import BookJobKit
import CryptoKit
import LibraryKit
import XCTest

@testable import SpokenFolioApp

final class IdentityMigrationTests: XCTestCase {
  func testIdentityUsesCleanSpokenFolioCutover() {
    XCTAssertEqual(AppIdentity.displayName, "SpokenFolio")
    XCTAssertEqual(AppIdentity.executableName, "spokenfolio")
    XCTAssertEqual(AppIdentity.bundleIdentifier, "com.xrishox.spokenfolio")
    XCTAssertEqual(AppIdentity.keychainService, "com.xrishox.spokenfolio.storyteller")
    XCTAssertEqual(AppIdentity.windowAutosaveName, "SpokenFolioMainWindow")
  }

  func testFreshAndAlreadyCurrentAreNoOps() throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let legacy = root.appendingPathComponent("legacy")
    let current = root.appendingPathComponent("current")
    let defaults = UserDefaults(suiteName: UUID().uuidString)!
    let migration = makeMigration(legacy: legacy, current: current, defaults: defaults)

    XCTAssertEqual(try migration.run(), .freshInstall)
    XCTAssertTrue(FileManager.default.fileExists(atPath: current.path))
    XCTAssertEqual(try migration.run(), .alreadyCurrent)
  }

  func testBothRootsConflictWithoutChangingEither() throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let legacy = root.appendingPathComponent("legacy")
    let current = root.appendingPathComponent("current")
    try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
    let migration = makeMigration(
      legacy: legacy, current: current, defaults: UserDefaults(suiteName: UUID().uuidString)!)

    XCTAssertThrowsError(try migration.run())
    XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: current.path))
  }

  func testMigrationMovesStateRewritesOwnedPathsAndRecomputesChecksum() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let legacy = root.appendingPathComponent("legacy")
    let current = root.appendingPathComponent("current")
    let source = legacy.appendingPathComponent("inputs/book.epub")
    try FileManager.default.createDirectory(
      at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("epub".utf8).write(to: source)
    let sourceHash = SHA256.hash(data: Data("epub".utf8)).map {
      String(format: "%02x", $0)
    }.joined()
    let request = BookJobRequest(
      title: "Fixture", author: nil,
      source: .init(path: source.path, sha256: sourceHash, format: "epub", importerVersion: 1),
      narration: .init(
        backendID: "siri", modelID: "siri-private", voiceID: "fixture",
        includedSectionIDs: [], bitrateKbps: 256, workers: 1,
        paragraphPauseSeconds: 0.6, chapterPauseSeconds: 1.75, announceTitles: true),
      m4bOutputPath: legacy.appendingPathComponent("outputs/book.m4b").path)
    let store = BookJobStore(root: legacy.appendingPathComponent("production-jobs"))
    _ = try await store.create(request)
    _ = try await BookSchedulerStore(
      url: legacy.appendingPathComponent("scheduler.json")
    ).setSuspended(true)
    let editionID = UUID()
    do {
      let library = try LibraryStore(databaseURL: legacy.appendingPathComponent("library.sqlite"))
      try library.createEdition(
        LibraryEdition(
          id: editionID, metadata: .init(title: "Fixture", author: nil),
          outputDirectory: legacy.appendingPathComponent("Processed").path,
          outputBaseName: "Fixture",
          source: .init(
            format: "epub", path: source.path, importerVersion: 1,
            sha256: sourceHash, size: 4)))
    }
    let defaults = UserDefaults(suiteName: UUID().uuidString)!
    let legacyDomain = "test.legacy.\(UUID().uuidString)"
    let currentDomain = "test.current.\(UUID().uuidString)"
    let oldFrameKey = "NSWindow Frame \(AppIdentity.legacyWindowAutosaveName)"
    defaults.setPersistentDomain(
      [oldFrameKey: "1 2 800 600 0 0 1440 900"],
      forName: legacyDomain)

    let outcome = try IdentityMigrationCoordinator(
      legacyRoot: legacy, currentRoot: current, defaults: defaults,
      legacyDefaultsDomain: legacyDomain, currentDefaultsDomain: currentDomain
    ).run()

    XCTAssertEqual(outcome, .migrated)
    XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
    let migratedStore = BookJobStore(root: current.appendingPathComponent("production-jobs"))
    let migrated = try await migratedStore.loadJob(request.id)
    XCTAssertEqual(
      migrated.0.source.path,
      current.appendingPathComponent("inputs/book.epub").path)
    XCTAssertEqual(
      migrated.0.m4bOutputPath,
      current.appendingPathComponent("outputs/book.m4b").path)
    let migratedEdition = try LibraryStore(
      databaseURL: current.appendingPathComponent("library.sqlite")).edition(editionID)
    XCTAssertEqual(migratedEdition.source.path, current.appendingPathComponent("inputs/book.epub").path)
    XCTAssertEqual(
      migratedEdition.outputDirectory, current.appendingPathComponent("Processed").path)
    XCTAssertEqual(
      defaults.persistentDomain(forName: currentDomain)?[
        "NSWindow Frame \(AppIdentity.windowAutosaveName)"] as? String,
      "1 2 800 600 0 0 1440 900")
    XCTAssertTrue(
      (defaults.persistentDomain(forName: legacyDomain) ?? [:]).isEmpty,
      "Golden Gate may retain an empty persistent domain after removal")
  }

  func testFailureAfterRewriteRestoresLegacyPathsAndRemovesCurrentRoot() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let legacy = root.appendingPathComponent("legacy")
    let current = root.appendingPathComponent("current")
    let source = legacy.appendingPathComponent("inputs/book.epub")
    try FileManager.default.createDirectory(
      at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
    let sourceData = Data("epub".utf8)
    try sourceData.write(to: source)
    let sourceHash = SHA256.hash(data: sourceData).map { String(format: "%02x", $0) }.joined()
    let request = BookJobRequest(
      title: "Rollback", author: nil,
      source: .init(path: source.path, sha256: sourceHash, format: "epub", importerVersion: 1),
      narration: .init(
        backendID: "siri", modelID: "siri-private", voiceID: "fixture",
        includedSectionIDs: [], bitrateKbps: 256, workers: 1,
        paragraphPauseSeconds: 0.6, chapterPauseSeconds: 1.75, announceTitles: true),
      m4bOutputPath: legacy.appendingPathComponent("outputs/book.m4b").path)
    let store = BookJobStore(root: legacy.appendingPathComponent("production-jobs"))
    _ = try await store.create(request)
    let defaults = UserDefaults(suiteName: UUID().uuidString)!
    let migration = IdentityMigrationCoordinator(
      legacyRoot: legacy, currentRoot: current,
      defaults: defaults,
      legacyDefaultsDomain: "test.legacy.\(UUID().uuidString)",
      currentDefaultsDomain: "test.current.\(UUID().uuidString)",
      afterDataValidation: { throw IdentityMigrationError(message: "injected failure") })

    XCTAssertThrowsError(try migration.run())
    XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: current.path))
    let restored = try await store.loadJob(request.id)
    XCTAssertEqual(restored.0.source.path, source.path)
    XCTAssertEqual(restored.0.m4bOutputPath, legacy.appendingPathComponent("outputs/book.m4b").path)
  }

  @MainActor
  func testNavigationDefaultsToProductionAndPersistsSelection() {
    let defaults = UserDefaults(suiteName: UUID().uuidString)!
    let first = AppNavigationModel(defaults: defaults)
    XCTAssertEqual(first.selection, .production)
    first.select(.server, defaults: defaults)
    XCTAssertEqual(AppNavigationModel(defaults: defaults).selection, .server)
  }

  @MainActor
  func testNavigationMigratesFormerSectionsIntoFiveDestinationShell() {
    let activityDefaults = UserDefaults(suiteName: UUID().uuidString)!
    activityDefaults.set("Activity", forKey: "SpokenFolioLastSection")
    let activity = AppNavigationModel(defaults: activityDefaults)
    XCTAssertEqual(activity.selection, .production)
    XCTAssertTrue(activity.initiallyShowsProductionQueue)

    for legacy in ["Create", "Storyteller", "ReadAloud Tools", "Settings"] {
      let defaults = UserDefaults(suiteName: UUID().uuidString)!
      defaults.set(legacy, forKey: "SpokenFolioLastSection")
      let model = AppNavigationModel(defaults: defaults)
      XCTAssertEqual(
        model.selection,
        ["Storyteller", "ReadAloud Tools", "Settings"].contains(legacy)
          ? .settings : .production)
      XCTAssertEqual(defaults.string(forKey: "SpokenFolioLastSection"), model.selection.rawValue)
      if legacy == "Storyteller" {
        XCTAssertEqual(
          defaults.string(forKey: SettingsScope.persistenceKey),
          SettingsScope.storyteller.rawValue)
      } else if legacy == "ReadAloud Tools" {
        XCTAssertEqual(
          defaults.string(forKey: SettingsScope.persistenceKey),
          SettingsScope.readAloud.rawValue)
      }
    }
  }

  private func makeMigration(
    legacy: URL, current: URL, defaults: UserDefaults
  ) -> IdentityMigrationCoordinator {
    IdentityMigrationCoordinator(
      legacyRoot: legacy, currentRoot: current, defaults: defaults,
      legacyDefaultsDomain: "test.legacy.\(UUID().uuidString)",
      currentDefaultsDomain: "test.current.\(UUID().uuidString)")
  }

  private func temporaryRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  }
}

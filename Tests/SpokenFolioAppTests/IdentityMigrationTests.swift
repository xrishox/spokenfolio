import BookJobKit
import CryptoKit
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
    try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
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
    XCTAssertEqual(
      defaults.persistentDomain(forName: currentDomain)?[
        "NSWindow Frame \(AppIdentity.windowAutosaveName)"] as? String,
      "1 2 800 600 0 0 1440 900")
    XCTAssertNil(defaults.persistentDomain(forName: legacyDomain))
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
  func testNavigationDefaultsToCreateAndPersistsSelection() {
    let defaults = UserDefaults(suiteName: UUID().uuidString)!
    let first = AppNavigationModel(defaults: defaults)
    XCTAssertEqual(first.selection, .create)
    first.select(.server, defaults: defaults)
    XCTAssertEqual(AppNavigationModel(defaults: defaults).selection, .server)
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

import BookJobKit
import Foundation
import LibraryKit
import StorytellerKit
import XCTest

@testable import SpokenFolioApp

/// Execution of the deletion manifest: per-book blocking, conflict-safe remote
/// deletes with ceiling semantics, local file/record/sidecar cleanup,
/// idempotency, and partial-failure isolation.
final class LibraryDeleteServiceTests: XCTestCase {
  // A scripted remote deleter — no network.
  private final class FakeDeleter: StorytellerAssetDeleter, @unchecked Sendable {
    var canUpdate = true
    var books: [UUID: StorytellerBook] = [:]
    var deleted: [(UUID, StorytellerFormat)] = []
    var hash: String?

    func ensureCanUpdate() async throws {
      if !canUpdate { throw StorytellerAPIError.missingPermission("bookUpdate") }
    }
    func liveBook(_ id: UUID) async throws -> StorytellerBook? { books[id] }
    func assetHash(bookID: UUID, format: StorytellerFormat, expectedSize: UInt64) async throws
      -> String?
    { hash }
    func deleteAsset(bookID: UUID, format: StorytellerFormat) async throws -> StorytellerBook {
      deleted.append((bookID, format))
      guard var book = books[bookID] else {
        throw StorytellerAPIError.rejected(status: 404, message: "gone")
      }
      switch format {
      case .ebook: book.ebook = nil
      case .audiobook: book.audiobook = nil
      case .readaloud: book.readaloud = nil
      }
      books[bookID] = book
      return book
    }
  }

  private func asset(_ id: UUID = UUID(), size: UInt64 = 10) -> StorytellerAsset {
    .init(uuid: id, filepath: "f.bin", fileSize: size)
  }

  private func service(
    catalogStore: BookCatalogStore, deleter: FakeDeleter? = nil,
    blocked: @escaping @Sendable (UUID?, String) async -> String? = { _, _ in nil },
    mutations: LibraryMutationCoordinator? = nil,
    timelineRoot: URL
  ) -> LibraryDeleteService {
    LibraryDeleteService(
      catalogStore: catalogStore, synthesisTimelineRoot: timelineRoot,
      mutations: mutations, makeDeleter: { _ in deleter }, blockedReason: blocked)
  }

  // MARK: - fixtures

  private func makeCatalog(_ root: URL) -> BookCatalogStore {
    BookCatalogStore(root: root.appendingPathComponent("catalog"))
  }

  private func sha(_ c: String) -> String { String(repeating: c, count: 64) }

  private func record(
    id: UUID, directory: URL, products extra: [BookCatalogProduct]
  ) -> BookCatalogRecord {
    BookCatalogRecord(
      id: id,
      source: .init(format: "epub", importerVersion: 1, sha256: sha("a"), size: 12),
      metadata: .init(title: "Fixture", author: "Author"),
      outputDirectory: directory.path, outputBaseName: "Fixture - Author",
      products: [
        .init(
          kind: .sourceEPUB, path: directory.appendingPathComponent("Fixture.epub").path,
          size: 12, sha256: sha("a"), verifiedAt: Date())
      ] + extra)
  }

  func testBlockedBookIsSkippedAndNothingIsTouched() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let catalog = makeCatalog(root)
    let id = UUID()
    let bookDir = root.appendingPathComponent("book")
    try FileManager.default.createDirectory(at: bookDir, withIntermediateDirectories: true)
    let m4bPath = bookDir.appendingPathComponent("a.m4b")
    try Data("audio".utf8).write(to: m4bPath)
    try await catalog.create(
      record(
        id: id, directory: bookDir,
        products: [
          .init(kind: .m4b, path: m4bPath.path, size: 5, sha256: sha("b"), verifiedAt: Date())
        ]))

    let impact = LibraryDeletePlanner.DeletionImpact(
      rowID: "local:\(id.uuidString)", title: "Fixture", catalogID: id, sourceSHA256: sha("a"),
      outputDirectory: bookDir.path, audiobookSHA256s: [sha("b")], wholeBookLocal: false,
      wholeBookLosesHuman: false,
      localSlots: [.init(kind: .m4b, path: m4bPath.path, sha256: sha("b"))],
      connectionID: nil, remoteBookID: nil, remoteSlots: [])

    let svc = service(
      catalogStore: catalog, blocked: { _, _ in "a production job for this book is active" },
      timelineRoot: root.appendingPathComponent("timelines"))
    let outcomes = await svc.execute([impact])
    XCTAssertEqual(outcomes.first?.blocked, "a production job for this book is active")
    XCTAssertFalse(outcomes.first?.didSomething ?? true)
    // Untouched: file and catalog product remain.
    XCTAssertTrue(FileManager.default.fileExists(atPath: m4bPath.path))
    let stillThere = try await catalog.load(id)
    XCTAssertTrue(stillThere.products.contains { $0.kind == .m4b })
  }

  func testLocalSlotDeleteRemovesFileRecordAndSidecar() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let catalog = makeCatalog(root)
    let timelineRoot = root.appendingPathComponent("timelines")
    let id = UUID()
    let bookDir = root.appendingPathComponent("book")
    try FileManager.default.createDirectory(at: bookDir, withIntermediateDirectories: true)
    let m4bPath = bookDir.appendingPathComponent("a.m4b")
    try Data("audio".utf8).write(to: m4bPath)
    let m4bHash = sha("b")
    // A synthesis-timeline sidecar keyed by the M4B digest.
    let timelines = SynthesisTimelineStore(root: timelineRoot)
    try FileManager.default.createDirectory(at: timelineRoot, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: timelines.url(forAudiobookSHA256: m4bHash))

    try await catalog.create(
      record(
        id: id, directory: bookDir,
        products: [.init(kind: .m4b, path: m4bPath.path, size: 5, sha256: m4bHash, verifiedAt: Date())]))

    let impact = LibraryDeletePlanner.DeletionImpact(
      rowID: "local:\(id.uuidString)", title: "Fixture", catalogID: id, sourceSHA256: sha("a"),
      outputDirectory: bookDir.path, audiobookSHA256s: [m4bHash], wholeBookLocal: false,
      wholeBookLosesHuman: false,
      localSlots: [.init(kind: .m4b, path: m4bPath.path, sha256: m4bHash)],
      connectionID: nil, remoteBookID: nil, remoteSlots: [])

    let svc = service(catalogStore: catalog, timelineRoot: timelineRoot)
    let outcomes = await svc.execute([impact])
    XCTAssertEqual(outcomes.first?.localDeleted, [.m4b])
    XCTAssertTrue(outcomes.first?.failures.isEmpty ?? false)
    XCTAssertFalse(FileManager.default.fileExists(atPath: m4bPath.path))
    XCTAssertFalse(timelines.exists(forAudiobookSHA256: m4bHash))
    let afterDelete = try await catalog.load(id)
    XCTAssertFalse(afterDelete.products.contains { $0.kind == .m4b })
    // The book itself (source) survives.
    XCTAssertTrue(afterDelete.products.contains { $0.kind == .sourceEPUB })
  }

  /// The catalog refusing a delete must leave the bytes where they were.
  /// Removing the file first and then failing the database mutation would
  /// leave a catalog row pointing at a file that no longer exists.
  func testFailedCatalogDeleteRestoresTheQuarantinedFile() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let catalog = makeCatalog(root)
    let timelineRoot = root.appendingPathComponent("timelines")
    let id = UUID()
    let bookDir = root.appendingPathComponent("book")
    try FileManager.default.createDirectory(at: bookDir, withIntermediateDirectories: true)
    let m4bPath = bookDir.appendingPathComponent("a.m4b")
    try Data("audio".utf8).write(to: m4bPath)
    let m4bHash = sha("b")
    try await catalog.create(
      record(
        id: id, directory: bookDir,
        products: [
          .init(kind: .m4b, path: m4bPath.path, size: 5, sha256: m4bHash, verifiedAt: Date())
        ]))

    // The digest guard fails: the plan's recorded hash no longer matches.
    let impact = LibraryDeletePlanner.DeletionImpact(
      rowID: "local:\(id.uuidString)", title: "Fixture", catalogID: id, sourceSHA256: sha("a"),
      outputDirectory: bookDir.path, audiobookSHA256s: [m4bHash], wholeBookLocal: false,
      wholeBookLosesHuman: false,
      localSlots: [.init(kind: .m4b, path: m4bPath.path, sha256: sha("stale"))],
      connectionID: nil, remoteBookID: nil, remoteSlots: [])

    let svc = service(catalogStore: catalog, timelineRoot: timelineRoot)
    let outcomes = await svc.execute([impact])

    XCTAssertEqual(outcomes.first?.localDeleted, [])
    XCTAssertFalse(outcomes.first?.failures.isEmpty ?? true, "the refusal must be reported")
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: m4bPath.path),
      "the file must be back where the catalog still says it is")
    XCTAssertEqual(try Data(contentsOf: m4bPath), Data("audio".utf8))
    let after = try await catalog.load(id)
    XCTAssertTrue(after.products.contains { $0.kind == .m4b })
    // No quarantine debris is left behind in the book folder.
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: bookDir.path)
      .filter { $0.hasPrefix(".spokenfolio-deleting-") }
    XCTAssertTrue(leftovers.isEmpty, "quarantine debris: \(leftovers)")
  }

  /// Two books in one run must not block each other: a lease is released
  /// before the next book is considered, not in a detached task that may
  /// still be pending.
  func testLeaseIsReleasedBeforeTheNextBookInTheSameRun() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let catalog = makeCatalog(root)
    let coordinator = LibraryMutationCoordinator()
    let svc = service(
      catalogStore: catalog, mutations: coordinator,
      timelineRoot: root.appendingPathComponent("timelines"))

    // The same book twice in one selection: the second pass must not be
    // refused by the first pass's own lease.
    let id = UUID()
    let impact = LibraryDeletePlanner.DeletionImpact(
      rowID: "local:\(id.uuidString)", title: "Fixture", catalogID: id, sourceSHA256: sha("a"),
      outputDirectory: nil, audiobookSHA256s: [], wholeBookLocal: false,
      wholeBookLosesHuman: false, localSlots: [], connectionID: nil, remoteBookID: nil,
      remoteSlots: [])

    let outcomes = await svc.execute([impact, impact])
    XCTAssertEqual(outcomes.count, 2)
    XCTAssertNil(outcomes[0].blocked)
    XCTAssertNil(outcomes[1].blocked, "the first pass's lease was still held")

    // And the coordinator is left clean for other work.
    guard case .success = await coordinator.acquire([.edition(id)], for: .production) else {
      return XCTFail("the deletion did not release its lease")
    }
  }

  /// A book another operation holds is skipped with the reason, and nothing
  /// it owns is touched.
  func testLeaseHeldBookIsSkippedRatherThanDeleted() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let catalog = makeCatalog(root)
    let id = UUID()
    let bookDir = root.appendingPathComponent("book")
    try FileManager.default.createDirectory(at: bookDir, withIntermediateDirectories: true)
    let m4bPath = bookDir.appendingPathComponent("a.m4b")
    try Data("audio".utf8).write(to: m4bPath)
    let m4bHash = sha("b")
    try await catalog.create(
      record(
        id: id, directory: bookDir,
        products: [
          .init(kind: .m4b, path: m4bPath.path, size: 5, sha256: m4bHash, verifiedAt: Date())
        ]))
    let impact = LibraryDeletePlanner.DeletionImpact(
      rowID: "local:\(id.uuidString)", title: "Fixture", catalogID: id, sourceSHA256: sha("a"),
      outputDirectory: bookDir.path, audiobookSHA256s: [m4bHash], wholeBookLocal: false,
      wholeBookLosesHuman: false,
      localSlots: [.init(kind: .m4b, path: m4bPath.path, sha256: m4bHash)],
      connectionID: nil, remoteBookID: nil, remoteSlots: [])

    let coordinator = LibraryMutationCoordinator()
    guard case .success = await coordinator.acquire([.edition(id)], for: .production) else {
      return XCTFail("test setup: the production lease must be granted")
    }

    let svc = service(
      catalogStore: catalog, mutations: coordinator,
      timelineRoot: root.appendingPathComponent("timelines"))
    let outcomes = await svc.execute([impact])

    XCTAssertEqual(outcomes.first?.blocked, "a production job for this book is running")
    XCTAssertTrue(FileManager.default.fileExists(atPath: m4bPath.path))
    let after = try await catalog.load(id)
    XCTAssertTrue(after.products.contains { $0.kind == .m4b })
  }

  func testWholeBookDeleteRemovesRecordFolderAndSidecars() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let catalog = makeCatalog(root)
    let timelineRoot = root.appendingPathComponent("timelines")
    let id = UUID()
    let bookDir = root.appendingPathComponent("book")
    try FileManager.default.createDirectory(at: bookDir, withIntermediateDirectories: true)
    try Data("epub".utf8).write(to: bookDir.appendingPathComponent("Fixture.epub"))
    let m4bHash = sha("b")
    try Data("audio".utf8).write(to: bookDir.appendingPathComponent("a.m4b"))
    let timelines = SynthesisTimelineStore(root: timelineRoot)
    try FileManager.default.createDirectory(at: timelineRoot, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: timelines.url(forAudiobookSHA256: m4bHash))

    try await catalog.create(
      record(
        id: id, directory: bookDir,
        products: [
          .init(
            kind: .m4b, path: bookDir.appendingPathComponent("a.m4b").path, size: 5,
            sha256: m4bHash, verifiedAt: Date())
        ]))

    let impact = LibraryDeletePlanner.DeletionImpact(
      rowID: "local:\(id.uuidString)", title: "Fixture", catalogID: id, sourceSHA256: sha("a"),
      outputDirectory: bookDir.path, audiobookSHA256s: [m4bHash], wholeBookLocal: true,
      wholeBookLosesHuman: false, localSlots: [], connectionID: nil, remoteBookID: nil,
      remoteSlots: [])

    let svc = service(catalogStore: catalog, timelineRoot: timelineRoot)
    let outcomes = await svc.execute([impact])
    XCTAssertTrue(outcomes.first?.wholeBookDeleted ?? false)
    XCTAssertFalse(FileManager.default.fileExists(atPath: bookDir.path))
    XCTAssertFalse(timelines.exists(forAudiobookSHA256: m4bHash))
    await XCTAssertThrowsErrorAsync(try await catalog.load(id))
  }

  func testRemoteDeleteHitsPerAssetEndpointAndIsIdempotentOnVanished() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let catalog = makeCatalog(root)
    let remoteBookID = UUID()
    let audiobookAsset = asset()
    let deleter = FakeDeleter()
    deleter.books[remoteBookID] = StorytellerBook(
      uuid: remoteBookID, title: "Fixture", authors: [], identifiers: [],
      audiobook: audiobookAsset, readaloud: asset())

    let impact = LibraryDeletePlanner.DeletionImpact(
      rowID: "row", title: "Fixture", catalogID: nil, sourceSHA256: nil, outputDirectory: nil,
      audiobookSHA256s: [], wholeBookLocal: false, wholeBookLosesHuman: false, localSlots: [],
      connectionID: UUID(), remoteBookID: remoteBookID,
      remoteSlots: [
        .init(
          format: .audiobook, assetID: audiobookAsset.uuid, size: 10, sha256: nil,
          fingerprint: nil, humanNarration: false)
      ])

    let svc = service(catalogStore: catalog, deleter: deleter, timelineRoot: root)
    let first = await svc.execute([impact])
    XCTAssertEqual(first.first?.remoteDeleted, [.audiobook])
    XCTAssertEqual(deleter.deleted.count, 1)
    XCTAssertNil(deleter.books[remoteBookID]?.audiobook)

    // Re-running finds the asset already gone → still succeeds, no new delete.
    let second = await svc.execute([impact])
    XCTAssertEqual(second.first?.remoteDeleted, [.audiobook])
    XCTAssertEqual(deleter.deleted.count, 1, "a vanished asset must not be deleted again")
  }

  func testRemoteCeilingAbortsWhenAssetIdentityChanged() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let catalog = makeCatalog(root)
    let remoteBookID = UUID()
    // The live asset has a DIFFERENT id than the confirmation snapshot.
    let liveAsset = asset()
    let deleter = FakeDeleter()
    deleter.books[remoteBookID] = StorytellerBook(
      uuid: remoteBookID, title: "Fixture", authors: [], identifiers: [], audiobook: liveAsset)

    let impact = LibraryDeletePlanner.DeletionImpact(
      rowID: "row", title: "Fixture", catalogID: nil, sourceSHA256: nil, outputDirectory: nil,
      audiobookSHA256s: [], wholeBookLocal: false, wholeBookLosesHuman: false, localSlots: [],
      connectionID: UUID(), remoteBookID: remoteBookID,
      remoteSlots: [
        .init(
          format: .audiobook, assetID: UUID(), size: 10, sha256: nil, fingerprint: nil,
          humanNarration: false)
      ])

    let svc = service(catalogStore: catalog, deleter: deleter, timelineRoot: root)
    let outcomes = await svc.execute([impact])
    XCTAssertTrue(outcomes.first?.remoteDeleted.isEmpty ?? false)
    XCTAssertEqual(outcomes.first?.failures.count, 1)
    XCTAssertEqual(deleter.deleted.count, 0, "a changed asset must never be deleted")
  }

  func testMissingUpdatePermissionFailsRemoteButNotLocal() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let catalog = makeCatalog(root)
    let timelineRoot = root.appendingPathComponent("timelines")
    let id = UUID()
    let bookDir = root.appendingPathComponent("book")
    try FileManager.default.createDirectory(at: bookDir, withIntermediateDirectories: true)
    let m4bPath = bookDir.appendingPathComponent("a.m4b")
    try Data("audio".utf8).write(to: m4bPath)
    let m4bHash = sha("b")
    try await catalog.create(
      record(
        id: id, directory: bookDir,
        products: [.init(kind: .m4b, path: m4bPath.path, size: 5, sha256: m4bHash, verifiedAt: Date())]))

    let deleter = FakeDeleter()
    deleter.canUpdate = false
    let remoteBookID = UUID()
    deleter.books[remoteBookID] = StorytellerBook(
      uuid: remoteBookID, title: "Fixture", authors: [], identifiers: [], audiobook: asset())

    let impact = LibraryDeletePlanner.DeletionImpact(
      rowID: "local:\(id.uuidString)", title: "Fixture", catalogID: id, sourceSHA256: sha("a"),
      outputDirectory: bookDir.path, audiobookSHA256s: [m4bHash], wholeBookLocal: false,
      wholeBookLosesHuman: false,
      localSlots: [.init(kind: .m4b, path: m4bPath.path, sha256: m4bHash)],
      connectionID: UUID(), remoteBookID: remoteBookID,
      remoteSlots: [
        .init(
          format: .audiobook, assetID: UUID(), size: 10, sha256: nil, fingerprint: nil,
          humanNarration: false)
      ])

    let svc = service(catalogStore: catalog, deleter: deleter, timelineRoot: timelineRoot)
    let outcomes = await svc.execute([impact])
    // Remote failed (no permission) but the local delete the user asked for
    // still happened — the two are independent.
    XCTAssertEqual(outcomes.first?.failures.count, 1)
    XCTAssertEqual(outcomes.first?.localDeleted, [.m4b])
    XCTAssertFalse(FileManager.default.fileExists(atPath: m4bPath.path))
  }
}

// Small async throwing assertion helper.
func XCTAssertThrowsErrorAsync(
  _ expression: @autoclosure () async throws -> some Any,
  _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line
) async {
  do {
    _ = try await expression()
    XCTFail(message().isEmpty ? "expected an error" : message(), file: file, line: line)
  } catch {}
}

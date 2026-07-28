import Foundation
import XCTest

@testable import LibraryKit

final class LibraryStoreTests: XCTestCase {
  private let sourceHash = String(repeating: "a", count: 64)

  private func temporaryURL(_ name: String = "library.sqlite") -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .appendingPathComponent(name)
  }

  private func edition(id: UUID = UUID()) -> LibraryEdition {
    let directory = "/tmp/\(id.uuidString)"
    return LibraryEdition(
      id: id, metadata: .init(title: "Fixture", author: "Author"),
      outputDirectory: directory, outputBaseName: "Fixture - Author",
      source: .init(
        format: "epub", path: "\(directory)/Fixture (E).epub", importerVersion: 1,
        sha256: sourceHash, size: 12),
      products: [
        .init(
          kind: .sourceEPUB, path: "\(directory)/Fixture (E).epub", size: 12,
          sha256: sourceHash, verifiedAt: Date())
      ])
  }

  func testUniversalLevelOrdering() {
    XCTAssertEqual(LibraryPackageState().level, .unavailable)
    XCTAssertEqual(LibraryPackageState(localEPUBReady: true).level, .readable)
    XCTAssertEqual(
      LibraryPackageState(localEPUBReady: true, remoteEPUBReady: true).level,
      .mirroredText)
    XCTAssertEqual(
      LibraryPackageState(
        remoteEPUBReady: true, remoteAudiobookReady: true, remoteReadAloudReady: true,
        remoteCoherence: .verified
      ).level, .remoteCompleteUnknown)
    XCTAssertEqual(
      LibraryPackageState(
        remoteEPUBReady: true, remoteAudiobookReady: true, remoteReadAloudReady: true,
        remoteCoherence: .verified, remoteNarration: .human
      ).level, .remoteCompleteHuman)
    XCTAssertEqual(
      LibraryPackageState(
        localEPUBReady: true, localAudiobookReady: true, localReadAloudReady: true,
        localCoherence: .verified, remoteEPUBReady: true, remoteAudiobookReady: true,
        remoteReadAloudReady: true, remoteCoherence: .verified, remoteNarration: .human
      ).level, .fullyResilient)
    XCTAssertEqual(
      LibraryPackageState(
        localEPUBReady: true, localAudiobookReady: true, localReadAloudReady: true,
        localCoherence: .conflict).level,
      .unavailable)
  }

  func testTwoEditionsCanBelongToTheSameWork() throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try LibraryStore(databaseURL: url)
    let workID = UUID()
    var first = edition()
    first.workID = workID
    try store.createEdition(first)
    var second = edition()
    second.workID = workID
    second.source.sha256 = String(repeating: "c", count: 64)
    try store.createEdition(second)
    XCTAssertEqual(try store.scanEditions().editions.count, 2)
    XCTAssertNoThrow(try store.validate())
  }

  func testEditionProductAndOptimisticLinkRoundTrip() throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try LibraryStore(databaseURL: url)
    let value = edition()
    try store.createEdition(value)
    XCTAssertEqual(try store.findEdition(sourceSHA256: sourceHash)?.id, value.id)

    let m4bHash = String(repeating: "b", count: 64)
    let m4b = LibraryLocalProduct(
      kind: .m4b, path: "/tmp/output.m4b", size: 100, sha256: m4bHash,
      verifiedAt: Date())
    let updated = try store.reconcileProduct(
      editionID: value.id,
      product: m4b,
      dependencies: [
        .init(productID: m4b.id, role: .source, inputSHA256: sourceHash)
      ])
    XCTAssertEqual(updated.revision, 1)
    XCTAssertEqual(updated.products.count, 2)
    XCTAssertEqual(
      updated.dependencies,
      [.init(productID: m4b.id, role: .source, inputSHA256: sourceHash)])

    let connectionID = UUID()
    try store.saveConnection(
      .init(
        id: connectionID, origin: URL(string: "http://storyteller.example:8001")!,
        displayName: "Storyteller", username: "reader", connectedAt: Date()))
    let linked = try store.replaceRemoteLinks(
      editionID: value.id,
      links: [
        .init(
          providerID: "storyteller", connectionID: connectionID,
          remoteBookID: UUID(), evidence: .userConfirmed)
      ], expectedRevision: updated.revision)
    XCTAssertEqual(linked.revision, 2)
    XCTAssertEqual(linked.remoteLinks.count, 1)
    XCTAssertThrowsError(
      try store.replaceRemoteLinks(
        editionID: value.id, links: [], expectedRevision: updated.revision))
    XCTAssertNoThrow(try store.validate())
  }

  func testExplicitProductReplacementIsAtomicAndDigestGuarded() throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try LibraryStore(databaseURL: url)
    let value = edition()
    try store.createEdition(value)
    let oldHash = String(repeating: "b", count: 64)
    let old = LibraryLocalProduct(
      kind: .m4b, path: "/tmp/output.m4b", size: 100, sha256: oldHash,
      verifiedAt: Date())
    _ = try store.reconcileProduct(
      editionID: value.id, product: old,
      dependencies: [.init(productID: old.id, role: .source, inputSHA256: sourceHash)])

    let replacement = LibraryLocalProduct(
      kind: .m4b, path: old.path, size: 110,
      sha256: String(repeating: "c", count: 64), verifiedAt: Date(),
      producerJobID: UUID(), narrationData: Data("provenance".utf8))
    XCTAssertThrowsError(
      try store.replaceProduct(
        editionID: value.id, product: replacement,
        expectedCurrentSHA256: String(repeating: "d", count: 64),
        dependencies: []))
    XCTAssertEqual(try store.edition(value.id).products.first { $0.kind == .m4b }?.sha256, oldHash)

    let updated = try store.replaceProduct(
      editionID: value.id, product: replacement, expectedCurrentSHA256: oldHash,
      dependencies: [
        .init(productID: replacement.id, role: .source, inputSHA256: sourceHash)
      ])
    XCTAssertEqual(updated.products.first { $0.kind == .m4b }?.sha256, replacement.sha256)
    XCTAssertEqual(
      updated.dependencies.first { $0.productID == replacement.id }?.inputSHA256, sourceHash)
    XCTAssertNoThrow(try store.validate())
  }

  func testDeleteProductRemovesItDropsTTSReceiptAndKeepsEdition() throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try LibraryStore(databaseURL: url)
    let value = edition()
    try store.createEdition(value)
    let m4bHash = String(repeating: "b", count: 64)
    let m4b = LibraryLocalProduct(
      kind: .m4b, path: "/tmp/output.m4b", size: 100, sha256: m4bHash, verifiedAt: Date())
    let withProduct = try store.reconcileProduct(
      editionID: value.id, product: m4b,
      dependencies: [.init(productID: m4b.id, role: .source, inputSHA256: sourceHash)])

    let connectionID = UUID()
    try store.saveConnection(
      .init(
        id: connectionID, origin: URL(string: "http://storyteller.example:8001")!,
        displayName: "Storyteller", username: "reader", connectedAt: Date()))
    _ = try store.replaceRemoteLinks(
      editionID: value.id,
      links: [
        .init(
          providerID: "storyteller", connectionID: connectionID, remoteBookID: UUID(),
          evidence: .userConfirmed,
          receipts: [.init(format: .audiobook, localSHA256: m4bHash, remoteAssetID: UUID())])
      ], expectedRevision: withProduct.revision)

    let updated = try store.deleteProduct(
      editionID: value.id, kind: .m4b, expectedSHA256: m4bHash)
    XCTAssertFalse(updated.products.contains { $0.kind == .m4b })
    XCTAssertTrue(updated.products.contains { $0.kind == .sourceEPUB })
    XCTAssertTrue(updated.dependencies.isEmpty, "the product's dependency rows must cascade away")
    // The delivery receipt the deleted M4B backed is gone; the link survives.
    XCTAssertEqual(updated.remoteLinks.first?.receipts.count, 0)
    XCTAssertEqual(updated.remoteLinks.count, 1)
    XCTAssertEqual(try store.findEdition(sourceSHA256: sourceHash)?.id, value.id)
    XCTAssertNoThrow(try store.validate())
  }

  /// A receipt's source identity and the representation that was actually
  /// served must both survive the database, including on a library created
  /// before those columns existed — otherwise every reopen would silently
  /// forget which of the two a size or digest described.
  func testReceiptRepresentationFieldsSurviveReopen() throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try LibraryStore(databaseURL: url)
    let value = edition()
    try store.createEdition(value)
    let connectionID = UUID()
    try store.saveConnection(
      .init(
        id: connectionID, origin: URL(string: "http://storyteller.example:8001")!,
        displayName: "Storyteller", username: "reader", connectedAt: Date()))
    let assetID = UUID()
    let stored = try store.replaceRemoteLinks(
      editionID: value.id,
      links: [
        .init(
          providerID: "storyteller", connectionID: connectionID, remoteBookID: UUID(),
          evidence: .userConfirmed,
          receipts: [
            .init(
              format: .audiobook, localSHA256: String(repeating: "b", count: 64),
              remoteAssetID: assetID, remoteSize: 4_000_000, remoteFingerprint: "fp",
              remoteSHA256: nil, servedSize: 123, servedSHA256: "served",
              servedContentType: "application/zip", sourceHashUnavailable: true)
          ])
      ], expectedRevision: value.revision)
    XCTAssertEqual(stored.remoteLinks.first?.receipts.count, 1)

    // Reopen: the values come back from SQLite, not from memory.
    let reopened = try LibraryStore(databaseURL: url)
    let receipt = try XCTUnwrap(
      try reopened.edition(value.id).remoteLinks.first?.receipts.first)
    XCTAssertEqual(receipt.remoteSize, 4_000_000)
    XCTAssertEqual(receipt.remoteFingerprint, "fp")
    XCTAssertNil(receipt.remoteSHA256)
    XCTAssertEqual(receipt.servedSize, 123)
    XCTAssertEqual(receipt.servedSHA256, "served")
    XCTAssertEqual(receipt.servedContentType, "application/zip")
    XCTAssertEqual(receipt.sourceHashUnavailable, true)
    XCTAssertNoThrow(try reopened.validate())
  }

  /// Opens a COPY of a real, pre-existing library and proves the schema
  /// migrates and still validates. Set `LIBRARY_MIGRATION_TEST_DB` to a copy
  /// of a live database; a fresh database exercises the create path but never
  /// the ALTER path an installed user actually takes.
  func testExistingDatabaseMigratesAndValidates() throws {
    guard let path = ProcessInfo.processInfo.environment["LIBRARY_MIGRATION_TEST_DB"] else {
      throw XCTSkip("LIBRARY_MIGRATION_TEST_DB not set")
    }
    let store = try LibraryStore(databaseURL: URL(fileURLWithPath: path))
    XCTAssertNoThrow(try store.validate())
    let editions = try store.scanEditions().editions
    // Existing receipts keep their source identity and simply have no served
    // representation recorded yet.
    for edition in editions {
      for link in edition.remoteLinks {
        for receipt in link.receipts {
          XCTAssertFalse(receipt.localSHA256.isEmpty)
        }
      }
    }
    print("migrated library: \(editions.count) editions")
  }

  func testDeleteProductIsDigestGuardedAndRefusesSource() throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try LibraryStore(databaseURL: url)
    let value = edition()
    try store.createEdition(value)
    let m4bHash = String(repeating: "b", count: 64)
    _ = try store.reconcileProduct(
      editionID: value.id,
      product: .init(
        kind: .m4b, path: "/tmp/output.m4b", size: 100, sha256: m4bHash, verifiedAt: Date()),
      dependencies: [])

    XCTAssertThrowsError(
      try store.deleteProduct(
        editionID: value.id, kind: .m4b, expectedSHA256: String(repeating: "d", count: 64))
    ) { error in
      guard case LibraryStoreError.conflict = error else { return XCTFail("expected conflict") }
    }
    XCTAssertTrue(try store.edition(value.id).products.contains { $0.kind == .m4b })

    XCTAssertThrowsError(
      try store.deleteProduct(editionID: value.id, kind: .sourceEPUB, expectedSHA256: sourceHash)
    ) { error in
      guard case LibraryStoreError.invalidRecord = error else {
        return XCTFail("source must not be deletable as a product")
      }
    }
    XCTAssertNoThrow(try store.validate())
  }

  func testDeleteEditionRemovesEverythingIncludingItsSoleWork() throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try LibraryStore(databaseURL: url)
    let value = edition()
    try store.createEdition(value)
    _ = try store.reconcileProduct(
      editionID: value.id,
      product: .init(
        kind: .m4b, path: "/tmp/output.m4b", size: 100,
        sha256: String(repeating: "b", count: 64), verifiedAt: Date()),
      dependencies: [])

    // Stale source digest is refused.
    XCTAssertThrowsError(
      try store.deleteEdition(
        editionID: value.id, expectedSourceSHA256: String(repeating: "d", count: 64))
    ) { error in
      guard case LibraryStoreError.conflict = error else { return XCTFail("expected conflict") }
    }
    XCTAssertEqual(try store.scanEditions().editions.count, 1)

    try store.deleteEdition(editionID: value.id, expectedSourceSHA256: sourceHash)
    XCTAssertEqual(try store.scanEditions().editions.count, 0)
    XCTAssertNil(try store.findEdition(sourceSHA256: sourceHash))
    XCTAssertThrowsError(try store.edition(value.id))
    XCTAssertNoThrow(try store.validate())
  }

  func testDeleteEditionKeepsAWorkSharedWithASiblingEdition() throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try LibraryStore(databaseURL: url)
    let workID = UUID()
    var first = edition()
    first.workID = workID
    try store.createEdition(first)
    let siblingHash = String(repeating: "c", count: 64)
    var second = edition()
    second.workID = workID
    second.source.sha256 = siblingHash
    second.source.path = "/tmp/sibling.epub"
    second.products = []
    try store.createEdition(second)

    try store.deleteEdition(editionID: first.id, expectedSourceSHA256: sourceHash)
    // The sibling — and therefore the shared work — must survive.
    XCTAssertEqual(try store.findEdition(sourceSHA256: siblingHash)?.id, second.id)
    XCTAssertEqual(try store.scanEditions().editions.count, 1)
    XCTAssertNoThrow(try store.validate())
  }

  func testCompleteRemoteGenerationMarksOnlyAbsentBooksMissing() throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try LibraryStore(databaseURL: url)
    let connectionID = UUID()
    try store.saveConnection(
      .init(
        id: connectionID, origin: URL(string: "http://storyteller.example:8001")!,
        displayName: "Storyteller", username: nil, connectedAt: Date()))
    let firstID = UUID()
    let secondID = UUID()
    _ = try store.replaceRemoteInventory(
      connectionID: connectionID,
      books: [
        .init(connectionID: connectionID, remoteBookID: firstID, title: "One"),
        .init(connectionID: connectionID, remoteBookID: secondID, title: "Two"),
      ])
    let result = try store.replaceRemoteInventory(
      connectionID: connectionID,
      books: [.init(connectionID: connectionID, remoteBookID: secondID, title: "Two")])
    XCTAssertEqual(result.generation, 2)
    let books = try store.remoteBooks(connectionID: connectionID)
    XCTAssertNotNil(books.first(where: { $0.id == firstID })?.missingAt)
    XCTAssertNil(books.first(where: { $0.id == secondID })?.missingAt)
  }

  func testRemoteReadAloudAutoAuditIntentIsDurableAndIdempotent() throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try LibraryStore(databaseURL: url)
    let connectionID = UUID()
    let bookID = UUID()
    try store.saveConnection(
      .init(
        id: connectionID, origin: URL(string: "http://storyteller.example:8001")!,
        displayName: "Storyteller", username: nil, connectedAt: Date()))

    let first = try store.beginRemoteReadAloudAutoAudit(
      connectionID: connectionID, bookID: bookID)
    let replay = try store.beginRemoteReadAloudAutoAudit(
      connectionID: connectionID, bookID: bookID)
    XCTAssertEqual(first.id, replay.id)
    XCTAssertEqual(try store.pendingRemoteReadAloudAutoAudits(), [first])

    try store.markRemoteReadAloudAutoAuditWaiting(first.id)
    XCTAssertEqual(try store.pendingRemoteReadAloudAutoAudits().first?.status, .waiting)
    try store.completeRemoteReadAloudAutoAudit(first.id)
    XCTAssertTrue(try store.pendingRemoteReadAloudAutoAudits().isEmpty)
    XCTAssertNoThrow(try store.validate())
  }

  func testIdentifierCorrectionAndProvenanceAreDurableAssertions() throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try LibraryStore(databaseURL: url)
    let value = edition()
    try store.createEdition(value)
    try store.setEditionIdentifier(
      editionID: value.id, kind: "isbn-13", value: "9780306406157")
    let corrected = try store.edition(value.id)
    XCTAssertEqual(corrected.metadata.identifiers.last?.value, "9780306406157")
    XCTAssertEqual(corrected.revision, 1)

    let connectionID = UUID()
    let remoteBookID = UUID()
    let assetID = UUID()
    try store.saveConnection(
      .init(
        id: connectionID, origin: URL(string: "http://storyteller.example:8001")!,
        displayName: "Storyteller", username: nil, connectedAt: Date()))
    let assertion = LibraryProvenanceAssertion(
      connectionID: connectionID, remoteBookID: remoteBookID,
      remoteAssetID: assetID, provenance: .human, coherence: .verified,
      source: "user")
    try store.assertProvenance(assertion)
    let restored = try XCTUnwrap(
      store.provenance(
        connectionID: connectionID, remoteBookID: remoteBookID,
        remoteAssetID: assetID))
    XCTAssertEqual(restored.id, assertion.id)
    XCTAssertEqual(restored.connectionID, assertion.connectionID)
    XCTAssertEqual(restored.remoteBookID, assertion.remoteBookID)
    XCTAssertEqual(restored.remoteAssetID, assertion.remoteAssetID)
    XCTAssertEqual(restored.provenance, .human)
    XCTAssertEqual(restored.coherence, .verified)
    XCTAssertEqual(restored.source, "user")
    XCTAssertEqual(
      restored.createdAt.timeIntervalSince1970,
      assertion.createdAt.timeIntervalSince1970, accuracy: 0.000_001)
  }

  func testBulkProvenanceAssertionsCommitAtomically() throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try LibraryStore(databaseURL: url)
    let connectionID = UUID()
    try store.saveConnection(
      .init(
        id: connectionID, origin: URL(string: "http://storyteller.example:8001")!,
        displayName: "Storyteller", username: nil, connectedAt: Date()))

    let firstBookID = UUID()
    let firstAssetID = UUID()
    let secondBookID = UUID()
    let secondAssetID = UUID()
    try store.assertProvenance([
      .init(
        connectionID: connectionID, remoteBookID: firstBookID,
        remoteAssetID: firstAssetID, provenance: .human, coherence: .verified,
        source: "user:bulk-narration"),
      .init(
        connectionID: connectionID, remoteBookID: secondBookID,
        remoteAssetID: secondAssetID, provenance: .human, coherence: .unknown,
        source: "user:bulk-narration"),
    ])
    XCTAssertEqual(
      try store.provenance(
        connectionID: connectionID, remoteBookID: firstBookID,
        remoteAssetID: firstAssetID)?.provenance,
      .human)
    XCTAssertEqual(
      try store.provenance(
        connectionID: connectionID, remoteBookID: secondBookID,
        remoteAssetID: secondAssetID)?.provenance,
      .human)

    let validBookID = UUID()
    let validAssetID = UUID()
    XCTAssertThrowsError(
      try store.assertProvenance([
        .init(
          connectionID: connectionID, remoteBookID: validBookID,
          remoteAssetID: validAssetID, provenance: .otherTTS, coherence: .unknown,
          source: "user:bulk-narration"),
        .init(
          connectionID: UUID(), remoteBookID: UUID(), remoteAssetID: UUID(),
          provenance: .otherTTS, coherence: .unknown,
          source: "user:bulk-narration"),
      ]))
    XCTAssertNil(
      try store.provenance(
        connectionID: connectionID, remoteBookID: validBookID,
        remoteAssetID: validAssetID))
  }

  func testReadAloudAuditProgressAndFindingsRoundTrip() throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try LibraryStore(databaseURL: url)
    let started = Date()
    var run = LibraryReadAloudAuditRun(
      target: .standalone(path: "/tmp/fixture-readaloud.epub"),
      mode: "standard", lifecycle: .running, progress: 0.4,
      progressMessage: "Checking embedded audio", startedAt: started,
      updatedAt: started)
    try store.saveReadAloudAudit(run)
    XCTAssertEqual(try store.readAloudAudits().first?.progress, 0.4)

    run.lifecycle = .completed
    run.progress = 1
    run.progressMessage = "Complete"
    run.artifactSHA256 = String(repeating: "d", count: 64)
    run.verdict = "likelyBroken"
    run.evidenceAdequacy = "sampled"
    run.metricsData = try JSONEncoder().encode(["primaryCoverage": 0.95])
    run.reportData = try JSONEncoder().encode(["schemaVersion": 1])
    run.completedAt = started.addingTimeInterval(2)
    run.updatedAt = run.completedAt!
    run.findings = [
      .init(
        dimension: "identity", code: "possibleAbridgedOrIncompatibleEdition",
        verdict: "likelyBroken", confidence: "strong",
        summary: "The text and narration do not represent a compatible edition.")
    ]
    try store.saveReadAloudAudit(run)
    let restored = try XCTUnwrap(store.latestReadAloudAudit(for: run.target))
    XCTAssertEqual(
      restored.startedAt.timeIntervalSince1970,
      run.startedAt.timeIntervalSince1970, accuracy: 0.000_001)
    XCTAssertEqual(
      restored.updatedAt.timeIntervalSince1970,
      run.updatedAt.timeIntervalSince1970, accuracy: 0.000_001)
    XCTAssertEqual(
      try XCTUnwrap(restored.completedAt).timeIntervalSince1970,
      try XCTUnwrap(run.completedAt).timeIntervalSince1970, accuracy: 0.000_001)
    var expected = run
    expected.startedAt = restored.startedAt
    expected.updatedAt = restored.updatedAt
    expected.completedAt = restored.completedAt
    XCTAssertEqual(restored, expected)
    XCTAssertEqual(try store.readAloudAudits().count, 1)
    XCTAssertNoThrow(try store.validate())
  }

  func testReadAloudAuditBatchAndRestartReconciliationPreserveQueuedWork() throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try LibraryStore(databaseURL: url)
    let queued = LibraryReadAloudAuditRun(
      target: .standalone(path: "/tmp/queued-readaloud.epub"), mode: "standard",
      progressMessage: "Queued")
    let running = LibraryReadAloudAuditRun(
      target: .standalone(path: "/tmp/running-readaloud.epub"), mode: "thorough",
      lifecycle: .running, progress: 0.4, progressMessage: "Transcribing")
    try store.saveReadAloudAudits([queued, running])

    try store.reconcileInterruptedReadAloudAudits()
    let restored = try store.readAloudAudits()
    XCTAssertEqual(restored.first(where: { $0.id == queued.id })?.lifecycle, .queued)
    XCTAssertEqual(restored.first(where: { $0.id == queued.id })?.progressMessage, "Queued")
    XCTAssertEqual(restored.first(where: { $0.id == running.id })?.lifecycle, .failed)
    XCTAssertEqual(
      restored.first(where: { $0.id == running.id })?.progressMessage,
      "Interrupted by application exit")
  }

  func testApplicableAuditIgnoresNewerRunningAndDifferentArtifact() throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try LibraryStore(databaseURL: url)
    let target = LibraryReadAloudAuditTarget.standalone(path: "/tmp/applicable.epub")
    let artifact = String(repeating: "a", count: 64)
    let reference = String(repeating: "b", count: 64)
    let now = Date()
    let completed = LibraryReadAloudAuditRun(
      target: target, artifactSHA256: artifact, referenceSHA256: reference,
      analyzerIdentity: "readaloud-quality-v1", policyVersion: 1,
      mode: "standard", lifecycle: .completed, progress: 1,
      progressMessage: "Complete", verdict: "likelyCorrect",
      evidenceAdequacy: "sampled", reportData: Data("{}".utf8),
      startedAt: now, updatedAt: now, completedAt: now)
    try store.saveReadAloudAudit(completed)
    try store.saveReadAloudAudit(
      LibraryReadAloudAuditRun(
        target: target, mode: "standard", lifecycle: .running, progress: 0.5,
        startedAt: now.addingTimeInterval(10), updatedAt: now.addingTimeInterval(10)))

    XCTAssertEqual(
      try store.latestApplicableReadAloudAudit(
        for: target, artifactSHA256: artifact, referenceSHA256: reference,
        analyzerIdentity: "readaloud-quality-v1", policyVersion: 1)?.id,
      completed.id)
    XCTAssertNil(
      try store.latestApplicableReadAloudAudit(
        for: target, artifactSHA256: String(repeating: "c", count: 64),
        referenceSHA256: reference, analyzerIdentity: "readaloud-quality-v1",
        policyVersion: 1))
  }
}

import Foundation
import XCTest

@testable import BookJobKit

final class BookJobTests: XCTestCase {
  private func request(id: UUID = UUID(), readAloud: Bool = true) -> BookJobRequest {
    BookJobRequest(
      id: id, title: "Fixture", author: "Author",
      source: .init(
        path: "/tmp/book.epub", sha256: String(repeating: "a", count: 64), format: "epub",
        importerVersion: 1),
      narration: .init(
        backendID: "siri", modelID: "siri-private", voiceID: "voice", includedSectionIDs: ["one"],
        bitrateKbps: 256, workers: 4, paragraphPauseSeconds: 0.6,
        chapterPauseSeconds: 1.75, announceTitles: !readAloud),
      m4bOutputPath: "/tmp/book.m4b",
      readAloud: readAloud ? .init(outputPath: "/tmp/book.readaloud.epub") : nil)
  }

  func testRequestPolicyAndStateTransitions() throws {
    try request().validate()
    var bad = request()
    bad.narration.announceTitles = true
    XCTAssertThrowsError(try bad.validate())
    bad = request()
    bad.m4bOutputPath = bad.source.path
    XCTAssertThrowsError(try bad.validate(), "an output must never overwrite the source EPUB")
    bad = request()
    bad.narration.backendID = "unknown"
    XCTAssertThrowsError(try bad.validate())
    bad = request()
    bad.operation = .storytellerDelivery
    XCTAssertThrowsError(try bad.validate(), "delivery-only work requires selected products")

    var state = BookJobState(jobID: UUID(), requestSHA256: "hash")
    try state.transition(to: .running)
    try state.updateStage(.preparation, status: .running, fraction: 2)
    XCTAssertEqual(state.stages[0].fraction, 1)
    XCTAssertThrowsError(try state.updateStage(.m4bSynthesis, status: .running))
    try state.updateStage(.preparation, status: .succeeded, fraction: 1)
    try state.transition(to: .paused)
    XCTAssertThrowsError(try state.transition(to: .completed))
  }

  func testLegacyRequestWithoutOperationDecodesAsProduction() throws {
    var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request()))
      as! [String: Any]
    object.removeValue(forKey: "operation")
    let decoded = try JSONDecoder().decode(
      BookJobRequest.self, from: JSONSerialization.data(withJSONObject: object))
    XCTAssertEqual(decoded.resolvedOperation, .production)
  }

  func testSchemaOneRequestFixtureStillDecodesAndValidates() throws {
    var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request()))
      as! [String: Any]
    object["schemaVersion"] = 1
    for key in [
      "operation", "catalogID", "batchID", "batchOrdinal", "batchCount", "managedByStudio",
      "alignmentAudio",
    ] { object.removeValue(forKey: key) }
    var source = object["source"] as! [String: Any]
    source.removeValue(forKey: "typedIdentifiers")
    object["source"] = source

    let decoded = try JSONDecoder().decode(
      BookJobRequest.self, from: JSONSerialization.data(withJSONObject: object))

    XCTAssertEqual(decoded.schemaVersion, 1)
    XCTAssertEqual(decoded.resolvedOperation, .production)
    XCTAssertTrue(decoded.source.typedIdentifiers.isEmpty)
    XCTAssertNoThrow(try decoded.validate())
  }

  func testManagedLayoutCatalogAndRemoteReceiptRoundTrip() async throws {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let source = temporary.appendingPathComponent("incoming.epub")
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    try Data("fixture epub".utf8).write(to: source)
    let hash = try BookFileDigest.sha256(source)
    let layout = ManagedBookLayout(
      directory: temporary.appendingPathComponent("Processed"), title: "A/B: Book",
      author: "An Author")
    XCTAssertEqual(layout.sourceEPUB.lastPathComponent, "A-B- Book - An Author (E).epub")
    XCTAssertEqual(layout.audiobook.lastPathComponent, "A-B- Book - An Author (A).m4b")
    XCTAssertEqual(layout.readAloud.lastPathComponent, "A-B- Book - An Author (R).epub")
    try layout.stageSource(from: source, expectedSHA256: hash)
    XCTAssertEqual(try BookFileDigest.sha256(layout.sourceEPUB), hash)

    let catalogRoot = temporary.appendingPathComponent("Catalog")
    let store = BookCatalogStore(root: catalogRoot)
    var record = BookCatalogRecord(
      source: .init(format: "epub", importerVersion: 1, sha256: hash, size: 12),
      metadata: .init(title: "A/B: Book", author: "An Author"),
      outputDirectory: layout.directory.path, outputBaseName: layout.baseName,
      products: [
        .init(
          kind: .sourceEPUB, path: layout.sourceEPUB.path, size: 12, sha256: hash,
          verifiedAt: Date())
      ])
    try await store.create(record)
    let originalRevision = record.revision
    record.upsertRemoteLink(
      .init(
        providerID: "storyteller", connectionID: UUID(), remoteBookID: UUID().uuidString,
        evidence: .exactAssetHash,
        receipts: [
          .init(
            format: "ebook", localSHA256: hash, remoteAssetID: UUID().uuidString,
            remoteSize: 12, remoteSHA256: hash)
        ]))
    try await store.update(record, expectedRevision: originalRevision)

    let loaded = try await store.load(record.id)
    let found = try await store.find(sourceSHA256: hash)
    XCTAssertEqual(loaded.products.first?.path, layout.sourceEPUB.path)
    XCTAssertEqual(loaded.remoteLinks.first?.receipts.first?.localSHA256, hash)
    XCTAssertEqual(found?.id, record.id)

    var illegal = loaded
    illegal.outputBaseName = "moved"
    illegal.touch()
    do {
      try await store.update(illegal, expectedRevision: loaded.revision)
      XCTFail("catalog identity and layout must be immutable")
    } catch let error as BookJobError {
      guard case .invalidRequest = error else { return XCTFail("unexpected error: \(error)") }
    }
  }

  func testCatalogAndJobScansReportCorruptEntriesWithoutHidingValidOnes() async throws {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let jobStore = BookJobStore(root: temporary.appendingPathComponent("Jobs"))
    let valid = request()
    _ = try await jobStore.create(valid)
    let corruptID = UUID()
    let corruptJob = await jobStore.jobDirectory(corruptID)
    try FileManager.default.createDirectory(at: corruptJob, withIntermediateDirectories: true)
    try Data("not json".utf8).write(to: corruptJob.appendingPathComponent("request.json"))
    let jobs = try await jobStore.scan()
    XCTAssertEqual(jobs.jobs.map(\.0.id), [valid.id])
    XCTAssertEqual(jobs.issues.map(\.directory), [corruptID.uuidString.lowercased()])

    let catalogStore = BookCatalogStore(root: temporary.appendingPathComponent("Catalog"))
    _ = try await catalogStore.scan()
    let corruptCatalog = await catalogStore.recordDirectory(UUID())
    try FileManager.default.createDirectory(at: corruptCatalog, withIntermediateDirectories: true)
    try Data("not json".utf8).write(to: corruptCatalog.appendingPathComponent("record.json"))
    let catalog = try await catalogStore.scan()
    XCTAssertTrue(catalog.records.isEmpty)
    XCTAssertEqual(catalog.issues.count, 1)
  }

  func testStudioSettingsAndSchedulerPersistence() async throws {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let settingsStore = StudioSettingsStore(url: temporary.appendingPathComponent("settings.json"))
    let home = URL(fileURLWithPath: "/Users/example")
    let defaultSettings = try await settingsStore.load()
    XCTAssertEqual(
      defaultSettings.resolvedProcessedDirectory(home: home).path,
      "/Users/example/Books/Processed")
    try await settingsStore.save(StudioSettings(processedDirectory: "/Volumes/Books"))
    let customSettings = try await settingsStore.load()
    XCTAssertEqual(
      customSettings.resolvedProcessedDirectory(home: home).path,
      "/Volumes/Books")

    let scheduler = BookSchedulerStore(url: temporary.appendingPathComponent("scheduler.json"))
    let first = try await scheduler.reserve(count: 3)
    let second = try await scheduler.reserve(count: 2)
    XCTAssertEqual(first, [0, 1, 2])
    XCTAssertEqual(second, [3, 4])
    _ = try await scheduler.setSuspended(false)
    let persisted = try await scheduler.load()
    XCTAssertFalse(persisted.isSuspended)
    XCTAssertEqual(persisted.nextQueueSequence, 5)
  }

  func testCrashRecoveryClearsStaleRunningStage() throws {
    var state = BookJobState(jobID: UUID(), requestSHA256: "hash")
    try state.transition(to: .running)
    try state.updateStage(.m4bSynthesis, status: .running, fraction: 0.4)
    state.lastError = "stale"
    state.prepareForRetry()
    XCTAssertEqual(state.lifecycle, .running)
    XCTAssertNil(state.lastError)
    XCTAssertEqual(
      state.stages.first(where: { $0.stage == .m4bSynthesis })?.status, .pending)
    XCTAssertFalse(state.stages.contains(where: { $0.status == .running }))
  }

  func testTouchAdvancesRevisionForDirectProgressMutations() {
    var state = BookJobState(jobID: UUID(), requestSHA256: "hash")
    let revision = state.revision
    state.audiobookProgress = .init(
      totalChapters: 2, totalCharacters: 100, reusedChapters: 0,
      chapterCharacters: [50, 50])
    state.touch()
    XCTAssertEqual(state.revision, revision + 1)
  }

  func testStoreRoundTripCancellationAndLease() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = BookJobStore(root: root)
    let value = request()
    let initial = try await store.create(value)
    XCTAssertEqual(initial.lifecycle, .queued)
    let loaded = try await store.loadRequest(value.id)
    let listed = try await store.list()
    XCTAssertEqual(loaded, value)
    XCTAssertEqual(listed.count, 1)

    try await store.requestCancellation(value.id, attempt: 4)
    let control = try await store.loadControl(value.id)
    XCTAssertEqual(control.cancelRequestedForAttempt, 4)

    let lease = try await store.acquireLease(value.id)
    try withExtendedLifetime(lease) {
      // Lease acquisition is synchronous after the actor returns, so a
      // second direct lease proves the cross-process flock exclusion.
      XCTAssertThrowsError(
        try BookJobLease(directory: root.appendingPathComponent(value.id.uuidString.lowercased())))
    }
  }

  func testLoadJobRejectsRequestChangedAfterCreation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = BookJobStore(root: root)
    let value = request()
    _ = try await store.create(value)
    let directory = await store.jobDirectory(value.id)
    let url = directory.appendingPathComponent("request.json")
    var text = try String(contentsOf: url, encoding: .utf8)
    text = text.replacingOccurrences(of: "Fixture", with: "Tampered")
    try Data(text.utf8).write(to: url)
    do {
      _ = try await store.loadJob(value.id)
      XCTFail("request checksum mismatch must fail")
    } catch let error as BookJobError {
      guard case .corruptState = error else { return XCTFail("unexpected error \(error)") }
    }
    do {
      _ = try await store.list()
      XCTFail("a corrupt durable job must be reported, not silently hidden")
    } catch {}
  }

  func testUnknownSchemaAndEventRotation() async throws {
    var value = request()
    value.schemaVersion = 99
    XCTAssertThrowsError(try value.validate())

    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = BookJobStore(root: root)
    let valid = request()
    _ = try await store.create(valid)
    for sequence in 0..<8 {
      try await store.appendEvent(
        BookJobEvent(
          jobID: valid.id, attempt: 1, sequence: UInt64(sequence), timestamp: Date(),
          type: "progress", stage: .m4bSynthesis, fraction: 0.5,
          message: String(repeating: "x", count: 80)),
        maximumBytes: 200)
    }
    let directory = await store.jobDirectory(valid.id)
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("events.ndjson.old").path))
  }
}

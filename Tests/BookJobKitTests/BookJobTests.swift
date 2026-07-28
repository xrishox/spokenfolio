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
    let current = request()
    try current.validate()
    // New requests default to the exact synthesis-timeline transcript.
    XCTAssertEqual(current.readAloud?.resolvedASREngineID, "synthesis")
    XCTAssertNil(current.readAloud?.resolvedASRModelID)
    var bad = request()
    bad.narration.announceTitles = true
    XCTAssertThrowsError(try bad.validate())
    bad = request()
    bad.m4bOutputPath = bad.source.path
    XCTAssertThrowsError(try bad.validate(), "an output must never overwrite the source EPUB")
    bad = request()
    bad.narration.backendID = "future-engine"
    bad.narration.modelID = "future-model"
    XCTAssertNoThrow(try bad.validate(), "BookJobKit stores qualified identities without owning engine policy")
    bad.narration.backendID = "  "
    XCTAssertThrowsError(try bad.validate())
    bad = request()
    bad.narration.pacePreset = 0
    XCTAssertThrowsError(try bad.validate())
    bad = request()
    bad.readAloud?.outputPath = "relative.epub"
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
    XCTAssertTrue(decoded.resolvedProductReplacements.isEmpty)
  }

  func testProductReplacementRequiresExplicitExpectedDigestAndOverwrite() throws {
    var value = request(readAloud: false)
    value.catalogID = UUID()
    value.productReplacements = [
      .init(kind: .m4b, expectedSHA256: String(repeating: "b", count: 64))
    ]
    XCTAssertThrowsError(try value.validate())
    value.allowOverwrite = true
    XCTAssertNoThrow(try value.validate())

    value.productReplacements?.append(
      .init(kind: .m4b, expectedSHA256: String(repeating: "c", count: 64)))
    XCTAssertThrowsError(try value.validate(), "replacement kinds must be unique")
  }

  func testReadAloudRecreateReplacementValidatesOnlyForMatchingOperation() throws {
    var value = request()
    value.catalogID = UUID()
    value.operation = .readAloud
    value.alignmentAudio = .init(mode: .temporaryResynthesis)
    value.productReplacements = [
      .init(kind: .readAloudEPUB, expectedSHA256: String(repeating: "d", count: 64))
    ]
    XCTAssertThrowsError(
      try value.validate(), "recreating a ReadAloud requires an explicit overwrite grant")
    value.allowOverwrite = true
    XCTAssertNoThrow(try value.validate())

    // A ReadAloud-only replacement is not a valid production plan…
    value.operation = .production
    XCTAssertThrowsError(try value.validate())
    // …but a production job may replace the ReadAloud alongside its M4B.
    value.productReplacements?.append(
      .init(kind: .m4b, expectedSHA256: String(repeating: "e", count: 64)))
    XCTAssertNoThrow(try value.validate())

    // Delivery-only jobs never replace products.
    value.operation = .storytellerDelivery
    XCTAssertThrowsError(try value.validate())
  }

  func testActualNarrationRuntimeRoundTripsInJobState() throws {
    var narration = request(readAloud: false).narration
    narration.runtime = .init(
      macOSVersion: "26.5.2", macOSBuild: "25F84",
      frameworkIdentifier: "com.apple.siri.SiriTTSService",
      frameworkVersion: "1", frameworkSDKVersion: "26.5", frameworkSDKBuild: "25F63",
      adapterIdentifier: "com.apple.fm.language.instruct_3b.voice",
      backendAdapterRevision: "adapter-2",
      resourceIdentity: "en-US", resourceRevision: "1023")
    var state = BookJobState(jobID: UUID(), requestSHA256: "hash")
    state.actualNarration = narration
    let decoded = try JSONDecoder().decode(
      BookJobState.self, from: JSONEncoder().encode(state))
    XCTAssertEqual(decoded.actualNarration, narration)
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
    var readAloud = object["readAloud"] as! [String: Any]
    readAloud.removeValue(forKey: "asrEngineID")
    readAloud.removeValue(forKey: "asrModelID")
    object["readAloud"] = readAloud

    let decoded = try JSONDecoder().decode(
      BookJobRequest.self, from: JSONSerialization.data(withJSONObject: object))

    XCTAssertEqual(decoded.schemaVersion, 1)
    XCTAssertEqual(decoded.resolvedOperation, .production)
    XCTAssertTrue(decoded.source.typedIdentifiers.isEmpty)
    XCTAssertEqual(decoded.readAloud?.resolvedASREngineID, "whisper")
    XCTAssertEqual(decoded.readAloud?.resolvedASRModelID, "tiny")
    XCTAssertNoThrow(try decoded.validate())
  }

  func testSchemaTwoReadAloudRetainsHistoricalWhisperTinyDefaults() throws {
    var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request()))
      as! [String: Any]
    object["schemaVersion"] = 2
    var readAloud = object["readAloud"] as! [String: Any]
    readAloud.removeValue(forKey: "asrEngineID")
    readAloud.removeValue(forKey: "asrModelID")
    object["readAloud"] = readAloud
    let decoded = try JSONDecoder().decode(
      BookJobRequest.self, from: JSONSerialization.data(withJSONObject: object))
    XCTAssertEqual(decoded.schemaVersion, 2)
    XCTAssertEqual(decoded.readAloud?.resolvedASREngineID, "whisper")
    XCTAssertEqual(decoded.readAloud?.resolvedASRModelID, "tiny")
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
    XCTAssertEqual(layout.directory.lastPathComponent, "A-B- Book - An Author")
    XCTAssertEqual(layout.sourceEPUB.lastPathComponent, "A-B- Book - An Author.epub")
    XCTAssertEqual(
      layout.audiobook.lastPathComponent, "A-B- Book - An Author - TTS Audiobook.m4b")
    XCTAssertEqual(
      layout.readAloud.lastPathComponent, "A-B- Book - An Author - TTS ReadAloud.epub")
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

  /// Producing a book runs `reconcileCatalog` more than once: once the moment
  /// the M4B is committed (so a job cancelled during the long ReadAloud stage
  /// can never leave the audiobook on disk untracked) and again at job end for
  /// the ReadAloud product. That repetition is only safe because reconcile is
  /// idempotent — a second reconcile of an identical product is a no-op. A
  /// digest-guarded replace, by contrast, is single-shot: applying it twice
  /// conflicts, which is exactly why the second pass skips products already in
  /// the catalog rather than replacing them again.
  func testRepeatedM4BCatalogingIsIdempotentButReplaceIsSingleShot() async throws {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: temporary) }
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)

    let sourceHash = String(repeating: "a", count: 64)
    let firstM4B = String(repeating: "b", count: 64)
    let secondM4B = String(repeating: "c", count: 64)
    let store = BookCatalogStore(root: temporary.appendingPathComponent("Catalog"))
    let record = BookCatalogRecord(
      source: .init(format: "epub", importerVersion: 1, sha256: sourceHash, size: 12),
      metadata: .init(title: "Idempotent", author: "Author"),
      outputDirectory: temporary.appendingPathComponent("book").path, outputBaseName: "Idempotent",
      products: [
        .init(
          kind: .sourceEPUB, path: "/tmp/book.epub", size: 12, sha256: sourceHash,
          verifiedAt: Date())
      ])
    try await store.create(record)

    let m4b = BookCatalogProduct(
      kind: .m4b, path: "/tmp/book.m4b", size: 4096, sha256: firstM4B, verifiedAt: Date())
    // The early (post-synthesis) catalog and the final (end-of-job) catalog
    // both reconcile the same M4B — the second must be a harmless no-op.
    _ = try await store.reconcile(catalogID: record.id, product: m4b, sourceSHA256: sourceHash)
    _ = try await store.reconcile(catalogID: record.id, product: m4b, sourceSHA256: sourceHash)
    let afterReconcile = try await store.load(record.id)
    XCTAssertEqual(afterReconcile.products.filter { $0.kind == .m4b }.count, 1)
    XCTAssertEqual(afterReconcile.product(.m4b)?.sha256, firstM4B)

    // A reprocess replaces the M4B under a digest guard. The guard makes it
    // single-shot: a second replace still expecting the old digest must fail,
    // proving the second catalog pass has to skip an already-replaced product.
    let replacement = BookCatalogProduct(
      kind: .m4b, path: "/tmp/book.m4b", size: 8192, sha256: secondM4B, verifiedAt: Date())
    _ = try await store.replace(
      catalogID: record.id, product: replacement, expectedCurrentSHA256: firstM4B,
      sourceSHA256: sourceHash)
    let afterReplace = try await store.load(record.id)
    XCTAssertEqual(afterReplace.product(.m4b)?.sha256, secondM4B)
    do {
      _ = try await store.replace(
        catalogID: record.id, product: replacement, expectedCurrentSHA256: firstM4B,
        sourceSHA256: sourceHash)
      XCTFail("replacing twice against a stale expected digest must conflict")
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
    XCTAssertTrue(
      catalog.issues.isEmpty,
      "legacy JSON is inactive after SQLite becomes authoritative")

    let legacyRoot = temporary.appendingPathComponent("LegacyCatalog")
    let legacyDatabase = temporary.appendingPathComponent("legacy-library.sqlite")
    let corruptBeforeMigration = BookCatalogStore(
      root: legacyRoot, databaseURL: legacyDatabase)
    let legacyCorruptID = UUID()
    let directory = await corruptBeforeMigration.recordDirectory(legacyCorruptID)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("not json".utf8).write(to: directory.appendingPathComponent("record.json"))
    do {
      _ = try await corruptBeforeMigration.scan()
      XCTFail("atomic migration must stop instead of silently dropping corrupt legacy records")
    } catch let error as BookJobError {
      guard case .corruptState = error else { return XCTFail("unexpected error: \(error)") }
    }
  }

  func testLegacyCatalogMigratesAtomicallyAndBecomesReadOnlyInput() async throws {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let root = temporary.appendingPathComponent("book-catalog")
    let database = temporary.appendingPathComponent("library.sqlite")
    let id = UUID()
    let directory = root.appendingPathComponent(id.uuidString.lowercased())
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let record = BookCatalogRecord(
      id: id,
      source: .init(
        format: "epub", importerVersion: 1,
        sha256: String(repeating: "c", count: 64), size: 42),
      metadata: .init(title: "Legacy", author: "Author"),
      outputDirectory: "/tmp/Processed", outputBaseName: "Legacy - Author",
      products: [
        .init(
          kind: .sourceEPUB, path: "/tmp/Processed/Legacy - Author (E).epub",
          size: 42, sha256: String(repeating: "c", count: 64), verifiedAt: Date())
      ])
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let legacyURL = directory.appendingPathComponent("record.json")
    let legacyData = try encoder.encode(record)
    try legacyData.write(to: legacyURL)

    let store = BookCatalogStore(root: root, databaseURL: database)
    let scan = try await store.scan()
    XCTAssertEqual(scan.records.map(\.id), [id])
    XCTAssertEqual(try Data(contentsOf: legacyURL), legacyData)
    XCTAssertTrue(FileManager.default.fileExists(atPath: database.path))
  }

  func testStudioSettingsAndSchedulerPersistence() async throws {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let settingsStore = StudioSettingsStore(url: temporary.appendingPathComponent("settings.json"))
    let home = URL(fileURLWithPath: "/Users/example")
    let defaultSettings = try await settingsStore.load()
    XCTAssertEqual(
      defaultSettings.resolvedProcessedDirectory(home: home).path,
      "/Users/example/Books/SpokenFolio")
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

    try await scheduler.save(
      BookSchedulerState(isSuspended: true, nextQueueSequence: UInt64.max - 1))
    do {
      _ = try await scheduler.reserve(count: 2)
      XCTFail("overflowing queue reservations must fail")
    } catch {}
  }

  func testStateWritesRejectDuplicateProductsAndCorruptControlFailsClosed() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = BookJobStore(root: root)
    let value = request()
    var state = try await store.create(value)
    let product = BookJobProduct(
      kind: .m4b, path: "/tmp/fixture.m4b", size: 1,
      sha256: String(repeating: "b", count: 64), verifiedAt: Date())
    state.products = [product, product]
    do {
      try await store.saveState(state)
      XCTFail("duplicate products must not be persisted")
    } catch {}

    let controlURL = await store.jobDirectory(value.id).appendingPathComponent("control.json")
    try Data("not json".utf8).write(to: controlURL)
    do {
      try await store.requestCancellation(value.id, attempt: 1)
      XCTFail("a corrupt control file must not be replaced")
    } catch {}
    XCTAssertEqual(try Data(contentsOf: controlURL), Data("not json".utf8))
  }

  func testCrashRecoveryClearsStaleRunningStage() throws {
    var state = BookJobState(jobID: UUID(), requestSHA256: "hash")
    try state.transition(to: .running)
    try state.updateStage(.m4bSynthesis, status: .running, fraction: 0.4)
    let startedAt = state.stages.first(where: { $0.stage == .m4bSynthesis })?.startedAt
    XCTAssertNotNil(startedAt)
    state.lastError = "stale"
    try state.prepareForRetry()
    XCTAssertEqual(state.lifecycle, .running)
    XCTAssertNil(state.lastError)
    XCTAssertEqual(
      state.stages.first(where: { $0.stage == .m4bSynthesis })?.status, .pending)
    XCTAssertNil(state.stages.first(where: { $0.stage == .m4bSynthesis })?.startedAt)
    XCTAssertFalse(state.stages.contains(where: { $0.status == .running }))
  }

  func testTouchAdvancesRevisionForDirectProgressMutations() throws {
    var state = BookJobState(jobID: UUID(), requestSHA256: "hash")
    let revision = state.revision
    state.audiobookProgress = .init(
      totalChapters: 2, totalCharacters: 100, reusedChapters: 0,
      chapterCharacters: [50, 50])
    try state.touch()
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

import BookJobKit
import LibraryKit
import CryptoKit
import Foundation
import TTSKit
import XCTest

@testable import SpokenFolioApp

final class BookJobExecutorTests: XCTestCase {
  private struct ComplianceFailure: LocalizedError {
    var errorDescription: String? { "fixture compliance failure" }
  }

  func testExistingExpressiveJobWorkersAreClampedAtExecution() {
    let expressive = BookJobRequest.Narration(
      backendID: "siri-fm", modelID: "siri-expressive", voiceID: "en-US-F",
      includedSectionIDs: [], bitrateKbps: 64, workers: 8,
      paragraphPauseSeconds: 0.6, chapterPauseSeconds: 1.75, announceTitles: true)
    let installed = BookJobRequest.Narration(
      backendID: "siri", modelID: "siri-private", voiceID: "voice",
      includedSectionIDs: [], bitrateKbps: 64, workers: 8,
      paragraphPauseSeconds: 0.6, chapterPauseSeconds: 1.75, announceTitles: true)

    XCTAssertEqual(BookJobExecutor.effectiveAudiobookWorkers(for: expressive), 1)
    XCTAssertEqual(BookJobExecutor.effectiveAudiobookWorkers(for: installed), 8)
  }

  func testPersistedPauseAndCancelIntentMapToDistinctLifecycles() {
    XCTAssertEqual(
      BookJobExecutor.interruptedLifecycle(
        control: BookJobControl(
          interruption: .init(attempt: 3, kind: .pause)), attempt: 3),
      .paused)
    XCTAssertEqual(
      BookJobExecutor.interruptedLifecycle(
        control: BookJobControl(
          interruption: .init(attempt: 3, kind: .cancel)), attempt: 3),
      .cancelled)
    XCTAssertEqual(
      BookJobExecutor.interruptedLifecycle(
        control: BookJobControl(
          interruption: .init(attempt: 2, kind: .cancel)), attempt: 3),
      .paused, "stale intent must not cancel a later attempt")
  }

  /// The ReadAloud delivery quality gate: an acceptable completed audit
  /// clears delivery, any other completed audit blocks it (rather than
  /// silently re-auditing forever), and no completed audit means one must be
  /// run inline before deciding — the change that lets "Send to Storyteller"
  /// run the audit itself instead of failing.
  func testDeliveryQualityGateDecision() throws {
    func run(verdict: String?, adequacy: String?) -> LibraryReadAloudAuditRun {
      LibraryReadAloudAuditRun(
        target: .localProduct(UUID()), mode: "standard", lifecycle: .completed,
        verdict: verdict, evidenceAdequacy: adequacy)
    }
    // No completed audit → run one inline.
    XCTAssertEqual(BookJobExecutor.deliveryQualityGate(nil), .needsAudit)
    // Clean pass → deliver silently.
    XCTAssertEqual(
      BookJobExecutor.deliveryQualityGate(run(verdict: "likelyCorrect", adequacy: "complete")),
      .acceptable)
    XCTAssertEqual(
      BookJobExecutor.deliveryQualityGate(run(verdict: "likelyCorrect", adequacy: "sampled")),
      .acceptable)
    // The delivery bar equals the CREATION bar: only confirmed broken blocks.
    XCTAssertEqual(
      BookJobExecutor.deliveryQualityGate(run(verdict: "likelyBroken", adequacy: "complete")),
      .blocked(verdict: "likelyBroken"))
    XCTAssertEqual(
      BookJobExecutor.deliveryQualityGate(run(verdict: "broken", adequacy: "complete")),
      .blocked(verdict: "broken"))
    // Borderline verdicts (needsReview, weak evidence) deliver WITH a
    // recorded warning — an artifact this pipeline published locally is
    // sendable, never silently borderline.
    XCTAssertEqual(
      BookJobExecutor.deliveryQualityGate(run(verdict: "needsReview", adequacy: "complete")),
      .acceptableWithWarning(verdict: "needsReview"))
    XCTAssertEqual(
      BookJobExecutor.deliveryQualityGate(run(verdict: "likelyCorrect", adequacy: "insufficient")),
      .acceptableWithWarning(verdict: "likelyCorrect"))
    XCTAssertEqual(
      BookJobExecutor.deliveryQualityGate(run(verdict: "inconclusive", adequacy: "complete")),
      .acceptableWithWarning(verdict: "inconclusive"))
  }

  func testStorytellerReportMapsAudioFilepathsToTranscriptNames() throws {
    let report = try JSONSerialization.data(withJSONObject: [
      "chapters": [
        ["audioFiles": [["filepath": "/assets/audio/chapter-01.mp4"]]],
        ["audioFiles": [["filepath": "chapter-02.m4a"]]],
      ],
      "unrelated": "must-not-be-treated-as.json",
    ])
    XCTAssertEqual(
      ReadAloudAuditService.transcriptionCandidates(report),
      ["chapter-01.json", "chapter-02.json"])
  }

  func testActualNarrationUsesAuthoritativeChildProvenance() throws {
    let requested = BookJobRequest.Narration(
      backendID: "siri-fm", modelID: "siri-expressive", voiceID: "en-US-F",
      pacePreset: 2, expressivityPreset: 5,
      includedSectionIDs: [], bitrateKbps: 64, workers: 1,
      paragraphPauseSeconds: 0.6, chapterPauseSeconds: 1.75, announceTitles: true)
    let provenance = try TTSRuntimeProvenance(
      backendID: TTSBackendID(rawValue: "siri-fm"), modelID: "siri-expressive",
      voiceID: "en-US-F",
      operatingSystemVersion: "27.0", operatingSystemBuild: "26A1",
      frameworkIdentifier: "com.apple.siri.SiriTTSService", frameworkVersion: "1",
      adapterIdentifier: "com.apple.fm.language.instruct_3b.voice",
      backendAdapterRevision: "adapter-2",
      modelRevision: "model-2", voiceRevision: "voice-3",
      resourceIdentity: "en-US", resourceRevision: "resource-4")

    let actual = try BookJobExecutor.actualNarration(
      requested: requested, runtimeProvenance: provenance)

    XCTAssertEqual(actual.modelRevision, "model-2")
    XCTAssertEqual(actual.voiceRevision, "voice-3")
    XCTAssertEqual(actual.runtime?.adapterIdentifier, "com.apple.fm.language.instruct_3b.voice")
    XCTAssertEqual(actual.runtime?.backendAdapterRevision, "adapter-2")
    XCTAssertEqual(actual.runtime?.resourceIdentity, "en-US")
    XCTAssertEqual(actual.runtime?.resourceRevision, "resource-4")
  }

  func testActualNarrationRejectsDifferentVoiceProvenance() throws {
    let requested = BookJobRequest.Narration(
      backendID: "siri", modelID: "siri-private", voiceID: "expected",
      includedSectionIDs: [], bitrateKbps: 64, workers: 1,
      paragraphPauseSeconds: 0.6, chapterPauseSeconds: 1.75, announceTitles: true)
    let provenance = try TTSRuntimeProvenance(
      backendID: TTSBackendID(rawValue: "siri"), modelID: "siri-private",
      voiceID: "different",
      operatingSystemVersion: "27.0", operatingSystemBuild: "26A1",
      frameworkIdentifier: "com.apple.siri.SiriTTSService", frameworkVersion: "1")

    XCTAssertThrowsError(
      try BookJobExecutor.actualNarration(
        requested: requested, runtimeProvenance: provenance))
  }

  private func request(root: URL) throws -> BookJobRequest {
    let source = root.appendingPathComponent("book.epub")
    let data = Data("not an epub".utf8)
    try data.write(to: source)
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return BookJobRequest(
      title: "Fixture", author: nil,
      source: .init(path: source.path, sha256: digest, format: "epub", importerVersion: 1),
      narration: .init(
        backendID: "siri", modelID: "siri-private", voiceID: "invalid",
        includedSectionIDs: [], bitrateKbps: 64, workers: 1,
        paragraphPauseSeconds: 0.6, chapterPauseSeconds: 1.75, announceTitles: true),
      m4bOutputPath: root.appendingPathComponent("out.m4b").path)
  }

  func testJobStartFailsBeforePublishingSourceWhenComplianceGateRejects() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let value = try request(root: root)
    let store = BookJobStore(root: root.appendingPathComponent("jobs"))
    _ = try await store.create(value)

    do {
      try await BookJobExecutor(
        store: store, audiobookExecutable: URL(fileURLWithPath: "/usr/bin/false"),
        executionLockURL: nil, validateEPUB: { _ in throw ComplianceFailure() }
      ).run(id: value.id)
      XCTFail("a rejected EPUB must stop the job")
    } catch is ComplianceFailure {}

    let state = try await store.loadState(value.id)
    XCTAssertEqual(state.lifecycle, .needsAttention)
    XCTAssertEqual(state.lastError, "fixture compliance failure")
    XCTAssertTrue(state.products.isEmpty)
  }

  func testStaleRunningStateIsRecoveredBeforeAttempt() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appendingPathComponent("invalid.epub")
    let sourceData = Data("not an epub".utf8)
    try sourceData.write(to: source)
    let digest = SHA256.hash(data: sourceData).map { String(format: "%02x", $0) }.joined()
    let request = BookJobRequest(
      title: "Crash recovery", author: nil,
      source: .init(path: source.path, sha256: digest, format: "epub", importerVersion: 1),
      narration: .init(
        backendID: "siri", modelID: "siri-private", voiceID: "invalid",
        includedSectionIDs: [], bitrateKbps: 64, workers: 1,
        paragraphPauseSeconds: 0.6, chapterPauseSeconds: 1.75, announceTitles: true),
      m4bOutputPath: root.appendingPathComponent("out.m4b").path)
    let store = BookJobStore(root: root.appendingPathComponent("jobs"))
    var state = try await store.create(request)
    try state.transition(to: .running)
    try state.updateStage(.m4bSynthesis, status: .running, fraction: 0.2)
    try await store.saveState(state)

    do {
      try await BookJobExecutor(
        store: store, audiobookExecutable: URL(fileURLWithPath: "/usr/bin/false"),
        executionLockURL: nil
      ).run(id: request.id)
      XCTFail("invalid source should not complete")
    } catch {}

    let recovered = try await store.loadState(request.id)
    let control = try await store.loadControl(request.id)
    XCTAssertEqual(recovered.lifecycle, .needsAttention)
    XCTAssertEqual(control.queueDisposition, .held)
    XCTAssertFalse(recovered.stages.contains(where: { $0.status == .running }))
    XCTAssertFalse(recovered.lastError?.contains("only one job stage") == true)
  }

  func testCancelDuringQueuedLaunchTargetsNextAttempt() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = BookJobStore(root: root.appendingPathComponent("jobs"))
    let value = try request(root: root)
    _ = try await store.create(value)
    let runner = BookJobProcessRunner(
      executable: URL(fileURLWithPath: "/usr/bin/false"), store: store)
    let stream = runner.run(id: value.id)
    try await runner.interrupt(.cancel)
    for _ in 0..<100 {
      if try await store.loadControl(value.id).cancelRequestedForAttempt == 1 { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    let control = try await store.loadControl(value.id)
    XCTAssertEqual(control.cancelRequestedForAttempt, 1)
    XCTAssertEqual(control.interruption?.kind, .cancel)
    _ = stream
  }

  func testDeliveryOnlyJobSkipsSynthesisAndVerifiesSelectedSource() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    var value = try request(root: root)
    value.operation = .storytellerDelivery
    value.storyteller = .init(
      connectionID: UUID(),
      remoteBookID: UUID(),
      products: [.sourceEPUB])
    let store = BookJobStore(root: root.appendingPathComponent("jobs"))
    _ = try await store.create(value)

    do {
      try await BookJobExecutor(
        store: store, audiobookExecutable: URL(fileURLWithPath: "/usr/bin/false"),
        executionLockURL: nil, validateEPUB: { _ in }
      ).run(id: value.id)
      XCTFail("the intentionally missing Storyteller connection must stop delivery")
    } catch {}

    let state = try await store.loadState(value.id)
    XCTAssertEqual(state.products.map(\.kind), [.sourceEPUB])
    XCTAssertEqual(
      state.stages.first(where: { $0.stage == .m4bSynthesis })?.status, .skipped)
    XCTAssertFalse(FileManager.default.fileExists(atPath: value.m4bOutputPath))
  }
}

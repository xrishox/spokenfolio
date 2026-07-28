import Foundation
import LocalTTSWorkerKit
import TTSKit
import XCTest

@testable import SpokenFolioApp

final class WorkerBackedTTSServiceTests: XCTestCase {
  private actor PreparationRecorder {
    private(set) var selections: [TTSVoiceSelection] = []
    func append(_ selection: TTSVoiceSelection) { selections.append(selection) }
  }

  private final class RecordingSession: TTSSession, @unchecked Sendable {
    let recorder: PreparationRecorder

    init(recorder: PreparationRecorder) { self.recorder = recorder }

    func prepare(
      selection: TTSVoiceSelection
    ) async throws -> TTSRuntimeProvenance {
      await recorder.append(selection)
      return try testProvenance(selection)
    }

    func synthesize(request: TTSSynthesisRequest) async throws -> TTSSynthesisResult {
      TTSSynthesisResult(
        audio: try PCM16Audio(data: Data([0, 0]), sampleRate: 48_000, channels: 1))
    }

    func shutdown() async {}
  }

  private final class LoaderCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var loads = 0
    let composition: LocalTTSComposition

    init(composition: LocalTTSComposition) { self.composition = composition }

    func load() -> LocalTTSComposition {
      lock.withLock { loads += 1 }
      return composition
    }

    var count: Int { lock.withLock { loads } }
  }

  private struct FakeFactory: LocalTTSWorkerBackendFactory {
    let id: TTSBackendID
    let voices: [VoiceDescriptor]
    let defaultVoice: VoiceKey
    let session: RecordingSession
    let makeTransport: @Sendable (VoiceKey) throws -> any LocalTTSWorkerTransport

    var models: [TTSModelDescriptor] {
      [
        TTSModelDescriptor(
          key: TTSModelKey(backendID: id, modelID: "test-model"),
          name: "Test Model", revision: "model-1", defaultVoice: defaultVoice,
          controls: TTSControlCapabilities(pace: true, expressivity: true))
      ]
    }

    init(
      recorder: PreparationRecorder, backendID: String = "test-backend",
      makeTransport: @escaping @Sendable (VoiceKey) throws -> any LocalTTSWorkerTransport = {
        _ in throw TTSBackendError.unavailable
      }
    ) {
      id = TTSBackendID(rawValue: backendID)
      let first = VoiceKey(backendID: id, modelID: "test-model", voiceID: "first")
      let configured = VoiceKey(backendID: id, modelID: "test-model", voiceID: "configured")
      defaultVoice = first
      voices = [
        VoiceDescriptor(
          key: first, name: "First", language: "en-US", quality: "test"),
        VoiceDescriptor(
          key: configured, name: "Configured", language: "en-US", quality: "test"),
      ]
      session = RecordingSession(recorder: recorder)
      self.makeTransport = makeTransport
    }

    func resolveVoice(_ requested: String) -> VoiceKey? {
      voices.first { $0.key.voiceID == requested }?.key
    }

    func makeWorkerClient(for voice: VoiceKey) throws -> any LocalTTSWorkerTransport {
      try makeTransport(voice)
    }

    func makeSession(configuration: TTSWorkloadConfiguration) throws -> any TTSSession {
      session
    }

    func makeSession(
      configuration: TTSWorkloadConfiguration,
      sharedWorkerPool: LocalTTSWorkerPool
    ) throws -> any TTSSession {
      PoolBackedSession(pool: sharedWorkerPool, recorder: session.recorder)
    }
  }

  private final class PoolBackedSession: TTSSession, @unchecked Sendable {
    let pool: LocalTTSWorkerPool
    let recorder: PreparationRecorder

    init(pool: LocalTTSWorkerPool, recorder: PreparationRecorder) {
      self.pool = pool
      self.recorder = recorder
    }

    func prepare(
      selection: TTSVoiceSelection
    ) async throws -> TTSRuntimeProvenance {
      await recorder.append(selection)
      return try testProvenance(selection)
    }

    func synthesize(request: TTSSynthesisRequest) async throws -> TTSSynthesisResult {
      let result = try await pool.synthesize(request)
      return TTSSynthesisResult(
        audio: result.audio, timings: result.timings, provenance: result.provenance)
    }

    func shutdown() async {}
  }

  private actor TransportGate {
    private(set) var started = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var released = false

    func begin() async {
      started += 1
      if released { return }
      await withCheckedContinuation { waiters.append($0) }
    }

    func releaseAll() {
      released = true
      let queued = waiters
      waiters.removeAll()
      for waiter in queued { waiter.resume() }
    }
  }

  private final class BlockingTransport: LocalTTSWorkerTransport, @unchecked Sendable {
    let gate: TransportGate

    init(gate: TransportGate) { self.gate = gate }

    func synthesize(
      request: TTSSynthesisRequest, deadline: ContinuousClock.Instant
    ) async throws -> LocalTTSWorkerResult {
      await gate.begin()
      return LocalTTSWorkerResult(
        audio: try PCM16Audio(data: Data([1, 0]), sampleRate: 48_000, channels: 1))
    }

    func terminateHard() {}
  }

  func testConfiguredSelectionIsPreparedAndUsedForOmittedRequestFields() async throws {
    let recorder = PreparationRecorder()
    let factory = FakeFactory(recorder: recorder)
    let config = ServerConfig(
      defaultTTS: DefaultTTSConfig(
        backendID: factory.id.rawValue, modelID: "test-model", voiceID: "configured",
        pacePreset: 2, expressivityPreset: 5))
    let service = try WorkerBackedTTSService(
      config: config, factories: [factory],
      publicModelKeys: [
        "test-public": TTSModelKey(backendID: factory.id, modelID: "test-model")
      ])

    try await service.initialize()

    let prepared = await recorder.selections
    XCTAssertEqual(prepared, [service.defaultSelection])
    let resolved = try service.resolveSelection(
      model: "test-public", voice: nil, pace: nil, expressivity: nil)
    XCTAssertEqual(resolved.voice.voiceID, "configured")
    XCTAssertEqual(resolved.controls.pace?.rawValue, 2)
    XCTAssertEqual(resolved.controls.expressivity?.rawValue, 5)
  }

  func testResolverRejectsInvalidConfiguredVoiceWithoutHidingCatalog() throws {
    let factory = FakeFactory(recorder: PreparationRecorder())
    let composition = try LocalTTSComposition(
      factories: [factory],
      publicModelKeys: [
        "test-public": TTSModelKey(backendID: factory.id, modelID: "test-model")
      ])
    let resolver = TTSSelectionResolver(composition: composition)

    XCTAssertThrowsError(
      try resolver.configuredDefault(
        configuredVoice: "missing", configuredDefault: nil))
    XCTAssertEqual(composition.registry.voices.count, 2)
  }

  func testInventoryProviderCoalescesConcurrentDiscovery() async throws {
    let factory = FakeFactory(recorder: PreparationRecorder())
    let composition = try LocalTTSComposition(
      factories: [factory],
      publicModelKeys: [
        "test-public": TTSModelKey(backendID: factory.id, modelID: "test-model")
      ])
    let counter = LoaderCounter(composition: composition)
    let provider = TTSInventoryProvider(loader: counter.load)

    async let first = provider.inventory(configuredVoice: nil)
    async let second = provider.inventory(configuredVoice: nil)
    _ = try await (first, second)

    XCTAssertEqual(counter.count, 1)
  }

  func testAudiobookSynthesizerRejectsInconsistentWorkerProvenance() async throws {
    let backendID = TTSBackendID(rawValue: "test-backend")
    let selection = TTSVoiceSelection(
      voice: VoiceKey(backendID: backendID, modelID: "test-model", voiceID: "voice"))
    let expected = try testProvenance(selection)
    let mismatched = try TTSRuntimeProvenance(
      backendID: backendID, modelID: "test-model", voiceID: "voice",
      operatingSystemVersion: "27.0", operatingSystemBuild: "26A1",
      frameworkIdentifier: "test.framework", frameworkVersion: "1",
      resourceIdentity: "different-resource")
    let synthesizer = SessionNarrationSynthesizer(
      session: ProvenanceSession(provenance: mismatched), selection: selection,
      expectedProvenance: expected)

    do {
      _ = try await synthesizer.synthesize(text: "hello")
      XCTFail("mismatched runtime provenance unexpectedly synthesized")
    } catch let error as TTSBackendError {
      guard case .inconsistentRuntimeProvenance = error else {
        return XCTFail("unexpected error: \(error)")
      }
    }
  }

  func testHTTPWorkersAndQueueAreGlobalAcrossBackends() async throws {
    let gate = TransportGate()
    let recorder = PreparationRecorder()
    let first = FakeFactory(
      recorder: recorder, backendID: "backend-a",
      makeTransport: { _ in BlockingTransport(gate: gate) })
    let second = FakeFactory(
      recorder: recorder, backendID: "backend-b",
      makeTransport: { _ in BlockingTransport(gate: gate) })
    let service = try WorkerBackedTTSService(
      config: ServerConfig(maxWorkers: 1, maxQueuedRequests: 1),
      factories: [first, second],
      publicModelKeys: [
        "public-a": TTSModelKey(backendID: first.id, modelID: "test-model"),
        "public-b": TTSModelKey(backendID: second.id, modelID: "test-model"),
      ])

    func request(_ backend: FakeFactory) -> TTSSynthesisRequest {
      TTSSynthesisRequest(
        text: "hello",
        selection: TTSVoiceSelection(
          voice: backend.defaultVoice,
          controls: TTSSynthesisControls(pace: .neutral, expressivity: .neutral)))
    }

    let running = Task { try await service.synthesize(request: request(first)) }
    while await gate.started < 1 { try await Task.sleep(for: .milliseconds(2)) }
    let queued = Task { try await service.synthesize(request: request(second)) }
    while await service.debugQueuedWorkerRequests < 1 {
      try await Task.sleep(for: .milliseconds(2))
    }

    do {
      _ = try await service.synthesize(request: request(second))
      XCTFail("the global HTTP queue bound should reject a third request")
    } catch let error as ServiceError {
      guard case .queueFull(1) = error else {
        return XCTFail("unexpected error: \(error)")
      }
    }

    await gate.releaseAll()
    _ = try await running.value
    _ = try await queued.value
    await service.shutdown()
  }
}

private final class ProvenanceSession: TTSSession, @unchecked Sendable {
  let provenance: TTSRuntimeProvenance

  init(provenance: TTSRuntimeProvenance) { self.provenance = provenance }

  func prepare(selection: TTSVoiceSelection) async throws -> TTSRuntimeProvenance {
    provenance
  }

  func synthesize(request: TTSSynthesisRequest) async throws -> TTSSynthesisResult {
    TTSSynthesisResult(
      audio: try PCM16Audio(data: Data([0, 0]), sampleRate: 48_000, channels: 1),
      provenance: provenance)
  }

  func shutdown() async {}
}

private func testProvenance(_ selection: TTSVoiceSelection) throws -> TTSRuntimeProvenance {
  try TTSRuntimeProvenance(
    backendID: selection.voice.backendID, modelID: selection.voice.modelID,
    voiceID: selection.voice.voiceID,
    operatingSystemVersion: "27.0", operatingSystemBuild: "26A1",
    frameworkIdentifier: "test.framework", frameworkVersion: "1")
}

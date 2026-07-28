import Foundation
import TTSKit
import XCTest

@testable import LocalTTSWorkerKit

final class LocalTTSWorkerPoolTests: XCTestCase {
  private static let voice = VoiceKey(
    backendID: TTSBackendID(rawValue: "test-backend"),
    modelID: "test-model",
    voiceID: "test-voice")

  func testQueuedCancellationRemovesWaiterWithoutAffectingRunningRequest() async throws {
    let gate = SynthesisGate()
    let pool = LocalTTSWorkerPool(
      maxWorkers: 1, maxQueued: 2, deadlineSeconds: 30,
      makeClient: { _ in BlockingWorker(gate: gate) })

    let runningRequest = Self.request(text: "first")
    let queuedRequest = Self.request(text: "second")
    let running = Task { try await pool.synthesize(runningRequest) }
    try await waitUntil { await gate.startedCount == 1 }

    let queued = Task { try await pool.synthesize(queuedRequest) }
    try await waitUntil { await pool.queuedRequestCount == 1 }
    queued.cancel()

    do {
      _ = try await queued.value
      XCTFail("cancelled waiter unexpectedly synthesized")
    } catch is CancellationError {
      // Expected.
    }
    let queuedCount = await pool.queuedRequestCount
    XCTAssertEqual(queuedCount, 0)

    await gate.releaseAll()
    let result = try await running.value
    XCTAssertEqual(result.audio.data, Data([1, 2]))
    await pool.shutdown()
  }

  func testQueueBoundRejectsExcessWaiter() async throws {
    let gate = SynthesisGate()
    let pool = LocalTTSWorkerPool(
      maxWorkers: 1, maxQueued: 1, deadlineSeconds: 30,
      makeClient: { _ in BlockingWorker(gate: gate) })

    let runningRequest = Self.request(text: "first")
    let queuedRequest = Self.request(text: "second")
    let running = Task { try await pool.synthesize(runningRequest) }
    try await waitUntil { await gate.startedCount == 1 }
    let queued = Task { try await pool.synthesize(queuedRequest) }
    try await waitUntil { await pool.queuedRequestCount == 1 }

    do {
      _ = try await pool.synthesize(Self.request(text: "third"))
      XCTFail("request exceeded the configured queue bound")
    } catch let error as TTSBackendError {
      guard case .queueFull(1) = error else { return XCTFail("unexpected error: \(error)") }
    }

    queued.cancel()
    await gate.releaseAll()
    _ = try await running.value
    _ = try? await queued.value
    await pool.shutdown()
  }

  func testQueuedRequestExpiresWithinOriginalDeadline() async throws {
    let gate = SynthesisGate()
    let pool = LocalTTSWorkerPool(
      maxWorkers: 1, maxQueued: 1, deadlineSeconds: 0.05,
      makeClient: { _ in BlockingWorker(gate: gate) })

    let runningRequest = Self.request(text: "first")
    let running = Task { try await pool.synthesize(runningRequest) }
    try await waitUntil { await gate.startedCount == 1 }
    do {
      _ = try await pool.synthesize(Self.request(text: "queued"))
      XCTFail("queued request outlived its deadline")
    } catch let error as TTSBackendError {
      guard case .timeout = error else { return XCTFail("unexpected error: \(error)") }
    }
    let count = await pool.queuedRequestCount
    XCTAssertEqual(count, 0)
    await gate.releaseAll()
    _ = try await running.value
    await pool.shutdown()
  }

  func testCrashRetriesOnceWithReplacementWorker() async throws {
    let factory = ScriptedWorkerFactory([
      .failure(.protocolFailure),
      .success(Data([9, 8, 7, 6])),
    ])
    let pool = LocalTTSWorkerPool(
      maxWorkers: 1, maxQueued: 1, deadlineSeconds: 5,
      makeClient: { _ in factory.make() })

    let result = try await pool.synthesize(Self.request(text: "test"))
    XCTAssertEqual(result.audio.data, Data([9, 8, 7, 6]))
    let diagnostics = await pool.diagnosticsSnapshot()
    XCTAssertEqual(diagnostics.retries, 1)
    XCTAssertEqual(diagnostics.crashes, 1)
    XCTAssertEqual(diagnostics.workersSpawned, 2)
    await pool.shutdown()
  }

  /// A transient engine refusal (worker answers `remote` failure, not a
  /// crash) gets the same single retry a crash gets, on a fresh worker —
  /// observed in production: the Siri engine refused ordinary paragraphs
  /// that synthesized fine moments later, and first-strike failures killed
  /// multi-hour audiobook jobs.
  func testEngineRefusalRetriesOnceWithReplacementWorker() async throws {
    let factory = ScriptedWorkerFactory([
      .failure(.remote("engine_error")),
      .success(Data([5, 5, 5, 5])),
    ])
    let pool = LocalTTSWorkerPool(
      maxWorkers: 1, maxQueued: 1, deadlineSeconds: 5,
      makeClient: { _ in factory.make() })

    let result = try await pool.synthesize(Self.request(text: "refused once"))
    XCTAssertEqual(result.audio.data, Data([5, 5, 5, 5]))
    let diagnostics = await pool.diagnosticsSnapshot()
    XCTAssertEqual(diagnostics.retries, 1)
    XCTAssertEqual(diagnostics.crashes, 0, "a refusal is not a crash and must not trip the circuit")
    XCTAssertEqual(diagnostics.workersSpawned, 2, "the refusing worker is recycled")
    await pool.shutdown()
  }

  /// A deterministic refusal (both attempts refused) still surfaces as
  /// `synthesisFailed`, so truly unspeakable input is not retried forever.
  func testPersistentEngineRefusalStillFails() async throws {
    let factory = ScriptedWorkerFactory([
      .failure(.remote("engine_error")),
      .failure(.remote("engine_error")),
    ])
    let pool = LocalTTSWorkerPool(
      maxWorkers: 1, maxQueued: 1, deadlineSeconds: 5,
      makeClient: { _ in factory.make() })
    do {
      _ = try await pool.synthesize(Self.request(text: "always refused"))
      XCTFail("a persistent refusal must fail")
    } catch let error as TTSBackendError {
      guard case .synthesisFailed = error else { return XCTFail("unexpected: \(error)") }
    }
    let diagnostics = await pool.diagnosticsSnapshot()
    XCTAssertEqual(diagnostics.crashes, 0)
    await pool.shutdown()
  }

  func testThreeCrashesOpenCircuitWithoutSpawningMoreWorkers() async {
    let factory = ScriptedWorkerFactory(Array(repeating: .failure(.protocolFailure), count: 5))
    let pool = LocalTTSWorkerPool(
      maxWorkers: 1, maxQueued: 1, deadlineSeconds: 5,
      makeClient: { _ in factory.make() })

    _ = try? await pool.synthesize(Self.request(text: "first"))
    _ = try? await pool.synthesize(Self.request(text: "second"))
    let createdBefore = factory.createdCount
    do {
      _ = try await pool.synthesize(Self.request(text: "third"))
      XCTFail("open circuit accepted another request")
    } catch let error as TTSBackendError {
      guard case .unavailable = error else { return XCTFail("unexpected error: \(error)") }
    } catch {
      XCTFail("unexpected error: \(error)")
    }
    XCTAssertEqual(factory.createdCount, createdBefore)
    let diagnostics = await pool.diagnosticsSnapshot()
    XCTAssertEqual(diagnostics.crashes, 3)
    await pool.shutdown()
  }

  func testTimeoutsRecycleWithoutOpeningCrashCircuit() async throws {
    let factory = ScriptedWorkerFactory([
      .failure(.timeout), .failure(.timeout), .failure(.timeout),
      .success(Data([4, 2])),
    ])
    let pool = LocalTTSWorkerPool(
      maxWorkers: 1, maxQueued: 1, deadlineSeconds: 5,
      makeClient: { _ in factory.make() })

    for _ in 0..<3 {
      do {
        _ = try await pool.synthesize(Self.request(text: "slow"))
        XCTFail("timeout unexpectedly succeeded")
      } catch let error as TTSBackendError {
        guard case .timeout = error else { return XCTFail("unexpected error: \(error)") }
      }
    }
    let healthy = try await pool.synthesize(Self.request(text: "healthy"))
    XCTAssertEqual(healthy.audio.data, Data([4, 2]))
    let diagnostics = await pool.diagnosticsSnapshot()
    XCTAssertEqual(diagnostics.timeouts, 3)
    XCTAssertEqual(diagnostics.crashes, 0)
    await pool.shutdown()
  }

  func testShutdownIsTerminalAndCannotSpawnRetryWorker() async throws {
    let gate = SynthesisGate()
    let factory = ShutdownFactory(gate: gate)
    let pool = LocalTTSWorkerPool(
      maxWorkers: 1, maxQueued: 1, deadlineSeconds: 5,
      makeClient: { _ in factory.make() })
    let activeRequest = Self.request(text: "active")
    let active = Task { try await pool.synthesize(activeRequest) }
    try await waitUntil { await gate.startedCount == 1 }

    await pool.shutdown()
    await gate.releaseAll()
    do {
      _ = try await active.value
      XCTFail("shutdown request unexpectedly succeeded")
    } catch let error as TTSBackendError {
      guard case .unavailable = error else { return XCTFail("unexpected error: \(error)") }
    }
    do {
      _ = try await pool.synthesize(Self.request(text: "later"))
      XCTFail("post-shutdown request unexpectedly succeeded")
    } catch let error as TTSBackendError {
      guard case .unavailable = error else { return XCTFail("unexpected error: \(error)") }
    }
    XCTAssertEqual(factory.createdCount, 1)
  }

  private static func request(text: String) -> TTSSynthesisRequest {
    TTSSynthesisRequest(text: text, selection: TTSVoiceSelection(voice: voice))
  }

  private func waitUntil(
    timeout: Duration = .seconds(2), condition: @escaping @Sendable () async -> Bool
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !(await condition()) {
      guard clock.now < deadline else { throw TestFailure.timedOut }
      try await Task.sleep(for: .milliseconds(5))
    }
  }
}

private enum TestFailure: Error { case timedOut }

private actor SynthesisGate {
  private(set) var startedCount = 0
  private var isReleased = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    startedCount += 1
    guard !isReleased else { return }
    await withCheckedContinuation { waiters.append($0) }
  }

  func releaseAll() {
    isReleased = true
    let pending = waiters
    waiters.removeAll()
    for waiter in pending { waiter.resume() }
  }
}

private final class BlockingWorker: LocalTTSWorkerTransport, @unchecked Sendable {
  private let gate: SynthesisGate

  init(gate: SynthesisGate) { self.gate = gate }

  func synthesize(
    request: TTSSynthesisRequest, deadline: ContinuousClock.Instant
  ) async throws -> LocalTTSWorkerResult {
    await gate.wait()
    try Task.checkCancellation()
    return LocalTTSWorkerResult(
      audio: try PCM16Audio(data: Data([1, 2]), sampleRate: 48_000, channels: 1))
  }

  func terminateHard() {}
}

private final class ScriptedWorkerFactory: @unchecked Sendable {
  enum Result {
    case success(Data)
    case failure(LocalTTSWorkerClientError)
  }

  private let lock = NSLock()
  private var results: [Result]
  private var created = 0

  init(_ results: [Result]) { self.results = results }

  var createdCount: Int { lock.withLock { created } }

  func make() -> any LocalTTSWorkerTransport {
    let result: Result = lock.withLock {
      created += 1
      return results.isEmpty ? .failure(.protocolFailure) : results.removeFirst()
    }
    return ScriptedWorker(result: result)
  }
}

private final class ScriptedWorker: LocalTTSWorkerTransport, @unchecked Sendable {
  private let result: ScriptedWorkerFactory.Result
  init(result: ScriptedWorkerFactory.Result) { self.result = result }

  func synthesize(
    request: TTSSynthesisRequest, deadline: ContinuousClock.Instant
  ) async throws -> LocalTTSWorkerResult {
    switch result {
    case .success(let data):
      return LocalTTSWorkerResult(
        audio: try PCM16Audio(data: data, sampleRate: 48_000, channels: 1))
    case .failure(let error):
      throw error
    }
  }

  func terminateHard() {}
}

private final class ShutdownFactory: @unchecked Sendable {
  private let lock = NSLock()
  private let gate: SynthesisGate
  private var created = 0

  init(gate: SynthesisGate) { self.gate = gate }

  var createdCount: Int { lock.withLock { created } }

  func make() -> any LocalTTSWorkerTransport {
    lock.withLock { created += 1 }
    return ShutdownWorker(gate: gate)
  }
}

private final class ShutdownWorker: LocalTTSWorkerTransport, @unchecked Sendable {
  private let gate: SynthesisGate
  init(gate: SynthesisGate) { self.gate = gate }

  func synthesize(
    request: TTSSynthesisRequest, deadline: ContinuousClock.Instant
  ) async throws -> LocalTTSWorkerResult {
    await gate.wait()
    throw LocalTTSWorkerClientError.protocolFailure
  }

  func terminateHard() {}
}

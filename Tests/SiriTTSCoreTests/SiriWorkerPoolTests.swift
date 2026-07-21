import Foundation
import XCTest

@testable import SiriTTSCore

final class SiriWorkerPoolTests: XCTestCase {
  func testQueuedCancellationRemovesWaiterWithoutAffectingRunningRequest() async throws {
    let gate = SynthesisGate()
    let pool = SiriWorkerPool(
      maxWorkers: 1, maxQueued: 2, deadlineSeconds: 30,
      makeClient: { _ in BlockingWorker(gate: gate) })

    let running = Task { try await pool.synthesize(text: "first", voiceID: "voice") }
    try await waitUntil { await gate.startedCount == 1 }

    let queued = Task { try await pool.synthesize(text: "second", voiceID: "voice") }
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
    let audio = try await running.value
    XCTAssertEqual(audio, Data([1, 2]))
    await pool.shutdown()
  }

  func testQueueBoundRejectsExcessWaiter() async throws {
    let gate = SynthesisGate()
    let pool = SiriWorkerPool(
      maxWorkers: 1, maxQueued: 1, deadlineSeconds: 30,
      makeClient: { _ in BlockingWorker(gate: gate) })

    let running = Task { try await pool.synthesize(text: "first", voiceID: "voice") }
    try await waitUntil { await gate.startedCount == 1 }
    let queued = Task { try await pool.synthesize(text: "second", voiceID: "voice") }
    try await waitUntil { await pool.queuedRequestCount == 1 }

    do {
      _ = try await pool.synthesize(text: "third", voiceID: "voice")
      XCTFail("request exceeded the configured queue bound")
    } catch let error as ServiceError {
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
    let pool = SiriWorkerPool(
      maxWorkers: 1, maxQueued: 1, deadlineSeconds: 0.05,
      makeClient: { _ in BlockingWorker(gate: gate) })

    let running = Task { try await pool.synthesize(text: "first", voiceID: "voice") }
    try await waitUntil { await gate.startedCount == 1 }
    do {
      _ = try await pool.synthesize(text: "queued", voiceID: "voice")
      XCTFail("queued request outlived its deadline")
    } catch let error as ServiceError {
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
      .success(Data([9, 8, 7])),
    ])
    let pool = SiriWorkerPool(
      maxWorkers: 1, maxQueued: 1, deadlineSeconds: 5,
      makeClient: { _ in factory.make() })

    let result = try await pool.synthesize(text: "test", voiceID: "voice")
    XCTAssertEqual(result, Data([9, 8, 7]))
    let diagnostics = await pool.diagnosticsSnapshot()
    XCTAssertEqual(diagnostics.retries, 1)
    XCTAssertEqual(diagnostics.crashes, 1)
    XCTAssertEqual(diagnostics.workersSpawned, 2)
    await pool.shutdown()
  }

  func testThreeCrashesOpenCircuitWithoutSpawningMoreWorkers() async {
    let factory = ScriptedWorkerFactory(Array(repeating: .failure(.protocolFailure), count: 5))
    let pool = SiriWorkerPool(
      maxWorkers: 1, maxQueued: 1, deadlineSeconds: 5,
      makeClient: { _ in factory.make() })

    _ = try? await pool.synthesize(text: "first", voiceID: "voice")
    _ = try? await pool.synthesize(text: "second", voiceID: "voice")
    let createdBefore = factory.createdCount
    do {
      _ = try await pool.synthesize(text: "third", voiceID: "voice")
      XCTFail("open circuit accepted another request")
    } catch let error as ServiceError {
      guard case .engineUnavailable = error else { return XCTFail("unexpected error: \(error)") }
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
    let pool = SiriWorkerPool(
      maxWorkers: 1, maxQueued: 1, deadlineSeconds: 5,
      makeClient: { _ in factory.make() })

    for _ in 0..<3 {
      do {
        _ = try await pool.synthesize(text: "slow", voiceID: "voice")
        XCTFail("timeout unexpectedly succeeded")
      } catch let error as ServiceError {
        guard case .timeout = error else { return XCTFail("unexpected error: \(error)") }
      }
    }
    let healthy = try await pool.synthesize(text: "healthy", voiceID: "voice")
    XCTAssertEqual(healthy, Data([4, 2]))
    let diagnostics = await pool.diagnosticsSnapshot()
    XCTAssertEqual(diagnostics.timeouts, 3)
    XCTAssertEqual(diagnostics.crashes, 0)
    await pool.shutdown()
  }

  func testShutdownIsTerminalAndCannotSpawnRetryWorker() async throws {
    let gate = SynthesisGate()
    let factory = ShutdownFactory(gate: gate)
    let pool = SiriWorkerPool(
      maxWorkers: 1, maxQueued: 1, deadlineSeconds: 5,
      makeClient: { _ in factory.make() })
    let active = Task { try await pool.synthesize(text: "active", voiceID: "voice") }
    try await waitUntil { await gate.startedCount == 1 }

    await pool.shutdown()
    await gate.releaseAll()
    do {
      _ = try await active.value
      XCTFail("shutdown request unexpectedly succeeded")
    } catch let error as ServiceError {
      guard case .engineUnavailable = error else { return XCTFail("unexpected error: \(error)") }
    }
    do {
      _ = try await pool.synthesize(text: "later", voiceID: "voice")
      XCTFail("post-shutdown request unexpectedly succeeded")
    } catch let error as ServiceError {
      guard case .engineUnavailable = error else { return XCTFail("unexpected error: \(error)") }
    }
    XCTAssertEqual(factory.createdCount, 1)
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

private final class BlockingWorker: SiriWorkerTransport, @unchecked Sendable {
  private let gate: SynthesisGate

  init(gate: SynthesisGate) { self.gate = gate }

  func synthesizeDetailed(
    text: String, splitSentences: Bool, includeTimings: Bool, timeout: Duration
  ) async throws -> (pcm: Data, timingsJSON: Data?) {
    await gate.wait()
    try Task.checkCancellation()
    return (Data([1, 2]), nil)
  }

  func terminateHard() {}
}

private final class ScriptedWorkerFactory: @unchecked Sendable {
  enum Result {
    case success(Data)
    case failure(WorkerClientError)
  }

  private let lock = NSLock()
  private var results: [Result]
  private var created = 0

  init(_ results: [Result]) { self.results = results }

  var createdCount: Int { lock.withLock { created } }

  func make() -> any SiriWorkerTransport {
    let result: Result = lock.withLock {
      created += 1
      return results.isEmpty ? .failure(.protocolFailure) : results.removeFirst()
    }
    return ScriptedWorker(result: result)
  }
}

private final class ScriptedWorker: SiriWorkerTransport, @unchecked Sendable {
  private let result: ScriptedWorkerFactory.Result
  init(result: ScriptedWorkerFactory.Result) { self.result = result }

  func synthesizeDetailed(
    text: String, splitSentences: Bool, includeTimings: Bool, timeout: Duration
  ) async throws -> (pcm: Data, timingsJSON: Data?) {
    switch result {
    case .success(let data): (data, nil)
    case .failure(let error): throw error
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

  func make() -> any SiriWorkerTransport {
    lock.withLock { created += 1 }
    return ShutdownWorker(gate: gate)
  }
}

private final class ShutdownWorker: SiriWorkerTransport, @unchecked Sendable {
  private let gate: SynthesisGate
  init(gate: SynthesisGate) { self.gate = gate }

  func synthesizeDetailed(
    text: String, splitSentences: Bool, includeTimings: Bool, timeout: Duration
  ) async throws -> (pcm: Data, timingsJSON: Data?) {
    await gate.wait()
    throw WorkerClientError.protocolFailure
  }

  func terminateHard() {}
}

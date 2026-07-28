import Foundation
import TTSKit

package struct LocalTTSWorkerPoolDiagnostics: Sendable, Equatable {
  package var workersSpawned = 0
  package var workerKills = 0
  package var crashes = 0
  package var timeouts = 0
  package var retries = 0

  package init() {}
}

package enum LocalTTSWorkerClientError: Error, Sendable, Equatable {
  case notRunning
  case timeout
  case remote(String)
  case protocolFailure

  package var requiresReplacement: Bool {
    switch self {
    case .remote("synthesis_failed"): false
    default: true
    }
  }
}

package protocol LocalTTSWorkerTransport: AnyObject, Sendable {
  func synthesize(
    request: TTSSynthesisRequest, deadline: ContinuousClock.Instant
  ) async throws -> LocalTTSWorkerResult
  func terminateHard()
}

package actor LocalTTSWorkerPool {
  private enum ReleaseDisposition {
    case healthy
    case recycle
    case crashed
  }

  private struct Slot {
    let id: UUID
    let voice: VoiceKey
    let client: any LocalTTSWorkerTransport
    var busy: Bool
    var lastUsed: TimeInterval
  }

  private struct Lease: Sendable {
    let slotID: UUID
    let client: any LocalTTSWorkerTransport
  }

  private struct Pending {
    let id: UUID
    let voice: VoiceKey
    let continuation: CheckedContinuation<Lease, Error>
  }

  private let maxWorkers: Int
  private let maxQueued: Int
  private let timeout: Duration
  private let makeClient: @Sendable (VoiceKey) throws -> any LocalTTSWorkerTransport
  private var slots: [UUID: Slot] = [:]
  private var pending: [Pending] = []
  private var pendingTimers: [UUID: Task<Void, Never>] = [:]
  private var crashTimes: [TTSBackendID: [Date]] = [:]
  private var diagnostics = LocalTTSWorkerPoolDiagnostics()
  private var isShutDown = false

  package init(
    maxWorkers: Int, maxQueued: Int, deadlineSeconds: Double,
    makeClient: @escaping @Sendable (VoiceKey) throws -> any LocalTTSWorkerTransport
  ) {
    self.maxWorkers = maxWorkers
    self.maxQueued = maxQueued
    timeout = .milliseconds(Int64(deadlineSeconds * 1_000))
    self.makeClient = makeClient
  }

  package func synthesize(_ request: TTSSynthesisRequest) async throws -> LocalTTSWorkerResult {
    guard !isShutDown else { throw TTSBackendError.unavailable }
    do {
      try LocalTTSWorkerFraming.validateRequest(LocalTTSWorkerRequest(request: request))
    } catch LocalTTSWorkerProtocolError.frameTooLarge {
      throw TTSBackendError.invalidInput("'input' is too large for the local TTS worker protocol.")
    } catch {
      throw TTSBackendError.invalidInput("'input' cannot be encoded.")
    }

    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    var lastError = TTSBackendError.crashed
    for attempt in 0...1 {
      try Task.checkCancellation()
      let lease = try await acquire(voice: request.selection.voice, deadline: deadline)
      let remaining = clock.now.duration(to: deadline)
      guard remaining > .zero else {
        diagnostics.timeouts += 1
        release(lease, disposition: .recycle)
        throw TTSBackendError.timeout
      }
      do {
        let result = try await lease.client.synthesize(request: request, deadline: deadline)
        guard !isShutDown else {
          lease.client.terminateHard()
          throw TTSBackendError.unavailable
        }
        try Task.checkCancellation()
        release(lease, disposition: .healthy)
        return result
      } catch is CancellationError {
        release(lease, disposition: .recycle)
        throw CancellationError()
      } catch let error as LocalTTSWorkerClientError {
        switch error {
        case .timeout:
          release(lease, disposition: .recycle)
          diagnostics.timeouts += 1
          throw TTSBackendError.timeout
        case .remote("engine_unavailable"):
          release(lease, disposition: .recycle)
          throw TTSBackendError.unavailable
        case .remote:
          // An engine refusal gets the same single retry a crash gets, on a
          // FRESH worker: observed twice in production, the Siri engine
          // transiently refused ordinary mid-book paragraphs that synthesized
          // fine moments later, and the first-strike failure killed
          // multi-hour audiobook jobs. The refusing worker is recycled
          // because its engine session state is suspect. A deterministic
          // refusal (truly unspeakable input) fails again on the retry and
          // still surfaces as `synthesisFailed`.
          release(lease, disposition: .recycle)
          lastError = .synthesisFailed
        default:
          release(lease, disposition: .crashed)
          lastError = .crashed
        }
      } catch let error as TTSBackendError {
        release(lease, disposition: .recycle)
        throw error
      } catch {
        release(lease, disposition: .crashed)
        lastError = .crashed
      }
      if attempt == 0 {
        diagnostics.retries += 1
        continue
      }
    }
    throw lastError
  }

  package func diagnosticsSnapshot() -> LocalTTSWorkerPoolDiagnostics { diagnostics }
  package var queuedRequestCount: Int { pending.count }

  package func shutdown() {
    guard !isShutDown else { return }
    isShutDown = true
    for slot in slots.values { slot.client.terminateHard() }
    slots.removeAll()
    let waiters = pending
    pending.removeAll()
    let timers = pendingTimers.values
    pendingTimers.removeAll()
    for timer in timers { timer.cancel() }
    for waiter in waiters { waiter.continuation.resume(throwing: TTSBackendError.unavailable) }
  }

  private func acquire(
    voice: VoiceKey, deadline: ContinuousClock.Instant
  ) async throws -> Lease {
    guard !isShutDown else { throw TTSBackendError.unavailable }
    if circuitIsOpen(for: voice.backendID) { throw TTSBackendError.unavailable }
    let clock = ContinuousClock()
    guard clock.now < deadline else { throw TTSBackendError.timeout }
    if let lease = try leaseNow(voice: voice) { return lease }
    guard pending.count < maxQueued else { throw TTSBackendError.queueFull(maxQueued) }

    let id = UUID()
    let lease = try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        pending.append(Pending(id: id, voice: voice, continuation: continuation))
        let remaining = clock.now.duration(to: deadline)
        pendingTimers[id] = Task { [weak self] in
          do { try await Task.sleep(for: remaining) } catch { return }
          await self?.expirePending(id)
        }
        if Task.isCancelled { cancelPending(id) }
      }
    } onCancel: {
      Task { await self.cancelPending(id) }
    }
    if Task.isCancelled {
      release(lease, disposition: .healthy)
      throw CancellationError()
    }
    return lease
  }

  private func cancelPending(_ id: UUID) {
    if let index = pending.firstIndex(where: { $0.id == id }) {
      let waiter = pending.remove(at: index)
      pendingTimers.removeValue(forKey: id)?.cancel()
      waiter.continuation.resume(throwing: CancellationError())
    }
  }

  private func expirePending(_ id: UUID) {
    guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
    let waiter = pending.remove(at: index)
    pendingTimers.removeValue(forKey: id)?.cancel()
    diagnostics.timeouts += 1
    waiter.continuation.resume(throwing: TTSBackendError.timeout)
  }

  private func leaseNow(voice: VoiceKey) throws -> Lease? {
    guard !isShutDown else { throw TTSBackendError.unavailable }
    if let existing = slots.values
      .filter({ !$0.busy && $0.voice == voice })
      .min(by: { $0.lastUsed < $1.lastUsed })
    {
      var slot = existing
      slot.busy = true
      slots[slot.id] = slot
      return Lease(slotID: slot.id, client: slot.client)
    }

    if slots.count >= maxWorkers {
      guard let victim = slots.values
        .filter({ !$0.busy })
        .min(by: { $0.lastUsed < $1.lastUsed })
      else { return nil }
      victim.client.terminateHard()
      slots.removeValue(forKey: victim.id)
    }

    let client = try makeClient(voice)
    diagnostics.workersSpawned += 1
    let id = UUID()
    slots[id] = Slot(
      id: id, voice: voice, client: client, busy: true,
      lastUsed: Date().timeIntervalSince1970)
    return Lease(slotID: id, client: client)
  }

  private func release(_ lease: Lease, disposition: ReleaseDisposition) {
    guard var slot = slots[lease.slotID] else { return }
    switch disposition {
    case .healthy:
      slot.busy = false
      slot.lastUsed = Date().timeIntervalSince1970
      slots[slot.id] = slot
    case .recycle:
      slot.client.terminateHard()
      slots.removeValue(forKey: slot.id)
      diagnostics.workerKills += 1
    case .crashed:
      slot.client.terminateHard()
      slots.removeValue(forKey: slot.id)
      diagnostics.workerKills += 1
      diagnostics.crashes += 1
      recordCrash(for: slot.voice.backendID)
    }
    drain()
  }

  private func drain() {
    if isShutDown {
      let waiters = pending
      pending.removeAll()
      for waiter in waiters {
        pendingTimers.removeValue(forKey: waiter.id)?.cancel()
        waiter.continuation.resume(throwing: TTSBackendError.unavailable)
      }
      return
    }
    while !pending.isEmpty {
      let waiter = pending[0]
      if circuitIsOpen(for: waiter.voice.backendID) {
        pending.removeFirst()
        pendingTimers.removeValue(forKey: waiter.id)?.cancel()
        waiter.continuation.resume(throwing: TTSBackendError.unavailable)
        continue
      }
      do {
        guard let lease = try leaseNow(voice: waiter.voice) else { return }
        pending.removeFirst()
        pendingTimers.removeValue(forKey: waiter.id)?.cancel()
        waiter.continuation.resume(returning: lease)
      } catch {
        pending.removeFirst()
        pendingTimers.removeValue(forKey: waiter.id)?.cancel()
        waiter.continuation.resume(throwing: TTSBackendError.crashed)
      }
    }
  }

  private func circuitIsOpen(for backendID: TTSBackendID) -> Bool {
    let cutoff = Date().addingTimeInterval(-60)
    crashTimes[backendID, default: []].removeAll(where: { $0 < cutoff })
    return crashTimes[backendID, default: []].count >= 3
  }

  private func recordCrash(for backendID: TTSBackendID) {
    crashTimes[backendID, default: []].append(Date())
    _ = circuitIsOpen(for: backendID)
  }
}

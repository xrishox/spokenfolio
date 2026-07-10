import Foundation

actor SiriWorkerPool {
  private enum ReleaseDisposition {
    case healthy
    case recycle
    case crashed
  }

  private struct Slot {
    let id: UUID
    let voiceID: String
    let client: SiriWorkerClient
    var busy: Bool
    var lastUsed: TimeInterval
  }

  private struct Lease: Sendable {
    let slotID: UUID
    let client: SiriWorkerClient
  }

  private struct Pending {
    let id: UUID
    let voiceID: String
    let continuation: CheckedContinuation<Lease, Error>
  }

  private let maxWorkers: Int
  private let maxQueued: Int
  private let timeout: Duration
  private var slots: [UUID: Slot] = [:]
  private var pending: [Pending] = []
  private var cancelledBeforeEnqueue: Set<UUID> = []
  private var crashTimes: [Date] = []

  init(maxWorkers: Int, maxQueued: Int, deadlineSeconds: Double) {
    self.maxWorkers = maxWorkers
    self.maxQueued = maxQueued
    timeout = .milliseconds(Int64(deadlineSeconds * 1_000))
  }

  func synthesize(text: String, voiceID: String) async throws -> Data {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    var lastError: ServiceError = .workerCrashed
    for attempt in 0...1 {
      try Task.checkCancellation()
      let lease = try await acquire(voiceID: voiceID)
      let remaining = clock.now.duration(to: deadline)
      guard remaining > .zero else {
        release(lease, disposition: .recycle)
        throw ServiceError.timeout
      }
      do {
        let pcm = try await lease.client.synthesize(text: text, timeout: remaining)
        release(lease, disposition: .healthy)
        return pcm
      } catch is CancellationError {
        release(lease, disposition: .recycle)
        throw CancellationError()
      } catch let error as WorkerClientError {
        release(
          lease,
          disposition: error.requiresReplacement ? .crashed : .healthy)
        switch error {
        case .timeout:
          throw ServiceError.timeout
        case .remote("engine_unavailable"):
          throw ServiceError.engineUnavailable
        case .remote:
          throw ServiceError.synthesisFailed
        default:
          lastError = .workerCrashed
        }
      } catch {
        release(lease, disposition: .crashed)
        lastError = .workerCrashed
      }
      if attempt == 0 { continue }
    }
    throw lastError
  }

  func shutdown() {
    for slot in slots.values { slot.client.terminateHard() }
    slots.removeAll()
    let waiters = pending
    pending.removeAll()
    for waiter in waiters { waiter.continuation.resume(throwing: ServiceError.engineUnavailable) }
  }

  private func acquire(voiceID: String) async throws -> Lease {
    if circuitIsOpen { throw ServiceError.engineUnavailable }
    if let lease = try leaseNow(voiceID: voiceID) { return lease }
    guard pending.count < maxQueued else { throw ServiceError.queueFull(maxQueued) }

    let id = UUID()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        if cancelledBeforeEnqueue.remove(id) != nil {
          continuation.resume(throwing: CancellationError())
        } else {
          pending.append(Pending(id: id, voiceID: voiceID, continuation: continuation))
        }
      }
    } onCancel: {
      Task { await self.cancelPending(id) }
    }
  }

  private func cancelPending(_ id: UUID) {
    if let index = pending.firstIndex(where: { $0.id == id }) {
      let waiter = pending.remove(at: index)
      waiter.continuation.resume(throwing: CancellationError())
    } else {
      cancelledBeforeEnqueue.insert(id)
    }
  }

  private func leaseNow(voiceID: String) throws -> Lease? {
    if let existing = slots.values
      .filter({ !$0.busy && $0.voiceID == voiceID })
      .min(by: { $0.lastUsed < $1.lastUsed })
    {
      var slot = existing
      slot.busy = true
      slots[slot.id] = slot
      return Lease(slotID: slot.id, client: slot.client)
    }

    if slots.count >= maxWorkers {
      guard
        let victim = slots.values
          .filter({ !$0.busy })
          .min(by: { $0.lastUsed < $1.lastUsed })
      else { return nil }
      victim.client.terminateHard()
      slots.removeValue(forKey: victim.id)
    }

    let client = try SiriWorkerClient(voiceID: voiceID)
    let id = UUID()
    slots[id] = Slot(
      id: id,
      voiceID: voiceID,
      client: client,
      busy: true,
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
    case .crashed:
      slot.client.terminateHard()
      slots.removeValue(forKey: slot.id)
      recordCrash()
    }
    drain()
  }

  private func drain() {
    if circuitIsOpen {
      let waiters = pending
      pending.removeAll()
      for waiter in waiters {
        waiter.continuation.resume(throwing: ServiceError.engineUnavailable)
      }
      return
    }
    while !pending.isEmpty {
      let waiter = pending[0]
      do {
        guard let lease = try leaseNow(voiceID: waiter.voiceID) else { return }
        pending.removeFirst()
        waiter.continuation.resume(returning: lease)
      } catch {
        pending.removeFirst()
        waiter.continuation.resume(throwing: ServiceError.workerCrashed)
      }
    }
  }

  private var circuitIsOpen: Bool {
    let cutoff = Date().addingTimeInterval(-60)
    crashTimes.removeAll(where: { $0 < cutoff })
    return crashTimes.count >= 3
  }

  private func recordCrash() {
    crashTimes.append(Date())
    _ = circuitIsOpen
  }
}

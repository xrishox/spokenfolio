import BookJobKit
import Darwin
import Foundation

/// A point-in-time view of the durable production queue, safe to send to any
/// interface (SwiftUI adapter, web API, SSE stream).
struct JobSchedulerSnapshot: Sendable {
  struct Row: Identifiable, Sendable {
    let request: BookJobRequest
    let state: BookJobState
    let control: BookJobControl
    var id: UUID { request.id }
  }

  var rows: [Row] = []
  var scanIssues: [BookJobStore.ScanIssue] = []
  var isSuspended = true
  var activeJobID: UUID?
  var error: String?
  /// Monotonic change counter so consumers can cheaply detect staleness.
  var sequence: UInt64 = 0

  var queuedCount: Int {
    rows.filter {
      ($0.control.queueDisposition == .ready
        && [.queued, .paused].contains($0.state.lifecycle))
        || ($0.control.queueDisposition == .retryReady
          && $0.state.lifecycle == .needsAttention)
    }.count
  }

  var runningCount: Int { rows.filter { $0.state.lifecycle == .running }.count }
}

/// The durable FIFO production scheduler, extracted from the GUI so any
/// interface can host it: it owns the scheduler lock, the 2-second durable
/// scan loop, and the single heavyweight `jobs run` child. Exactly one
/// instance may be active per machine (`scheduler.lock` arbitration); the
/// SwiftUI `StudioJobCoordinator` is a thin observation adapter over this
/// actor, and the web API talks to it directly.
actor JobSchedulerService {
  private let store: BookJobStore
  private let schedulerStore: BookSchedulerStore
  private let schedulerLockURL: URL?
  private let executable: URL?
  private var runner: BookJobProcessRunner?
  private var runnerTask: Task<Void, Never>?
  private var monitorTask: Task<Void, Never>?
  private var coordinatorLock: BookFileLock?

  private var snapshot = JobSchedulerSnapshot()
  private var subscribers: [UUID: AsyncStream<JobSchedulerSnapshot>.Continuation] = [:]

  init(
    store: BookJobStore = BookJobStore(root: AppPaths.productionJobRoot),
    schedulerStore: BookSchedulerStore = BookSchedulerStore(url: AppPaths.schedulerStateURL),
    schedulerLockURL: URL? = AppPaths.schedulerLockURL,
    executable: URL? = nil
  ) {
    self.store = store
    self.schedulerStore = schedulerStore
    self.schedulerLockURL = schedulerLockURL
    self.executable = executable
  }

  // MARK: - Observation

  var currentSnapshot: JobSchedulerSnapshot { snapshot }

  /// Yields the current snapshot immediately, then every subsequent change.
  func snapshots() -> AsyncStream<JobSchedulerSnapshot> {
    let id = UUID()
    return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
      subscribers[id] = continuation
      continuation.yield(snapshot)
      continuation.onTermination = { _ in
        Task { [weak self] in await self?.removeSubscriber(id) }
      }
    }
  }

  private func removeSubscriber(_ id: UUID) {
    subscribers[id] = nil
  }

  private func publish(_ mutate: (inout JobSchedulerSnapshot) -> Void) {
    mutate(&snapshot)
    snapshot.sequence &+= 1
    for continuation in subscribers.values {
      continuation.yield(snapshot)
    }
  }

  // MARK: - Lifecycle

  @discardableResult
  func start() -> JobSchedulerSnapshot {
    guard monitorTask == nil else { return snapshot }
    do {
      coordinatorLock = try schedulerLockURL.map { try BookFileLock(url: $0, nonblocking: true) }
    } catch {
      publish { $0.error = "Another Studio scheduler is already active." }
      return snapshot
    }
    monitorTask = Task { [weak self] in
      guard let self else { return }
      // A process launch is a new user session. The requested policy is to
      // leave unfinished work suspended until Resume Queue is explicit.
      do {
        _ = try await self.schedulerStore.setSuspended(true)
        await self.publishSuspended(true, error: nil)
      } catch {
        await self.publishSuspended(
          true,
          error:
            "The queue could not be placed in its safe suspended state: \(error.localizedDescription)"
        )
        return
      }
      await self.reload()
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(2))
        guard !Task.isCancelled else { return }
        await self.reload()
        await self.startNextIfPossible()
      }
    }
    return snapshot
  }

  private func publishSuspended(_ suspended: Bool, error: String?) {
    publish {
      $0.isSuspended = suspended
      if let error { $0.error = error }
    }
  }

  func prepareForTermination() async throws {
    _ = try await schedulerStore.setSuspended(true)
    publish { $0.isSuspended = true }
    if let runner { try await runner.interrupt(.pause) }
    for row in snapshot.rows
    where row.state.lifecycle == .running && row.id != snapshot.activeJobID {
      try await store.requestInterruption(row.id, attempt: row.state.attempt, kind: .pause)
      Self.signalVerifiedRunner(row.state.runner, signal: SIGINT)
    }
    let activeTask = runnerTask
    if let activeTask { await activeTask.value }
    monitorTask?.cancel()
    let monitor = monitorTask
    monitorTask = nil
    if let monitor { await monitor.value }
    coordinatorLock = nil
  }

  // MARK: - Durable state

  @discardableResult
  func reload() async -> JobSchedulerSnapshot {
    do {
      let scan = try await store.scan()
      var next: [JobSchedulerSnapshot.Row] = []
      var controlIssues: [BookJobStore.ScanIssue] = []
      for (request, loadedState) in scan.jobs {
        var state = loadedState
        if state.lifecycle == .running, snapshot.activeJobID != request.id,
          await jobLeaseIsAvailable(request.id)
        {
          state.runner = nil
          state.lastError = "The production child exited without finalizing its job state."
          if let stage = state.stages.first(where: { $0.status == .running })?.stage {
            try state.updateStage(
              stage, status: .needsAttention,
              fraction: state.stages.first(where: { $0.stage == stage })?.fraction,
              message: state.lastError)
          }
          try state.transition(to: .needsAttention)
          try await store.saveState(state)
          try await store.setQueueDisposition(.held, id: request.id)
        }
        let control: BookJobControl
        do {
          control = try await store.loadControl(request.id)
        } catch {
          control = BookJobControl(queueDisposition: .held)
          controlIssues.append(
            .init(
              directory: request.id.uuidString.lowercased(),
              message: "control.json: \(error.localizedDescription)"))
        }
        next.append(.init(request: request, state: state, control: control))
      }
      let sorted = next.sorted { left, right in
        let l = left.control.queueSequence ?? UInt64.max
        let r = right.control.queueSequence ?? UInt64.max
        return l == r ? left.request.createdAt < right.request.createdAt : l < r
      }
      let issues = scan.issues + controlIssues
      let suspended = (try await schedulerStore.load()).isSuspended
      publish {
        $0.rows = sorted
        $0.scanIssues = issues
        $0.isSuspended = suspended
        if let active = $0.activeJobID,
          !sorted.contains(where: { $0.id == active && $0.state.lifecycle == .running })
        {
          $0.activeJobID = nil
        }
        $0.error = nil
      }
    } catch {
      publish {
        $0.isSuspended = true
        $0.error = error.localizedDescription
      }
    }
    return snapshot
  }

  // MARK: - Queue mutations

  func enqueue(_ requests: [BookJobRequest]) async -> [UUID: String] {
    guard !requests.isEmpty else { return [:] }
    var failures: [UUID: String] = [:]
    let sequences: [UInt64]
    do {
      sequences = try await schedulerStore.reserve(count: requests.count)
    } catch {
      publish { $0.error = error.localizedDescription }
      return Dictionary(uniqueKeysWithValues: requests.map { ($0.id, error.localizedDescription) })
    }
    var enqueued = 0
    for (request, sequence) in zip(requests, sequences) {
      do {
        _ = try await store.create(request)
        try await store.enqueue(request.id, sequence: sequence)
        enqueued += 1
      } catch {
        failures[request.id] = error.localizedDescription
      }
    }
    if enqueued > 0 {
      do {
        _ = try await schedulerStore.setSuspended(false)
        await reload()
        startNextIfPossible()
      } catch {
        // Successfully enqueued jobs remain durable and are not reported as
        // failed merely because waking the scheduler failed.
        publish { $0.error = error.localizedDescription }
      }
    }
    return failures
  }

  func resumeQueue() async {
    do {
      _ = try await schedulerStore.setSuspended(false)
      await reload()
      startNextIfPossible()
    } catch { publish { $0.error = error.localizedDescription } }
  }

  func pauseQueue(interruptActive: Bool = false) async {
    do {
      _ = try await schedulerStore.setSuspended(true)
      publish { $0.isSuspended = true }
      if interruptActive { try await runner?.interrupt(.pause) }
    } catch { publish { $0.error = error.localizedDescription } }
  }

  /// Holds selected waiting work and safely interrupts a selected active child.
  /// The durable control file is always changed before a signal is sent.
  func pauseJobs(_ ids: Set<UUID>) async {
    guard !ids.isEmpty else { return }
    do {
      for id in ids {
        let state = try await store.loadState(id)
        guard ![.completed, .cancelled].contains(state.lifecycle) else { continue }
        if snapshot.activeJobID == id {
          try await runner?.interrupt(.pause)
        } else if state.lifecycle == .running {
          try await store.requestInterruption(id, attempt: state.attempt, kind: .pause)
          Self.signalVerifiedRunner(state.runner, signal: SIGINT)
        } else {
          try await store.setQueueDisposition(.held, id: id)
        }
      }
      await reload()
    } catch { publish { $0.error = error.localizedDescription } }
  }

  /// Makes selected held work runnable. Needs-attention jobs use the explicit
  /// retry disposition so a failed attempt can never restart accidentally.
  func resumeJobs(_ ids: Set<UUID>) async {
    guard !ids.isEmpty else { return }
    do {
      var didResume = false
      // Preserve the visible FIFO order when more than one held job needs a
      // new sequence. Iterating a Set would make that ordering nondeterministic.
      let knownIDs = snapshot.rows.filter { ids.contains($0.id) }.map(\.id)
      let remainingIDs = ids.subtracting(knownIDs).sorted {
        $0.uuidString < $1.uuidString
      }
      for id in knownIDs + remainingIDs {
        let state = try await store.loadState(id)
        guard ![.running, .completed, .cancelled].contains(state.lifecycle) else { continue }
        var control = try await store.loadControl(id)
        if control.queueSequence == nil {
          control.queueSequence = try await schedulerStore.reserve(count: 1).first
        }
        control.queueDisposition = state.lifecycle == .needsAttention ? .retryReady : .ready
        control.interruption = nil
        control.cancelRequestedForAttempt = nil
        try await store.saveControl(control, id: id)
        didResume = true
      }
      if didResume { _ = try await schedulerStore.setSuspended(false) }
      await reload()
      startNextIfPossible()
    } catch { publish { $0.error = error.localizedDescription } }
  }

  /// Cancels selected nonterminal jobs. Waiting jobs transition immediately;
  /// running children receive persisted cancellation intent before SIGINT.
  func cancelJobs(_ ids: Set<UUID>) async {
    guard !ids.isEmpty else { return }
    do {
      for id in ids {
        var state = try await store.loadState(id)
        guard ![.completed, .cancelled].contains(state.lifecycle) else { continue }
        if snapshot.activeJobID == id {
          try await runner?.interrupt(.cancel)
        } else if state.lifecycle == .running {
          try await store.requestInterruption(id, attempt: state.attempt, kind: .cancel)
          Self.signalVerifiedRunner(state.runner, signal: SIGINT)
        } else {
          try state.transition(to: .cancelled)
          try await store.saveState(state)
          try await store.setQueueDisposition(.held, id: id)
        }
      }
      await reload()
    } catch { publish { $0.error = error.localizedDescription } }
  }

  /// Cancels the durable waiting queue. The active job is intentionally left
  /// alone unless the caller explicitly opts in.
  func cancelWaitingJobs(includeActive: Bool = false) async {
    do {
      // Freeze dispatch first so a waiting job cannot become the active job
      // while the cancellation set is being persisted.
      _ = try await schedulerStore.setSuspended(true)
      publish { $0.isSuspended = true }
      await reload()
      let waiting = Set(snapshot.rows.compactMap { row -> UUID? in
        guard ![.running, .completed, .cancelled].contains(row.state.lifecycle) else { return nil }
        return row.id
      })
      var targets = waiting
      if includeActive, let active = snapshot.activeJobID { targets.insert(active) }
      await cancelJobs(targets)
    } catch { publish { $0.error = error.localizedDescription } }
  }

  // MARK: - Dispatch

  private func startNextIfPossible() {
    guard !snapshot.isSuspended, runner == nil else { return }
    guard !snapshot.rows.contains(where: { $0.state.lifecycle == .running }) else { return }
    guard let next = snapshot.rows.first(where: {
      ($0.control.queueDisposition == .ready
        && [.queued, .paused].contains($0.state.lifecycle))
        || ($0.control.queueDisposition == .retryReady
          && $0.state.lifecycle == .needsAttention)
    }) else { return }

    let runner = BookJobProcessRunner(executable: executable, store: store)
    self.runner = runner
    publish { $0.activeJobID = next.id }
    runnerTask = Task { [weak self] in
      guard let self else { return }
      var launchFailure = false
      do {
        for try await _ in runner.run(id: next.id) { await self.reload() }
      } catch {
        let state = try? await self.store.loadState(next.id)
        launchFailure = state?.lifecycle == .queued
        await self.publishError(error.localizedDescription)
      }
      await self.finishRunner(launchFailure: launchFailure)
    }
  }

  private func publishError(_ message: String) {
    publish { $0.error = message }
  }

  private func finishRunner(launchFailure: Bool) async {
    runner = nil
    runnerTask = nil
    publish { $0.activeJobID = nil }
    if launchFailure {
      _ = try? await schedulerStore.setSuspended(true)
    }
    await reload()
    startNextIfPossible()
  }

  // MARK: - Process helpers

  nonisolated static func processIsAlive(_ pid: Int32?) -> Bool {
    guard let pid, pid > 0 else { return false }
    if Darwin.kill(pid, 0) == 0 { return true }
    return errno == EPERM
  }

  private func jobLeaseIsAvailable(_ id: UUID) async -> Bool {
    do {
      let lease = try await store.acquireLease(id)
      _fixLifetime(lease)
      return true
    } catch BookJobError.alreadyRunning {
      return false
    } catch {
      return false
    }
  }

  nonisolated private static func signalVerifiedRunner(
    _ runner: BookJobRunnerIdentity?, signal: Int32
  ) {
    guard let runner, runner.pid > 0 else { return }
    var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    let length = proc_pidpath(runner.pid, &path, UInt32(path.count))
    guard length > 0 else { return }
    let decoded = String(
      decoding: path.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    let actual = URL(fileURLWithPath: decoded).standardizedFileURL.path
    let expected = URL(fileURLWithPath: runner.executablePath).standardizedFileURL.path
    guard actual == expected else { return }
    _ = Darwin.kill(runner.pid, signal)
  }
}

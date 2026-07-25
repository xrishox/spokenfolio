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
  /// The delivery-only child running in the lightweight lane, if any. It
  /// coexists with the heavyweight `activeJobID` child by design: a Library
  /// send is network I/O and never contends with synthesis.
  var deliveryActiveJobID: UUID?
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

  /// Whether a row is eligible for dispatch right now.
  static func isDispatchable(_ row: Row) -> Bool {
    (row.control.queueDisposition == .ready
      && [.queued, .paused].contains(row.state.lifecycle))
      || (row.control.queueDisposition == .retryReady
        && row.state.lifecycle == .needsAttention)
  }

  static func isDeliveryOnly(_ row: Row) -> Bool {
    row.request.resolvedOperation == .storytellerDelivery
  }

  /// The next job for the heavyweight lane: first dispatchable non-delivery
  /// row, only while no non-delivery child is running.
  static func heavyCandidate(rows: [Row]) -> Row? {
    guard
      !rows.contains(where: { $0.state.lifecycle == .running && !isDeliveryOnly($0) })
    else { return nil }
    return rows.first { isDispatchable($0) && !isDeliveryOnly($0) }
  }

  /// The next job for the delivery lane: first dispatchable delivery-only
  /// row whose book has no other active work — another job for the same
  /// edition that is running, or dispatchable and ordered ahead, keeps the
  /// send waiting (a queued ReadAloud creation must finish before its book
  /// is sent). Held or failed same-book jobs do not block a send: they will
  /// not run spontaneously, and delivery verification is digest-guarded.
  static func deliveryCandidate(rows: [Row]) -> Row? {
    guard
      !rows.contains(where: { $0.state.lifecycle == .running && isDeliveryOnly($0) })
    else { return nil }
    return rows.first { row in
      guard isDispatchable(row), isDeliveryOnly(row) else { return false }
      guard let catalogID = row.request.catalogID else { return true }
      if rows.contains(where: {
        $0.id != row.id && $0.request.catalogID == catalogID
          && $0.state.lifecycle == .running
      }) {
        return false
      }
      let ahead = rows.prefix(while: { $0.id != row.id })
      return !ahead.contains { $0.request.catalogID == catalogID && isDispatchable($0) }
    }
  }
}

/// The durable FIFO production scheduler, extracted from the GUI so any
/// interface can host it: it owns the scheduler lock, the 2-second durable
/// scan loop, and two `jobs run` children — one heavyweight production
/// child, plus at most one delivery-only child so Library sends of finished
/// books never wait behind synthesis. Exactly one instance may be active
/// per machine (`scheduler.lock` arbitration); the SwiftUI
/// `StudioJobCoordinator` is a thin observation adapter over this actor,
/// and the web API talks to it directly.
actor JobSchedulerService {
  private let store: BookJobStore
  private let schedulerStore: BookSchedulerStore
  private let schedulerLockURL: URL?
  private let executable: URL?
  private var runner: BookJobProcessRunner?
  private var runnerTask: Task<Void, Never>?
  private var deliveryRunner: BookJobProcessRunner?
  private var deliveryRunnerTask: Task<Void, Never>?
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
        await self.dispatchIfPossible()
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
    if let deliveryRunner { try await deliveryRunner.interrupt(.pause) }
    for row in snapshot.rows
    where row.state.lifecycle == .running && row.id != snapshot.activeJobID
      && row.id != snapshot.deliveryActiveJobID
    {
      try await store.requestInterruption(row.id, attempt: row.state.attempt, kind: .pause)
      Self.signalVerifiedRunner(row.state.runner, signal: SIGINT)
    }
    let activeTask = runnerTask
    if let activeTask { await activeTask.value }
    let activeDeliveryTask = deliveryRunnerTask
    if let activeDeliveryTask { await activeDeliveryTask.value }
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
          snapshot.deliveryActiveJobID != request.id,
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
        if let active = $0.deliveryActiveJobID,
          !sorted.contains(where: { $0.id == active && $0.state.lifecycle == .running })
        {
          $0.deliveryActiveJobID = nil
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
        dispatchIfPossible()
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
      // Resuming the queue also revives work that was paused by an
      // interrupt (quit, Pause Now, preemption) at its OLD position: those
      // rows are paused+held with a persisted pause interruption and keep
      // their queue sequence. An explicitly held waiting job (no
      // interruption) stays held.
      await reload()
      for row in snapshot.rows
      where row.state.lifecycle == .paused
        && row.control.queueDisposition == .held
        && row.control.interruption?.kind == .pause
      {
        var control = try await store.loadControl(row.id)
        control.queueDisposition = .ready
        control.interruption = nil
        control.cancelRequestedForAttempt = nil
        try await store.saveControl(control, id: row.id)
      }
      _ = try await schedulerStore.setSuspended(false)
      await reload()
      dispatchIfPossible()
    } catch { publish { $0.error = error.localizedDescription } }
  }

  /// Preempts the queue for one chosen book: the target moves to the front,
  /// a running heavyweight job is safely paused (chapter-checkpointed), and
  /// that paused job is re-readied directly behind the target so it
  /// continues next. Nothing is lost: pause intent is persisted before any
  /// signal, and resume reuses completed chapters after digest validation.
  func runNext(_ targetID: UUID) async -> String? {
    await reload()
    guard let target = snapshot.rows.first(where: { $0.id == targetID }) else {
      return "That job no longer exists."
    }
    guard ![.running, .completed, .cancelled].contains(target.state.lifecycle) else {
      return "That job cannot be moved: it is \(target.state.lifecycle.rawValue)."
    }
    do {
      // Make the target dispatchable and first in line.
      if target.control.queueDisposition == .held
        || target.state.lifecycle == .needsAttention
      {
        var control = try await store.loadControl(targetID)
        control.queueDisposition =
          target.state.lifecycle == .needsAttention ? .retryReady : .ready
        control.interruption = nil
        control.cancelRequestedForAttempt = nil
        try await store.saveControl(control, id: targetID)
      }
      let preempted = JobSchedulerSnapshot.isDeliveryOnly(target) ? nil : snapshot.activeJobID
      try await applyOrder(front: [targetID], thenPreempted: preempted)
      _ = try await schedulerStore.setSuspended(false)

      // Safely pause the running heavyweight job so the target can start.
      if preempted != nil, let runner {
        try await runner.interrupt(.pause)
        let task = runnerTask
        if let task { await task.value }
        await reload()
        if let preempted,
          let row = snapshot.rows.first(where: { $0.id == preempted }),
          row.state.lifecycle == .paused
        {
          var control = try await store.loadControl(preempted)
          control.queueDisposition = .ready
          control.interruption = nil
          control.cancelRequestedForAttempt = nil
          try await store.saveControl(control, id: preempted)
          try await applyOrder(front: [targetID, preempted], thenPreempted: nil)
        }
      }
      await reload()
      dispatchIfPossible()
      return nil
    } catch {
      publish { $0.error = error.localizedDescription }
      return error.localizedDescription
    }
  }

  /// Rewrites queue sequences so `front` comes first (in the given order),
  /// followed by every other non-running, non-terminal row in its current
  /// order. `thenPreempted` reserves the second slot for a job that is
  /// about to be paused and re-queued.
  private func applyOrder(front: [UUID], thenPreempted preempted: UUID?) async throws {
    var order = front
    if let preempted, !order.contains(preempted) { order.append(preempted) }
    let rest = snapshot.rows.filter {
      ![.running, .completed, .cancelled].contains($0.state.lifecycle)
        && !order.contains($0.id)
    }.map(\.id)
    // A running preempted job is not yet reorderable; sequences are only
    // written for rows that currently qualify.
    let target = (order + rest).filter { id in
      snapshot.rows.first(where: { $0.id == id }).map {
        ![.running, .completed, .cancelled].contains($0.state.lifecycle)
      } ?? false
    }
    let sequences = try await schedulerStore.reserve(count: target.count)
    for (id, sequence) in zip(target, sequences) {
      var control = try await store.loadControl(id)
      control.queueSequence = sequence
      try await store.saveControl(control, id: id)
    }
    await reload()
  }

  func pauseQueue(interruptActive: Bool = false) async {
    do {
      _ = try await schedulerStore.setSuspended(true)
      publish { $0.isSuspended = true }
      if interruptActive {
        try await runner?.interrupt(.pause)
        try await deliveryRunner?.interrupt(.pause)
      }
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
        } else if snapshot.deliveryActiveJobID == id {
          try await deliveryRunner?.interrupt(.pause)
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
      dispatchIfPossible()
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
        } else if snapshot.deliveryActiveJobID == id {
          try await deliveryRunner?.interrupt(.cancel)
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
      if includeActive, let active = snapshot.deliveryActiveJobID { targets.insert(active) }
      await cancelJobs(targets)
    } catch { publish { $0.error = error.localizedDescription } }
  }

  // MARK: - Dispatch

  private enum Lane { case heavy, delivery }

  /// Two lanes: one heavyweight production child, and one delivery-only
  /// child that ships already-finished products without waiting behind
  /// synthesis. Same-book conflicts are excluded by `deliveryCandidate`.
  private func dispatchIfPossible() {
    guard !snapshot.isSuspended else { return }
    if runner == nil, let next = JobSchedulerSnapshot.heavyCandidate(rows: snapshot.rows) {
      startRunner(next, lane: .heavy)
    }
    if deliveryRunner == nil,
      let next = JobSchedulerSnapshot.deliveryCandidate(rows: snapshot.rows)
    {
      startRunner(next, lane: .delivery)
    }
  }

  private func startRunner(_ next: JobSchedulerSnapshot.Row, lane: Lane) {
    let runner = BookJobProcessRunner(executable: executable, store: store)
    switch lane {
    case .heavy:
      self.runner = runner
      publish { $0.activeJobID = next.id }
    case .delivery:
      deliveryRunner = runner
      publish { $0.deliveryActiveJobID = next.id }
    }
    let task = Task { [weak self] in
      guard let self else { return }
      var launchFailure = false
      do {
        for try await _ in runner.run(id: next.id) { await self.reload() }
      } catch {
        let state = try? await self.store.loadState(next.id)
        launchFailure = state?.lifecycle == .queued
        await self.publishError(error.localizedDescription)
      }
      await self.finishRunner(lane: lane, launchFailure: launchFailure)
    }
    switch lane {
    case .heavy: runnerTask = task
    case .delivery: deliveryRunnerTask = task
    }
  }

  private func publishError(_ message: String) {
    publish { $0.error = message }
  }

  private func finishRunner(lane: Lane, launchFailure: Bool) async {
    switch lane {
    case .heavy:
      runner = nil
      runnerTask = nil
      publish { $0.activeJobID = nil }
    case .delivery:
      deliveryRunner = nil
      deliveryRunnerTask = nil
      publish { $0.deliveryActiveJobID = nil }
    }
    if launchFailure {
      _ = try? await schedulerStore.setSuspended(true)
    }
    await reload()
    dispatchIfPossible()
  }

  // MARK: - Reordering

  /// Applies a new order to the waiting queue. `orderedIDs` must be the
  /// complete set of non-running, non-terminal jobs (any disposition) in the
  /// desired order; a mismatch means the queue changed underneath the caller
  /// and nothing is written. Fresh sequences keep the order durable.
  func reorder(_ orderedIDs: [UUID]) async -> String? {
    await reload()
    let reorderable = snapshot.rows.filter {
      ![.running, .completed, .cancelled].contains($0.state.lifecycle)
    }.map(\.id)
    guard orderedIDs.count == reorderable.count, Set(orderedIDs) == Set(reorderable) else {
      return "The queue changed while reordering; refresh and try again."
    }
    do {
      let sequences = try await schedulerStore.reserve(count: orderedIDs.count)
      for (id, sequence) in zip(orderedIDs, sequences) {
        var control = try await store.loadControl(id)
        control.queueSequence = sequence
        try await store.saveControl(control, id: id)
      }
      await reload()
      dispatchIfPossible()
      return nil
    } catch {
      publish { $0.error = error.localizedDescription }
      return error.localizedDescription
    }
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

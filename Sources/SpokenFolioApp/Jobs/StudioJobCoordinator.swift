import BookJobKit
import Darwin
import Foundation
import Observation

@MainActor
@Observable
final class StudioJobCoordinator {
  struct Row: Identifiable {
    let request: BookJobRequest
    let state: BookJobState
    let control: BookJobControl
    var id: UUID { request.id }
  }

  private(set) var rows: [Row] = []
  private(set) var scanIssues: [BookJobStore.ScanIssue] = []
  private(set) var isSuspended = true
  private(set) var activeJobID: UUID?
  private(set) var error: String?

  @ObservationIgnored private let store: BookJobStore
  @ObservationIgnored private let schedulerStore: BookSchedulerStore
  @ObservationIgnored private let schedulerLockURL: URL?
  @ObservationIgnored private let executable: URL?
  @ObservationIgnored private var runner: BookJobProcessRunner?
  @ObservationIgnored private var runnerTask: Task<Void, Never>?
  @ObservationIgnored private var monitorTask: Task<Void, Never>?
  @ObservationIgnored private var coordinatorLock: BookFileLock?

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

  func start() {
    guard monitorTask == nil else { return }
    do {
      coordinatorLock = try schedulerLockURL.map { try BookFileLock(url: $0, nonblocking: true) }
    } catch {
      self.error = "Another Studio scheduler is already active."
      return
    }
    monitorTask = Task { [weak self] in
      guard let self else { return }
      // A process launch is a new user session. The requested policy is to
      // leave unfinished work suspended until Resume Queue is explicit.
      _ = try? await self.schedulerStore.setSuspended(true)
      await self.reload()
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(2))
        guard !Task.isCancelled else { return }
        await self.reload()
        self.startNextIfPossible()
      }
    }
  }

  func prepareForTermination() async throws {
    _ = try await schedulerStore.setSuspended(true)
    isSuspended = true
    if let runner { try await runner.interrupt(.pause) }
    let activeTask = runnerTask
    if let activeTask { await activeTask.value }
    monitorTask?.cancel()
    let monitor = monitorTask
    monitorTask = nil
    if let monitor { await monitor.value }
    coordinatorLock = nil
  }

  func reload() async {
    do {
      let scan = try await store.scan()
      var next: [Row] = []
      for (request, loadedState) in scan.jobs {
        var state = loadedState
        if state.lifecycle == .running, activeJobID != request.id,
          !Self.processIsAlive(state.runner?.pid)
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
        let control = (try? await store.loadControl(request.id)) ?? BookJobControl()
        next.append(Row(request: request, state: state, control: control))
      }
      rows = next.sorted { left, right in
        let l = left.control.queueSequence ?? UInt64.max
        let r = right.control.queueSequence ?? UInt64.max
        return l == r ? left.request.createdAt < right.request.createdAt : l < r
      }
      scanIssues = scan.issues
      isSuspended = (try await schedulerStore.load()).isSuspended
      if let activeJobID,
        !rows.contains(where: { $0.id == activeJobID && $0.state.lifecycle == .running })
      {
        self.activeJobID = nil
      }
      error = nil
    } catch {
      self.error = error.localizedDescription
    }
  }

  func enqueue(_ requests: [BookJobRequest]) async -> [UUID: String] {
    guard !requests.isEmpty else { return [:] }
    var failures: [UUID: String] = [:]
    do {
      let sequences = try await schedulerStore.reserve(count: requests.count)
      var created: [(UUID, UInt64)] = []
      for (request, sequence) in zip(requests, sequences) {
        do {
          _ = try await store.create(request)
          created.append((request.id, sequence))
        } catch { failures[request.id] = error.localizedDescription }
      }
      // Wake the queue only after every independently valid request has a
      // durable request/state/control triplet.
      for (id, sequence) in created { try await store.enqueue(id, sequence: sequence) }
      _ = try await schedulerStore.setSuspended(false)
      await reload()
      startNextIfPossible()
    } catch {
      self.error = error.localizedDescription
    }
    return failures
  }

  func resumeQueue() {
    Task {
      do {
        _ = try await schedulerStore.setSuspended(false)
        await reload()
        startNextIfPossible()
      } catch { self.error = error.localizedDescription }
    }
  }

  func pauseQueue(interruptActive: Bool = false) {
    Task {
      do {
        _ = try await schedulerStore.setSuspended(true)
        isSuspended = true
        if interruptActive { try await runner?.interrupt(.pause) }
      } catch { self.error = error.localizedDescription }
    }
  }

  func pauseJob(_ id: UUID) {
    Task {
      do {
        if activeJobID == id {
          try await runner?.interrupt(.pause)
        } else {
          try await store.setQueueDisposition(.held, id: id)
        }
        await reload()
      } catch { self.error = error.localizedDescription }
    }
  }

  func resumeJob(_ id: UUID) {
    Task {
      do {
        let state = try await store.loadState(id)
        guard ![.completed, .cancelled].contains(state.lifecycle) else { return }
        var control = try await store.loadControl(id)
        if control.queueSequence == nil {
          control.queueSequence = try await schedulerStore.reserve(count: 1).first
        }
        control.queueDisposition = .ready
        control.interruption = nil
        control.cancelRequestedForAttempt = nil
        try await store.saveControl(control, id: id)
        _ = try await schedulerStore.setSuspended(false)
        await reload()
        startNextIfPossible()
      } catch { self.error = error.localizedDescription }
    }
  }

  func cancelJob(_ id: UUID) {
    Task {
      do {
        var state = try await store.loadState(id)
        if activeJobID == id {
          try await runner?.interrupt(.cancel)
        } else if ![.completed, .cancelled].contains(state.lifecycle) {
          try state.transition(to: .cancelled)
          try await store.saveState(state)
          try await store.setQueueDisposition(.held, id: id)
        }
        await reload()
      } catch { self.error = error.localizedDescription }
    }
  }

  var queuedCount: Int {
    rows.filter {
      $0.control.queueDisposition == .ready
        && [.queued, .paused].contains($0.state.lifecycle)
    }.count
  }

  var runningCount: Int { rows.filter { $0.state.lifecycle == .running }.count }

  private func startNextIfPossible() {
    guard !isSuspended, runner == nil else { return }
    guard !rows.contains(where: { $0.state.lifecycle == .running }) else { return }
    guard let next = rows.first(where: {
      $0.control.queueDisposition == .ready
        && [.queued, .paused].contains($0.state.lifecycle)
    }) else { return }

    let runner = BookJobProcessRunner(executable: executable, store: store)
    self.runner = runner
    activeJobID = next.id
    runnerTask = Task { [weak self] in
      guard let self else { return }
      var launchFailure = false
      do {
        for try await _ in runner.run(id: next.id) { await self.reload() }
      } catch {
        let state = try? await self.store.loadState(next.id)
        launchFailure = state?.lifecycle == .queued
        self.error = error.localizedDescription
      }
      self.runner = nil
      self.runnerTask = nil
      self.activeJobID = nil
      if launchFailure {
        _ = try? await self.schedulerStore.setSuspended(true)
      }
      await self.reload()
      self.startNextIfPossible()
    }
  }

  nonisolated static func processIsAlive(_ pid: Int32?) -> Bool {
    guard let pid, pid > 0 else { return false }
    if Darwin.kill(pid, 0) == 0 { return true }
    return errno == EPERM
  }
}

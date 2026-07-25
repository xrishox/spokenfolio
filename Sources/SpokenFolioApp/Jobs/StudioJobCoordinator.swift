import BookJobKit
import Foundation
import Observation

/// SwiftUI observation adapter over the process-wide `JobSchedulerService`
/// actor. All scheduling authority lives in the service; this class mirrors
/// its snapshots onto the main actor and keeps the historical GUI surface.
@MainActor
@Observable
final class StudioJobCoordinator {
  typealias Row = JobSchedulerSnapshot.Row

  private(set) var rows: [Row] = []
  private(set) var scanIssues: [BookJobStore.ScanIssue] = []
  private(set) var isSuspended = true
  private(set) var activeJobID: UUID?
  private(set) var deliveryActiveJobID: UUID?
  private(set) var error: String?

  @ObservationIgnored let service: JobSchedulerService
  @ObservationIgnored private var subscription: Task<Void, Never>?

  init(
    store: BookJobStore = BookJobStore(root: AppPaths.productionJobRoot),
    schedulerStore: BookSchedulerStore = BookSchedulerStore(url: AppPaths.schedulerStateURL),
    schedulerLockURL: URL? = AppPaths.schedulerLockURL,
    executable: URL? = nil
  ) {
    self.service = JobSchedulerService(
      store: store, schedulerStore: schedulerStore,
      schedulerLockURL: schedulerLockURL, executable: executable)
  }

  init(service: JobSchedulerService) {
    self.service = service
  }

  deinit {
    subscription?.cancel()
  }

  private func apply(_ snapshot: JobSchedulerSnapshot) {
    rows = snapshot.rows
    scanIssues = snapshot.scanIssues
    isSuspended = snapshot.isSuspended
    activeJobID = snapshot.activeJobID
    deliveryActiveJobID = snapshot.deliveryActiveJobID
    error = snapshot.error
  }

  func start() {
    guard subscription == nil else { return }
    subscription = Task { [weak self, service] in
      for await snapshot in await service.snapshots() {
        guard let self else { return }
        self.apply(snapshot)
      }
    }
    Task { [service] in
      apply(await service.start())
    }
  }

  func prepareForTermination() async throws {
    try await service.prepareForTermination()
    apply(await service.currentSnapshot)
  }

  func reload() async {
    apply(await service.reload())
  }

  func enqueue(_ requests: [BookJobRequest]) async -> [UUID: String] {
    let failures = await service.enqueue(requests)
    apply(await service.currentSnapshot)
    return failures
  }

  func resumeQueue() {
    Task { [service] in
      await service.resumeQueue()
      apply(await service.currentSnapshot)
    }
  }

  /// Preempts the queue for one book; returns a refusal message on failure.
  @discardableResult
  func runNext(_ id: UUID) async -> String? {
    let failure = await service.runNext(id)
    apply(await service.currentSnapshot)
    return failure
  }

  /// Applies a new waiting-queue order; returns the scheduler's refusal
  /// message when the queue changed underneath the caller.
  @discardableResult
  func reorder(_ orderedIDs: [UUID]) async -> String? {
    let failure = await service.reorder(orderedIDs)
    apply(await service.currentSnapshot)
    return failure
  }

  func pauseQueue(interruptActive: Bool = false) {
    Task { [service] in
      await service.pauseQueue(interruptActive: interruptActive)
      apply(await service.currentSnapshot)
    }
  }

  func pauseJob(_ id: UUID) {
    Task { await pauseJobs([id]) }
  }

  func resumeJob(_ id: UUID) {
    Task { await resumeJobs([id]) }
  }

  func cancelJob(_ id: UUID) {
    Task { await cancelJobs([id]) }
  }

  func pauseJobs(_ ids: Set<UUID>) async {
    await service.pauseJobs(ids)
    apply(await service.currentSnapshot)
  }

  func resumeJobs(_ ids: Set<UUID>) async {
    await service.resumeJobs(ids)
    apply(await service.currentSnapshot)
  }

  func cancelJobs(_ ids: Set<UUID>) async {
    await service.cancelJobs(ids)
    apply(await service.currentSnapshot)
  }

  func cancelWaitingJobs(includeActive: Bool = false) async {
    await service.cancelWaitingJobs(includeActive: includeActive)
    apply(await service.currentSnapshot)
  }

  var queuedCount: Int {
    rows.filter {
      ($0.control.queueDisposition == .ready
        && [.queued, .paused].contains($0.state.lifecycle))
        || ($0.control.queueDisposition == .retryReady
          && $0.state.lifecycle == .needsAttention)
    }.count
  }

  var runningCount: Int { rows.filter { $0.state.lifecycle == .running }.count }

  nonisolated static func processIsAlive(_ pid: Int32?) -> Bool {
    JobSchedulerService.processIsAlive(pid)
  }
}

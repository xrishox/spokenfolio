import BookJobKit
import Foundation
@testable import SpokenFolioApp
import XCTest

@MainActor
final class ProductionWorkspaceTests: XCTestCase {
  func testCancelWaitingLeavesRunningAndTerminalJobsAlone() async throws {
    let fixture = try Fixture()
    let queued = try await fixture.makeJob("Queued")
    let paused = try await fixture.makeJob("Paused", lifecycle: .paused)
    let review = try await fixture.makeJob("Review", lifecycle: .needsAttention)
    let running = try await fixture.makeJob("Running", lifecycle: .running)
    let completed = try await fixture.makeJob("Completed", lifecycle: .completed)

    await fixture.coordinator.reload()
    await fixture.coordinator.cancelWaitingJobs()

    let queuedState = try await fixture.store.loadState(queued)
    let pausedState = try await fixture.store.loadState(paused)
    let reviewState = try await fixture.store.loadState(review)
    let runningState = try await fixture.store.loadState(running)
    let completedState = try await fixture.store.loadState(completed)
    XCTAssertEqual(queuedState.lifecycle, .cancelled)
    XCTAssertEqual(pausedState.lifecycle, .cancelled)
    XCTAssertEqual(reviewState.lifecycle, .cancelled)
    XCTAssertEqual(runningState.lifecycle, .running)
    XCTAssertEqual(completedState.lifecycle, .completed)
  }

  func testBulkResumeUsesRetryDispositionAndWakesQueue() async throws {
    let fixture = try Fixture()
    let paused = try await fixture.makeJob("Paused", lifecycle: .paused)
    let review = try await fixture.makeJob("Review", lifecycle: .needsAttention)
    _ = try await fixture.makeJob("Already Running", lifecycle: .running)
    try await fixture.store.setQueueDisposition(.held, id: paused)
    try await fixture.store.setQueueDisposition(.held, id: review)

    await fixture.coordinator.reload()
    await fixture.coordinator.resumeJobs([paused, review])

    let pausedControl = try await fixture.store.loadControl(paused)
    let reviewControl = try await fixture.store.loadControl(review)
    let scheduler = try await fixture.scheduler.load()
    XCTAssertEqual(pausedControl.queueDisposition, .ready)
    XCTAssertEqual(reviewControl.queueDisposition, .retryReady)
    XCTAssertFalse(scheduler.isSuspended)
  }

  func testJobPresentationSeparatesQueueFromHistoryAndKeepsFIFO() async throws {
    let fixture = try Fixture()
    let first = try await fixture.makeJob("Zulu")
    let second = try await fixture.makeJob("Alpha")
    let completed = try await fixture.makeJob("Done", lifecycle: .completed)
    try await fixture.store.enqueue(first, sequence: 4)
    try await fixture.store.enqueue(second, sequence: 8)
    await fixture.coordinator.reload()

    XCTAssertEqual(
      ProductionJobPresentation.rows(
        fixture.coordinator.rows, mode: .queue, search: "").map(\.id),
      [first, second])
    XCTAssertEqual(
      ProductionJobPresentation.rows(
        fixture.coordinator.rows, mode: .history, search: "").map(\.id),
      [completed])
    XCTAssertEqual(
      ProductionJobPresentation.rows(
        fixture.coordinator.rows, mode: .queue, search: "alpha").map(\.id),
      [second])
  }
}

@MainActor
private final class Fixture {
  let root: URL
  let store: BookJobStore
  let scheduler: BookSchedulerStore
  let coordinator: StudioJobCoordinator
  private var leases: [BookJobLease] = []

  init() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("spokenfolio-production-tests-\(UUID())", isDirectory: true)
    let store = BookJobStore(root: root.appendingPathComponent("jobs", isDirectory: true))
    let scheduler = BookSchedulerStore(url: root.appendingPathComponent("scheduler.json"))
    self.store = store
    self.scheduler = scheduler
    coordinator = StudioJobCoordinator(
      store: store, schedulerStore: scheduler, schedulerLockURL: nil,
      executable: URL(fileURLWithPath: "/usr/bin/false"))
  }

  deinit { try? FileManager.default.removeItem(at: root) }

  func makeJob(_ title: String, lifecycle: BookJobLifecycle = .queued) async throws -> UUID {
    let id = UUID()
    let request = BookJobRequest(
      id: id, title: title, author: nil,
      source: .init(
        path: root.appendingPathComponent("\(id).epub").path,
        sha256: String(repeating: "a", count: 64), format: "epub", importerVersion: 1),
      narration: .init(
        backendID: "siri", modelID: "siri-private", voiceID: "test.voice",
        includedSectionIDs: [], bitrateKbps: 64, workers: 1,
        paragraphPauseSeconds: 0.6, chapterPauseSeconds: 1.75,
        announceTitles: true),
      m4bOutputPath: root.appendingPathComponent("\(id).m4b").path)
    var state = try await store.create(request)
    if lifecycle != .queued {
      try state.transition(to: .running)
      if lifecycle != .running { try state.transition(to: lifecycle) }
      try await store.saveState(state)
      if lifecycle == .running {
        leases.append(try await store.acquireLease(id))
      }
    }
    return id
  }
}

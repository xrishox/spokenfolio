import BookJobKit
import Foundation
import XCTest

@testable import SpokenFolioApp

/// Two-lane dispatch selection: the heavyweight lane never runs delivery-only
/// jobs, the delivery lane never waits behind synthesis, and a send always
/// waits for other active work on the same book.
final class JobSchedulerLanesTests: XCTestCase {
  private func request(
    operation: BookJobRequest.Operation, catalogID: UUID
  ) -> BookJobRequest {
    var request = BookJobRequest(
      catalogID: catalogID,
      title: "Fixture", author: nil,
      source: .init(
        path: "/tmp/x.epub", sha256: String(repeating: "a", count: 64),
        format: "epub", importerVersion: 1),
      narration: .init(
        backendID: "siri", modelID: "siri-private", voiceID: "voice",
        includedSectionIDs: [], bitrateKbps: 256, workers: 4,
        paragraphPauseSeconds: 0.6, chapterPauseSeconds: 1.75, announceTitles: false),
      m4bOutputPath: "/tmp/x.m4b",
      storyteller: operation == .storytellerDelivery
        ? .init(connectionID: UUID(), remoteBookID: UUID(), products: [.sourceEPUB])
        : nil,
      operation: operation)
    _ = request
    return request
  }

  private func row(
    operation: BookJobRequest.Operation, catalogID: UUID = UUID(),
    lifecycle: BookJobLifecycle = .queued,
    disposition: BookJobControl.QueueDisposition = .ready
  ) -> JobSchedulerSnapshot.Row {
    let request = request(operation: operation, catalogID: catalogID)
    var state = BookJobState(jobID: request.id, requestSHA256: String(repeating: "b", count: 64))
    if lifecycle != state.lifecycle {
      state.lifecycle = lifecycle
    }
    return .init(
      request: request, state: state,
      control: BookJobControl(queueDisposition: disposition))
  }

  func testHeavyLaneSkipsDeliveryJobsAndBusyLane() {
    let delivery = row(operation: .storytellerDelivery)
    let production = row(operation: .production)
    XCTAssertEqual(
      JobSchedulerSnapshot.heavyCandidate(rows: [delivery, production])?.id, production.id)
    // A running production job blocks the heavy lane...
    let runningProduction = row(operation: .production, lifecycle: .running)
    XCTAssertNil(JobSchedulerSnapshot.heavyCandidate(rows: [runningProduction, production]))
    // ...but a running delivery does not.
    let runningDelivery = row(operation: .storytellerDelivery, lifecycle: .running)
    XCTAssertEqual(
      JobSchedulerSnapshot.heavyCandidate(rows: [runningDelivery, production])?.id,
      production.id)
  }

  func testDeliveryLaneRunsAlongsideSynthesisButNotSameBook() {
    let bookA = UUID()
    let bookB = UUID()
    let runningProduction = row(operation: .production, catalogID: bookA, lifecycle: .running)
    let sendOtherBook = row(operation: .storytellerDelivery, catalogID: bookB)
    // An unrelated send dispatches while synthesis runs.
    XCTAssertEqual(
      JobSchedulerSnapshot.deliveryCandidate(rows: [runningProduction, sendOtherBook])?.id,
      sendOtherBook.id)
    // A send for the SAME book as the running job waits.
    let sendSameBook = row(operation: .storytellerDelivery, catalogID: bookA)
    XCTAssertNil(
      JobSchedulerSnapshot.deliveryCandidate(rows: [runningProduction, sendSameBook]))
    // A dispatchable same-book job queued ahead also blocks the send...
    let queuedProduction = row(operation: .production, catalogID: bookA)
    XCTAssertNil(
      JobSchedulerSnapshot.deliveryCandidate(rows: [queuedProduction, sendSameBook]))
    // ...but a held same-book job does not.
    let heldProduction = row(operation: .production, catalogID: bookA, disposition: .held)
    XCTAssertEqual(
      JobSchedulerSnapshot.deliveryCandidate(rows: [heldProduction, sendSameBook])?.id,
      sendSameBook.id)
  }

  func testOnlyOneDeliveryChildAtATime() {
    let runningDelivery = row(operation: .storytellerDelivery, lifecycle: .running)
    let waitingDelivery = row(operation: .storytellerDelivery)
    XCTAssertNil(
      JobSchedulerSnapshot.deliveryCandidate(rows: [runningDelivery, waitingDelivery]))
  }

  func testReorderRewritesWaitingSequence() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("scheduler-reorder-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = BookJobStore(root: root.appendingPathComponent("jobs"))
    let schedulerStore = BookSchedulerStore(url: root.appendingPathComponent("scheduler.json"))
    let service = JobSchedulerService(
      store: store, schedulerStore: schedulerStore, schedulerLockURL: nil)
    // Suspended so nothing dispatches while the order changes.
    _ = try await schedulerStore.setSuspended(true)

    let first = request(operation: .production, catalogID: UUID())
    let second = request(operation: .production, catalogID: UUID())
    let third = request(operation: .production, catalogID: UUID())
    for (index, request) in [first, second, third].enumerated() {
      _ = try await store.create(request)
      try await store.enqueue(
        request.id, sequence: try await schedulerStore.reserve(count: 1).first!)
      _ = index
    }
    _ = try await schedulerStore.setSuspended(true)
    var order = (await service.reload()).rows.map(\.id)
    XCTAssertEqual(order, [first.id, second.id, third.id])

    // A stale set is refused untouched.
    let refusal = await service.reorder([third.id, first.id])
    XCTAssertNotNil(refusal)
    order = (await service.reload()).rows.map(\.id)
    XCTAssertEqual(order, [first.id, second.id, third.id])

    // The complete set in a new order is applied durably.
    let failure = await service.reorder([third.id, first.id, second.id])
    XCTAssertNil(failure)
    order = (await service.reload()).rows.map(\.id)
    XCTAssertEqual(order, [third.id, first.id, second.id])
  }
}

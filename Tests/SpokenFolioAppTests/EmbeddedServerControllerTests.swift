import Vapor
import XCTest

@testable import SpokenFolioApp

@MainActor
final class EmbeddedServerControllerTests: XCTestCase {
  func testRestartWaitsForPreviousRunToStop() async throws {
    let probe = ServerLifecycleProbe()
    let controller = EmbeddedServerController {
      let id = await probe.created()
      let app = try await Application.make(.testing)
      return EmbeddedServerHandle(
        application: app,
        config: ServerConfig(),
        run: { await probe.run(id: id) },
        waitUntilReady: {},
        requestStop: { Task { await probe.stop(id: id) } },
        shutdown: { try? await app.asyncShutdown() })
    }

    controller.start()
    try await waitUntil { await probe.activeCount == 1 }
    await controller.restart()
    try await waitUntil {
      let created = await probe.createdCount
      let active = await probe.activeCount
      return created == 2 && active == 1
    }

    let maximum = await probe.maximumActiveCount
    XCTAssertEqual(maximum, 1)
    await controller.stop()
  }

  func testStartIsIdempotentWhileRunning() async throws {
    let probe = ServerLifecycleProbe()
    let controller = EmbeddedServerController {
      let id = await probe.created()
      let app = try await Application.make(.testing)
      return EmbeddedServerHandle(
        application: app,
        config: ServerConfig(),
        run: { await probe.run(id: id) },
        waitUntilReady: {},
        requestStop: { Task { await probe.stop(id: id) } },
        shutdown: { try? await app.asyncShutdown() })
    }

    controller.start()
    controller.start()
    try await waitUntil { await probe.activeCount == 1 }
    let created = await probe.createdCount
    XCTAssertEqual(created, 1)
    await controller.stop()
  }

  func testStartupFailureIsNotImmediatelyOverwrittenByStopped() async throws {
    let controller = EmbeddedServerController {
      let app = try await Application.make(.testing)
      return EmbeddedServerHandle(
        application: app, config: ServerConfig(),
        run: { throw ControllerTestFailure.timedOut },
        waitUntilReady: { throw ControllerTestFailure.timedOut },
        requestStop: {}, shutdown: { try? await app.asyncShutdown() })
    }
    var events: [String] = []
    controller.onEvent = { event in
      switch event {
      case .starting: events.append("starting")
      case .ready: events.append("ready")
      case .failed: events.append("failed")
      case .stopped: events.append("stopped")
      }
    }
    controller.start()
    try await waitUntil { !controller.isRunning }
    XCTAssertEqual(events, ["starting", "failed"])
  }

  private func waitUntil(
    timeout: Duration = .seconds(2), condition: @escaping () async -> Bool
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !(await condition()) {
      guard clock.now < deadline else { throw ControllerTestFailure.timedOut }
      try await Task.sleep(for: .milliseconds(5))
    }
  }
}

private enum ControllerTestFailure: Error { case timedOut }

private actor ServerLifecycleProbe {
  private(set) var createdCount = 0
  private(set) var activeCount = 0
  private(set) var maximumActiveCount = 0
  private var stopped: Set<Int> = []
  private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]

  func created() -> Int {
    createdCount += 1
    return createdCount
  }

  func run(id: Int) async {
    activeCount += 1
    maximumActiveCount = max(maximumActiveCount, activeCount)
    if !stopped.contains(id) {
      await withCheckedContinuation { waiters[id] = $0 }
    }
    activeCount -= 1
  }

  func stop(id: Int) {
    stopped.insert(id)
    waiters.removeValue(forKey: id)?.resume()
  }
}

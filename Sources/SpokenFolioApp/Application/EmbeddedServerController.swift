import Foundation
import SiriTTSCore
import Vapor

struct EmbeddedServerHandle: @unchecked Sendable {
  let application: Application
  let config: ServerConfig
  let run: @Sendable () async throws -> Void
  let waitUntilReady: @Sendable () async throws -> Void
  let requestStop: @Sendable () -> Void
  let shutdown: @Sendable () async -> Void
}

@MainActor
final class EmbeddedServerController {
  enum Event {
    case starting
    case ready(EmbeddedServerHandle)
    case failed(Error?)
    case stopped
  }

  typealias Factory = @Sendable () async throws -> EmbeddedServerHandle

  var onEvent: ((Event) -> Void)?
  private(set) var activeHandle: EmbeddedServerHandle?

  private let factory: Factory
  private var task: Task<Void, Never>?
  private var generation = UUID()
  private var retryAttempts = 0
  private var retryTask: Task<Void, Never>?

  init(factory: @escaping Factory) { self.factory = factory }

  var isRunning: Bool { task != nil }

  func start() {
    guard task == nil else { return }
    let currentGeneration = UUID()
    generation = currentGeneration
    onEvent?(.starting)
    let factory = factory
    task = Task { [weak self] in
      var reportedFailure = false
      do {
        let handle = try await factory()
        guard !Task.isCancelled else {
          handle.requestStop()
          await handle.shutdown()
          self?.complete(generation: currentGeneration, emitStopped: true)
          return
        }
        let runTask = Task { try await handle.run() }
        do {
          try await handle.waitUntilReady()
          self?.becameReady(handle, generation: currentGeneration)
          try await runTask.value
        } catch {
          if !Task.isCancelled {
            reportedFailure = true
            self?.report(error, generation: currentGeneration)
          }
          runTask.cancel()
          // The Vapor application must not be shut down while execute() is
          // still in flight; wait for the cancelled run to unwind first.
          _ = try? await runTask.value
        }
        await handle.shutdown()
      } catch {
        if !Task.isCancelled {
          reportedFailure = true
          self?.report(error, generation: currentGeneration)
        }
      }
      self?.complete(generation: currentGeneration, emitStopped: !reportedFailure)
    }
  }

  func stop() async {
    retryTask?.cancel()
    retryTask = nil
    retryAttempts = 0
    guard let task else { return }
    activeHandle?.requestStop()
    task.cancel()
    await task.value
  }

  func stopImmediately() {
    retryTask?.cancel()
    retryTask = nil
    retryAttempts = 0
    activeHandle?.requestStop()
    task?.cancel()
  }

  func restart() async {
    await stop()
    start()
  }

  private func becameReady(_ handle: EmbeddedServerHandle, generation: UUID) {
    guard self.generation == generation else {
      handle.requestStop()
      Task { await handle.shutdown() }
      return
    }
    activeHandle = handle
    retryAttempts = 0
    onEvent?(.ready(handle))
  }

  private func report(_ error: Error, generation: UUID) {
    guard self.generation == generation else { return }
    onEvent?(.failed(error))
  }

  private func complete(generation: UUID, emitStopped: Bool) {
    guard self.generation == generation else { return }
    activeHandle = nil
    task = nil
    if emitStopped {
      onEvent?(.stopped)
    } else {
      // A failed start or a server task that died on its own (for example a
      // bind race against a just-terminated instance) retries with backoff
      // instead of leaving the app alive with a dead gateway. An explicit
      // stop() cancels the retry.
      scheduleRetry()
    }
  }

  private func scheduleRetry() {
    guard retryAttempts < 5, retryTask == nil else { return }
    retryAttempts += 1
    let delay = Duration.seconds(min(8, 1 << retryAttempts))
    retryTask = Task { [weak self] in
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled else { return }
      await MainActor.run {
        guard let self, self.retryTask != nil else { return }
        self.retryTask = nil
        self.start()
      }
    }
  }
}

import Foundation
import SiriTTSCore
import Vapor

struct EmbeddedServerHandle: @unchecked Sendable {
  let application: Application
  let config: ServerConfig
  let run: @Sendable () async throws -> Void
  let requestStop: @Sendable () -> Void
  let shutdown: @Sendable () async -> Void
}

@MainActor
final class EmbeddedServerController {
  enum Event {
    case starting
    case ready(EmbeddedServerHandle)
    case failed(ServiceError?)
    case stopped
  }

  typealias Factory = @Sendable () async throws -> EmbeddedServerHandle

  var onEvent: ((Event) -> Void)?
  private(set) var activeHandle: EmbeddedServerHandle?

  private let factory: Factory
  private var task: Task<Void, Never>?
  private var generation = UUID()

  init(factory: @escaping Factory) { self.factory = factory }

  var isRunning: Bool { task != nil }

  func start() {
    guard task == nil else { return }
    let currentGeneration = UUID()
    generation = currentGeneration
    onEvent?(.starting)
    let factory = factory
    task = Task { [weak self] in
      do {
        let handle = try await factory()
        guard !Task.isCancelled else {
          handle.requestStop()
          await handle.shutdown()
          self?.complete(generation: currentGeneration)
          return
        }
        self?.becameReady(handle, generation: currentGeneration)
        do {
          try await handle.run()
        } catch {
          if !Task.isCancelled {
            self?.report(error, generation: currentGeneration)
          }
        }
        await handle.shutdown()
      } catch {
        if !Task.isCancelled {
          self?.report(error, generation: currentGeneration)
        }
      }
      self?.complete(generation: currentGeneration)
    }
  }

  func stop() async {
    guard let task else { return }
    activeHandle?.requestStop()
    task.cancel()
    await task.value
  }

  func stopImmediately() {
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
    onEvent?(.ready(handle))
  }

  private func report(_ error: Error, generation: UUID) {
    guard self.generation == generation else { return }
    onEvent?(.failed(error as? ServiceError))
  }

  private func complete(generation: UUID) {
    guard self.generation == generation else { return }
    activeHandle = nil
    task = nil
    onEvent?(.stopped)
  }
}

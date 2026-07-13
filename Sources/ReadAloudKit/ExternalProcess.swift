import Darwin
import Foundation

package struct ExternalProcessResult: Sendable {
  package var status: Int32
  package var stdout: Data
  package var stderr: Data
}

package final class ExternalProcessRunner: @unchecked Sendable {
  private let lock = NSLock()
  private var process: Process?

  package init() {}

  package func run(
    executable: URL, arguments: [String], environment: [String: String],
    onStderr: (@Sendable (String) -> Void)? = nil
  ) async throws -> ExternalProcessResult {
    try Task.checkCancellation()
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.environment = environment
    process.standardInput = FileHandle.nullDevice
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    lock.withLock { self.process = process }

    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let outputBuffer = LockedDataBuffer(limit: 1 << 20)
        let errorBuffer = LockedDataBuffer(limit: 1 << 20)
        stdout.fileHandleForReading.readabilityHandler = { handle in
          let data = handle.availableData
          if data.isEmpty { handle.readabilityHandler = nil } else { outputBuffer.append(data) }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
          let data = handle.availableData
          if data.isEmpty {
            handle.readabilityHandler = nil
          } else {
            errorBuffer.append(data)
            onStderr?(String(decoding: data, as: UTF8.self))
          }
        }
        process.terminationHandler = { [weak self] process in
          stdout.fileHandleForReading.readabilityHandler = nil
          stderr.fileHandleForReading.readabilityHandler = nil
          // A termination callback may run before the readability queues have consumed the final
          // pipe bytes. Drain those bytes synchronously so semantic verifiers never see truncated
          // output from a successful child.
          outputBuffer.append(stdout.fileHandleForReading.readDataToEndOfFile())
          errorBuffer.append(stderr.fileHandleForReading.readDataToEndOfFile())
          self?.lock.withLock { self?.process = nil }
          continuation.resume(
            returning: ExternalProcessResult(
              status: process.terminationStatus,
              stdout: outputBuffer.snapshot(), stderr: errorBuffer.snapshot()))
        }
        guard !Task.isCancelled else {
          stdout.fileHandleForReading.readabilityHandler = nil
          stderr.fileHandleForReading.readabilityHandler = nil
          self.lock.withLock { self.process = nil }
          continuation.resume(throwing: CancellationError())
          return
        }
        do {
          try process.run()
          // Cancellation can race the narrow interval between the guard above and launch.
          if Task.isCancelled { self.cancel() }
        } catch {
          stdout.fileHandleForReading.readabilityHandler = nil
          stderr.fileHandleForReading.readabilityHandler = nil
          self.lock.withLock { self.process = nil }
          continuation.resume(throwing: error)
        }
      }
    } onCancel: {
      self.cancel()
    }
  }

  package func cancel() {
    let target = lock.withLock { process }
    guard let target, target.isRunning else { return }
    target.interrupt()
    DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [weak self, weak target] in
      guard let self, let target, target.isRunning else { return }
      target.terminate()
      DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [weak self, weak target] in
        guard let self, let target, target.isRunning else { return }
        self.lock.withLock {
          if target.isRunning { _ = Darwin.kill(target.processIdentifier, SIGKILL) }
        }
      }
    }
  }
}

private final class LockedDataBuffer: @unchecked Sendable {
  private let lock = NSLock()
  private let limit: Int
  private var data = Data()
  init(limit: Int) { self.limit = limit }
  func append(_ next: Data) {
    lock.withLock {
      data.append(next)
      if data.count > limit { data.removeFirst(data.count - limit) }
    }
  }
  func snapshot() -> Data { lock.withLock { data } }
}

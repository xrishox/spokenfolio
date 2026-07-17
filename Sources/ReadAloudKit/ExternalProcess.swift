import Darwin
import Foundation

package struct ExternalProcessResult: Sendable {
  package var status: Int32
  package var stdout: Data
  package var stderr: Data
}

package enum ExternalProcessError: Error, LocalizedError, Equatable {
  case timedOut

  package var errorDescription: String? {
    "The external tool exceeded its execution deadline."
  }
}

package final class ExternalProcessRunner: @unchecked Sendable {
  package init() {}

  package func run(
    executable: URL, arguments: [String], environment: [String: String],
    timeout: Duration = .seconds(1_800),
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
    let termination = ExternalProcessTermination()

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
        process.terminationHandler = { process in
          stdout.fileHandleForReading.readabilityHandler = nil
          stderr.fileHandleForReading.readabilityHandler = nil
          // A termination callback may run before the readability queues have consumed the final
          // pipe bytes. Drain those bytes synchronously so semantic verifiers never see truncated
          // output from a successful child.
          outputBuffer.append(stdout.fileHandleForReading.readDataToEndOfFile())
          errorBuffer.append(stderr.fileHandleForReading.readDataToEndOfFile())
          let reason = termination.finish()
          switch reason {
          case .cancelled:
            continuation.resume(throwing: CancellationError())
          case .timedOut:
            continuation.resume(throwing: ExternalProcessError.timedOut)
          case nil:
            continuation.resume(
              returning: ExternalProcessResult(
                status: process.terminationStatus,
                stdout: outputBuffer.snapshot(), stderr: errorBuffer.snapshot()))
          }
        }
        guard !Task.isCancelled else {
          stdout.fileHandleForReading.readabilityHandler = nil
          stderr.fileHandleForReading.readabilityHandler = nil
          continuation.resume(throwing: CancellationError())
          return
        }
        do {
          try process.run()
          termination.setTimeoutTask(
            Task {
              do { try await Task.sleep(for: timeout) } catch { return }
              guard termination.request(.timedOut) else { return }
              Self.terminate(process)
            })
          // Cancellation can race the narrow interval between the guard above and launch.
          if Task.isCancelled {
            _ = termination.request(.cancelled)
            Self.terminate(process)
          }
        } catch {
          stdout.fileHandleForReading.readabilityHandler = nil
          stderr.fileHandleForReading.readabilityHandler = nil
          termination.cancelTimer()
          continuation.resume(throwing: error)
        }
      }
    } onCancel: {
      _ = termination.request(.cancelled)
      Self.terminate(process)
    }
  }

  private static func terminate(_ target: Process) {
    guard target.isRunning else { return }
    target.interrupt()
    DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [weak target] in
      guard let target, target.isRunning else { return }
      target.terminate()
      DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [weak target] in
        guard let target, target.isRunning else { return }
        _ = Darwin.kill(target.processIdentifier, SIGKILL)
      }
    }
  }
}

private final class ExternalProcessTermination: @unchecked Sendable {
  enum Reason { case cancelled, timedOut }
  private let lock = NSLock()
  private var reason: Reason?
  private var timeoutTask: Task<Void, Never>?

  func request(_ value: Reason) -> Bool {
    lock.withLock {
      guard reason == nil else { return false }
      reason = value
      return true
    }
  }

  func setTimeoutTask(_ task: Task<Void, Never>) {
    lock.withLock {
      if reason == nil { timeoutTask = task } else { task.cancel() }
    }
  }

  func cancelTimer() { lock.withLock { timeoutTask?.cancel(); timeoutTask = nil } }

  func finish() -> Reason? {
    lock.withLock {
      timeoutTask?.cancel()
      timeoutTask = nil
      return reason
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

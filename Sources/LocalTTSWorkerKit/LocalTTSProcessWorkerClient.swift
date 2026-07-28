import Darwin
import Foundation
import TTSKit

/// Process-neutral client for a same-binary local TTS worker mode. The pool
/// guarantees one request at a time per client; the lock protects only process
/// liveness and hard termination across cancellation races.
package final class LocalTTSProcessWorkerClient: LocalTTSWorkerTransport, @unchecked Sendable {
  private let process: Process
  private let input: FileHandle
  private let output: FileHandle
  private let processLock = NSLock()

  package init(arguments: [String], executableURL: URL? = nil) throws {
    let override = ProcessInfo.processInfo.environment["SPOKENFOLIO_WORKER_EXECUTABLE"]
      .map { URL(fileURLWithPath: $0) }
    guard
      let executable = executableURL
        ?? override
        ?? Bundle.main.executableURL
        ?? URL(
          string: CommandLine.arguments[0],
          relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
    else { throw LocalTTSWorkerClientError.notRunning }

    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.standardInput = stdinPipe
    process.standardOutput = stdoutPipe
    process.standardError = FileHandle.standardError
    do { try process.run() } catch { throw LocalTTSWorkerClientError.notRunning }

    self.process = process
    input = stdoutPipe.fileHandleForReading
    output = stdinPipe.fileHandleForWriting
  }

  package func synthesize(
    request: TTSSynthesisRequest, deadline: ContinuousClock.Instant
  ) async throws -> LocalTTSWorkerResult {
    let wire = LocalTTSWorkerRequest(request: request)
    return try await withTaskCancellationHandler {
      try await withThrowingTaskGroup(of: LocalTTSWorkerResult.self) { group in
        group.addTask {
          try await Task.detached(priority: .userInitiated) {
            guard self.isRunning else { throw LocalTTSWorkerClientError.notRunning }
            do {
              try LocalTTSWorkerFraming.writeRequest(wire, to: self.output)
              return try LocalTTSWorkerFraming.readDetailedResponse(
                from: self.input, requestID: wire.id)
            } catch let error as LocalTTSWorkerClientError {
              throw error
            } catch {
              throw LocalTTSWorkerClientError.protocolFailure
            }
          }.value
        }
        group.addTask {
          let clock = ContinuousClock()
          guard clock.now < deadline else { throw LocalTTSWorkerClientError.timeout }
          try await clock.sleep(until: deadline)
          throw LocalTTSWorkerClientError.timeout
        }
        do {
          guard let result = try await group.next() else {
            throw LocalTTSWorkerClientError.protocolFailure
          }
          group.cancelAll()
          return result
        } catch {
          if (error as? LocalTTSWorkerClientError)?.requiresReplacement != false {
            terminateHard()
          }
          group.cancelAll()
          throw error
        }
      }
    } onCancel: {
      self.terminateHard()
    }
  }

  private var isRunning: Bool {
    processLock.withLock { process.isRunning }
  }

  package func terminateHard() {
    processLock.lock()
    defer { processLock.unlock() }
    guard process.isRunning else { return }
    _ = Darwin.kill(process.processIdentifier, SIGKILL)
    try? output.close()
    try? input.close()
  }
}

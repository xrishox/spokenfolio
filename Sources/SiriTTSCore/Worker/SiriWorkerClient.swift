import Darwin
import Foundation

enum WorkerClientError: Error, Sendable {
  case notRunning
  case timeout
  case remote(String)
  case protocolFailure

  var requiresReplacement: Bool {
    switch self {
    case .remote("synthesis_failed"): false
    default: true
    }
  }
}

protocol SiriWorkerTransport: AnyObject, Sendable {
  func synthesizeDetailed(
    text: String, splitSentences: Bool, includeTimings: Bool, timeout: Duration
  ) async throws -> (pcm: Data, timingsJSON: Data?)
  func terminateHard()
}

extension SiriWorkerTransport {
  func synthesize(text: String, splitSentences: Bool, timeout: Duration) async throws -> Data {
    try await synthesizeDetailed(
      text: text, splitSentences: splitSentences, includeTimings: false, timeout: timeout
    ).pcm
  }
}

final class SiriWorkerClient: SiriWorkerTransport, @unchecked Sendable {
  let voiceID: String

  private let process: Process
  private let input: FileHandle
  private let output: FileHandle
  private let processLock = NSLock()

  init(voiceID: String) throws {
    self.voiceID = voiceID
    // Under `swift test`, Bundle.main is the xctest runner, which has no
    // `--siri-worker` mode; tests point this at the built server binary.
    let override = ProcessInfo.processInfo.environment["SPOKENFOLIO_WORKER_EXECUTABLE"]
      .map { URL(fileURLWithPath: $0) }
    guard
      let executable = override
        ?? Bundle.main.executableURL
        ?? URL(
          string: CommandLine.arguments[0],
          relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
    else { throw WorkerClientError.notRunning }

    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    let process = Process()
    process.executableURL = executable
    process.arguments = ["--siri-worker", voiceID]
    process.standardInput = stdinPipe
    process.standardOutput = stdoutPipe
    process.standardError = FileHandle.standardError
    try process.run()

    self.process = process
    input = stdoutPipe.fileHandleForReading
    output = stdinPipe.fileHandleForWriting
  }

  func synthesizeDetailed(
    text: String, splitSentences: Bool, includeTimings: Bool, timeout: Duration
  ) async throws -> (pcm: Data, timingsJSON: Data?) {
    let request = WorkerRequest(
      id: UUID(), text: text, splitSentences: splitSentences, includeTimings: includeTimings)
    return try await withTaskCancellationHandler {
      try await withThrowingTaskGroup(of: (pcm: Data, timingsJSON: Data?).self) { group in
        group.addTask {
          try await Task.detached(priority: .userInitiated) {
            guard self.isRunning else { throw WorkerClientError.notRunning }
            do {
              try WorkerFraming.writeRequest(request, to: self.output)
              return try WorkerFraming.readDetailedResponse(
                from: self.input, requestID: request.id)
            } catch let error as WorkerClientError {
              throw error
            } catch {
              throw WorkerClientError.protocolFailure
            }
          }.value
        }
        group.addTask { () -> (pcm: Data, timingsJSON: Data?) in
          try await Task.sleep(for: timeout)
          throw WorkerClientError.timeout
        }

        do {
          guard let first = try await group.next() else {
            throw WorkerClientError.protocolFailure
          }
          group.cancelAll()
          return first
        } catch {
          // A worker that reported a clean per-request failure is alive
          // with its model warm — killing it would also desynchronize the
          // pool, which releases it as healthy. Kill only when the error
          // class actually requires replacement.
          if (error as? WorkerClientError)?.requiresReplacement != false {
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

  var isRunning: Bool {
    processLock.lock()
    defer { processLock.unlock() }
    return process.isRunning
  }

  func terminateHard() {
    processLock.lock()
    defer { processLock.unlock() }
    guard process.isRunning else { return }
    _ = Darwin.kill(process.processIdentifier, SIGKILL)
    try? output.close()
    try? input.close()
  }
}

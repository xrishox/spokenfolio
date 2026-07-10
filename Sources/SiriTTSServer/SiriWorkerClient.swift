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

final class SiriWorkerClient: @unchecked Sendable {
  let voiceID: String

  private let process: Process
  private let input: FileHandle
  private let output: FileHandle
  private let processLock = NSLock()

  init(voiceID: String) throws {
    self.voiceID = voiceID
    guard
      let executable = Bundle.main.executableURL
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

  func synthesize(text: String, timeout: Duration) async throws -> Data {
    let request = WorkerRequest(id: UUID(), text: text)
    return try await withTaskCancellationHandler {
      try await withThrowingTaskGroup(of: Data.self) { group in
        group.addTask {
          try await Task.detached(priority: .userInitiated) {
            guard self.isRunning else { throw WorkerClientError.notRunning }
            do {
              try WorkerFraming.writeRequest(request, to: self.output)
              return try WorkerFraming.readResponse(from: self.input, requestID: request.id)
            } catch let error as WorkerClientError {
              throw error
            } catch {
              throw WorkerClientError.protocolFailure
            }
          }.value
        }
        group.addTask {
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
          terminateHard()
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

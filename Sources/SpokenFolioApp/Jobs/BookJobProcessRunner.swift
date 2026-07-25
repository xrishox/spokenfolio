import BookJobKit
import Darwin
import Foundation

final class BookJobProcessRunner: @unchecked Sendable {
  private let executable: URL?
  private let store: BookJobStore
  private let lock = NSLock()
  private var process: Process?
  private var jobID: UUID?

  init(executable: URL? = nil, store: BookJobStore) {
    self.executable = Self.resolveExecutable(
      override: executable, bundleExecutable: Bundle.main.executableURL,
      commandPath: CommandLine.arguments.first)
    self.store = store
  }

  static func resolveExecutable(
    override: URL?, bundleExecutable: URL?, commandPath: String? = nil
  ) -> URL? {
    let candidates = [
      override,
      ProcessInfo.processInfo.environment["SPOKENFOLIO_JOB_EXECUTABLE"].map {
        URL(fileURLWithPath: $0)
      },
      bundleExecutable,
      commandPath.map { URL(fileURLWithPath: $0).standardizedFileURL },
    ]
    return candidates.compactMap { $0 }.first
  }

  func run(id: UUID) -> AsyncThrowingStream<BookJobState, Error> {
    AsyncThrowingStream { continuation in
      guard let executable else {
        continuation.finish(throwing: BookJobError.io("application executable is unavailable"))
        return
      }
      let process = Process()
      process.executableURL = executable
      process.arguments = ["jobs", "run", id.uuidString.lowercased()]
      process.standardInput = FileHandle.nullDevice
      process.standardOutput = FileHandle.nullDevice
      let stderr = Pipe()
      process.standardError = stderr
      let stderrTail = BookJobStderrTail(limit: 4_096)
      stderr.fileHandleForReading.readabilityHandler = { handle in
        let data = handle.availableData
        if data.isEmpty { handle.readabilityHandler = nil } else { stderrTail.append(data) }
      }
      lock.withLock {
        self.process = process
        self.jobID = id
      }
      do { try process.run() } catch {
        stderr.fileHandleForReading.readabilityHandler = nil
        lock.withLock {
          self.process = nil
          self.jobID = nil
        }
        continuation.finish(throwing: error)
        return
      }

      let task = Task.detached { [weak self] in
        guard let self else { return }
        var lastRevision: UInt64?
        while !Task.isCancelled && process.isRunning {
          do {
            let state = try await self.store.loadState(id)
            if state.revision != lastRevision {
              lastRevision = state.revision
              continuation.yield(state)
            }
          } catch {
            try? await self.interrupt(.pause)
            process.waitUntilExit()
            stderr.fileHandleForReading.readabilityHandler = nil
            stderrTail.append(stderr.fileHandleForReading.readDataToEndOfFile())
            self.lock.withLock {
              self.process = nil
              self.jobID = nil
            }
            continuation.finish(throwing: error)
            return
          }
          try? await Task.sleep(for: .milliseconds(400))
        }
        guard !Task.isCancelled else { return }
        process.waitUntilExit()
        stderr.fileHandleForReading.readabilityHandler = nil
        stderrTail.append(stderr.fileHandleForReading.readDataToEndOfFile())
        let finalState: Result<BookJobState, Error>
        do { finalState = .success(try await self.store.loadState(id)) } catch {
          finalState = .failure(error)
        }
        if case .success(let state) = finalState { continuation.yield(state) }
        self.lock.withLock {
          self.process = nil
          self.jobID = nil
        }
        if case .failure(let error) = finalState {
          continuation.finish(throwing: error)
        } else if process.terminationStatus == 0 {
          continuation.finish()
        } else {
          let message = String(decoding: stderrTail.snapshot(), as: UTF8.self)
          continuation.finish(
            throwing: BookJobError.io(message.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
      }
      continuation.onTermination = { [weak self] _ in
        task.cancel()
        Task { try? await self?.interrupt(.pause) }
      }
    }
  }

  func cancel() { Task { try? await interrupt(.pause) } }

  /// Persist intent before signaling. This ordering is what distinguishes an
  /// explicit cancellation from a resumable pause when the child handles
  /// SIGINT immediately.
  func interrupt(_ kind: BookJobControl.InterruptionKind) async throws {
    let values = lock.withLock { (process, jobID) }
    if let id = values.1 {
      if let state = try? await store.loadState(id) {
        // A queued child may not have incremented its attempt yet. Target the attempt it is
        // about to start so cancellation cannot be lost in the launch race.
        let attempt = state.lifecycle == .queued ? state.attempt + 1 : state.attempt
        try await store.requestInterruption(id, attempt: attempt, kind: kind)
      }
    }
    guard let process = values.0, process.isRunning else { return }
    process.interrupt()
    // The child gives its own synthesis subprocess up to 15s + 5s to stop
    // and then persists the clean pause; this outer window must be wider
    // than that inner one, or a slow checkpoint gets killed into
    // needs-attention instead of a graceful pause.
    if await Self.waitUntilStopped(process, timeout: .seconds(30)) { return }
    process.terminate()
    if await Self.waitUntilStopped(process, timeout: .seconds(10)) { return }
    _ = Darwin.kill(process.processIdentifier, SIGKILL)
    _ = await Self.waitUntilStopped(process, timeout: .seconds(2))
  }

  private static func waitUntilStopped(_ process: Process, timeout: Duration) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while process.isRunning, clock.now < deadline {
      try? await Task.sleep(for: .milliseconds(100))
    }
    return !process.isRunning
  }
}

private final class BookJobStderrTail: @unchecked Sendable {
  private let lock = NSLock()
  private let limit: Int
  private var data = Data()
  init(limit: Int) { self.limit = limit }
  func append(_ value: Data) {
    guard !value.isEmpty else { return }
    lock.withLock {
      data.append(value)
      if data.count > limit { data.removeFirst(data.count - limit) }
    }
  }
  func snapshot() -> Data { lock.withLock { data } }
}

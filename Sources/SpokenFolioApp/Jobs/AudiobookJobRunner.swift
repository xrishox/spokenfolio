import AudiobookKit
import Darwin
import Foundation

/// Runs an audiobook job by spawning `spokenfolio audiobook create
/// --progress ndjson` and decoding its stdout event stream.
///
/// This is the GUI's whole synthesis backend: the job executes in the same
/// battle-tested process the CLI and smoke tests use, isolated from every
/// AppKit failure mode. Nothing in the GUI process can wedge or kill a
/// running job short of killing the child.
final class AudiobookJobRunner: @unchecked Sendable {
  struct Failure: Error, LocalizedError {
    let exitCode: Int32
    let stderrTail: String

    var errorDescription: String? {
      // The CLI prints one final "error: <message>" line; surface exactly
      // that when present, with the raw tail as fallback.
      let lines = stderrTail.split(separator: "\n")
      if let line = lines.last(where: { $0.hasPrefix("error: ") }) {
        return String(line.dropFirst("error: ".count))
      }
      let tail = stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
      return tail.isEmpty ? "the synthesis process exited with status \(exitCode)" : tail
    }
  }

  private let executableURL: URL?
  private let processLock = NSLock()
  private var process: Process?
  private var killTimer: DispatchSourceTimer?
  private var readerTask: Task<Void, Never>?
  private var stdoutReadHandle: FileHandle?
  private var stderrReadHandle: FileHandle?
  private var cancellationRequested = false

  /// `executable` is injectable so tests can point at a built binary;
  /// the app uses its own executable (which owns the `audiobook` mode).
  init(executable: URL? = nil) {
    executableURL =
      executable
      ?? ProcessInfo.processInfo.environment["SPOKENFOLIO_JOB_EXECUTABLE"]
      .map { URL(fileURLWithPath: $0) }
      ?? Bundle.main.executableURL
  }

  /// Spawns the child and yields its progress events. The stream finishes
  /// normally only for exit 0; exit 130 (SIGINT) surfaces as
  /// `CancellationError`; anything else throws `Failure` carrying the
  /// child's own error text.
  func run(arguments: [String]) -> AsyncThrowingStream<AudiobookProgressEvent, Error> {
    AsyncThrowingStream { continuation in
      guard let executableURL else {
        continuation.finish(throwing: Failure(exitCode: -1, stderrTail: "no executable path"))
        return
      }

      let process = Process()
      process.executableURL = executableURL
      process.arguments = ["audiobook", "create"] + arguments + ["--progress", "ndjson"]
      let stdout = Pipe()
      let stderr = Pipe()
      process.standardOutput = stdout
      process.standardInput = FileHandle.nullDevice
      process.standardError = stderr

      // Bounded stderr tail for failure messages; reading continuously also
      // keeps the child from blocking on a full stderr pipe.
      let stderrTail = BoundedTailBuffer(limit: 4_096)
      stderr.fileHandleForReading.readabilityHandler = { handle in
        let data = handle.availableData
        if data.isEmpty {
          handle.readabilityHandler = nil
        } else {
          stderrTail.append(data)
        }
      }

      do {
        try process.run()
      } catch {
        stderr.fileHandleForReading.readabilityHandler = nil
        continuation.finish(
          throwing: Failure(
            exitCode: -1, stderrTail: "could not start: \(error.localizedDescription)"))
        return
      }
      processLock.withLock {
        self.process = process
        self.stdoutReadHandle = stdout.fileHandleForReading
        self.stderrReadHandle = stderr.fileHandleForReading
        self.cancellationRequested = false
      }

      let reader = Task.detached { [weak self] in
        let decoder = JSONDecoder()
        var sawFinished = false
        func decodeLine(_ data: Data) throws -> AudiobookProgressEvent? {
          guard !data.isEmpty else { return nil }
          guard let wire = try? decoder.decode(ProgressEventWire.self, from: data),
            let event = wire.event()
          else {
            let preview = String(decoding: data.prefix(200), as: UTF8.self)
            throw Failure(exitCode: -1, stderrTail: "unreadable progress event: \(preview)")
          }
          return event
        }
        do {
          // Strict 0x0A framing: AsyncLineSequence also splits on
          // U+2028/U+2029/U+0085, which JSON strings may legally contain.
          var buffer = Data()
          for try await byte in stdout.fileHandleForReading.bytes {
            if byte == UInt8(ascii: "\n") {
              if let event = try decodeLine(buffer) {
                if case .finished = event { sawFinished = true }
                continuation.yield(event)
              }
              buffer.removeAll(keepingCapacity: true)
            } else {
              buffer.append(byte)
              guard buffer.count <= 1 << 20 else {
                throw Failure(
                  exitCode: -1, stderrTail: "progress event exceeded the 1 MiB framing limit")
              }
            }
          }
          if let event = try decodeLine(buffer) {
            if case .finished = event { sawFinished = true }
            continuation.yield(event)
          }
        } catch {
          // Protocol violation or read error: stop the child (SIGINT, with
          // the SIGTERM escalation) and drain its stdout so it can exit —
          // waiting on an undrained pipe would deadlock both processes.
          self?.cancel()
          stdout.fileHandleForReading.readabilityHandler = { handle in
            if handle.availableData.isEmpty { handle.readabilityHandler = nil }
          }
          process.waitUntilExit()
          stdout.fileHandleForReading.readabilityHandler = nil
          stderr.fileHandleForReading.readabilityHandler = nil
          stderrTail.append((try? stderr.fileHandleForReading.readToEnd()) ?? Data())
          self?.clearProcess()
          continuation.finish(throwing: error)
          return
        }

        // Stream ended: the child closed stdout, so it is exiting.
        process.waitUntilExit()
        let wasCancelled = self?.processLock.withLock { self?.cancellationRequested ?? false } ?? false
        self?.clearProcess()
        let status = process.terminationStatus
        let signalDeath = process.terminationReason == .uncaughtSignal
        stderr.fileHandleForReading.readabilityHandler = nil
        stderrTail.append((try? stderr.fileHandleForReading.readToEnd()) ?? Data())
        switch (status, sawFinished) {
        case (0, true):
          continuation.finish()
        case (130, _):
          continuation.finish(throwing: CancellationError())
        // Cancel before the child installs its SIGINT handler (or after the
        // SIGTERM escalation) kills it by signal; that is still the user's
        // cancel, never a failure.
        case (_, _) where signalDeath && wasCancelled:
          continuation.finish(throwing: CancellationError())
        default:
          continuation.finish(
            throwing: Failure(exitCode: status, stderrTail: stderrTail.text()))
        }
      }
      processLock.withLock { readerTask = reader }
      continuation.onTermination = { [weak self] _ in
        // Do not cancel the reader: it owns continuous stdout/stderr draining
        // through child exit. Stopping it here can close the progress pipe
        // while the CLI is writing its final cancellation diagnostic.
        _ = reader
        self?.cancel()
      }
    }
  }

  /// SIGINT: the CLI's proven cancel path — completed chapters stay durable
  /// and the child exits 130 on its own. Escalates to SIGTERM if the child
  /// is still alive after 15 seconds.
  func cancel() {
    processLock.withLock {
      guard let process, process.isRunning else { return }
      cancellationRequested = true
      process.interrupt()
      let stdoutReadHandle = self.stdoutReadHandle
      let stderrReadHandle = self.stderrReadHandle
      // A subprocess of a shell child can inherit the progress pipe even
      // after the direct child exits. Drain through direct-child exit, then
      // release the reader so an inherited descriptor cannot hang
      // cancellation indefinitely.
      DispatchQueue.global().async { [weak self, weak process] in
        guard let self, let process else { return }
        process.waitUntilExit()
        self.processLock.withLock {
          if self.process === process, self.cancellationRequested {
            // Descendants of a shell wrapper may keep inherited descriptors
            // open after the direct child is gone. At that point draining is
            // complete for the process we own, so close both read ends.
            stderrReadHandle?.readabilityHandler = nil
            try? stdoutReadHandle?.close()
            try? stderrReadHandle?.close()
            self.readerTask?.cancel()
          }
        }
      }
      let timer = DispatchSource.makeTimerSource(queue: .global())
      timer.schedule(deadline: .now() + 15)
      timer.setEventHandler { [weak self] in
        self?.processLock.withLock {
          guard let process = self?.process, process.isRunning else { return }
          process.terminate()
          DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [weak self, weak process] in
            guard let self, let process else { return }
            self.processLock.withLock {
              if self.process === process, process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
              }
            }
          }
        }
      }
      timer.resume()
      killTimer = timer
    }
  }

  private func clearProcess() {
    processLock.withLock {
      process = nil
      readerTask = nil
      stdoutReadHandle = nil
      stderrReadHandle = nil
      cancellationRequested = false
      killTimer?.cancel()
      killTimer = nil
    }
  }
}

/// Last-N-bytes ring for the child's stderr.
private final class BoundedTailBuffer: @unchecked Sendable {
  private let lock = NSLock()
  private let limit: Int
  private var data = Data()

  init(limit: Int) {
    self.limit = limit
  }

  func append(_ chunk: Data) {
    lock.withLock {
      data.append(chunk)
      if data.count > limit { data.removeFirst(data.count - limit) }
    }
  }

  func text() -> String {
    lock.withLock { String(decoding: data, as: UTF8.self) }
  }
}

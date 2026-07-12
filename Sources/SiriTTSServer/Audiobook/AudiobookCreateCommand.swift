import ArgumentParser
import AudiobookKit
import Darwin
import Dispatch
import Foundation
import SiriTTSCore

extension AudiobookCommand {
  struct Create: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Synthesize an EPUB into an M4B audiobook with chapters, cover, and metadata.")

    @OptionGroup var book: BookArguments

    @Option(help: "Siri voice: canonical asset ID or an unambiguous name.")
    var voice: String?

    @Option(help: "AAC bitrate in kbps: 32, 64, 128, or 256.")
    var bitrate: Int?

    @Option(help: "Siri worker processes, 1-16 (default: auto for this machine).")
    var workers: Int?

    @Option(
      name: .shortAndLong,
      help: "Output path (default: '<Title> - <Author>.m4b' beside the EPUB).")
    var output: String?

    @Option(name: .customLong("paragraph-pause"), help: "Seconds of silence between paragraphs.")
    var paragraphPause: Double?

    @Option(name: .customLong("chapter-pause"), help: "Seconds of silence after each chapter.")
    var chapterPause: Double?

    @Option(name: .customLong("work-dir"), help: "Directory for resumable chapter artifacts.")
    var workDir: String?

    @Flag(name: .customLong("keep-work"), help: "Keep chapter artifacts after success.")
    var keepWork = false

    @Flag(help: "Discard previous progress and start over.")
    var force = false

    @Flag(help: "Replace an existing output file.")
    var overwrite = false

    @Flag(name: .shortAndLong, help: "Only report errors.")
    var quiet = false

    @Option(
      name: .customLong("progress"),
      help: "Progress output: human (stderr, default) or ndjson (one JSON event per line on stdout).")
    var progressFormat: ProgressFormat = .human

    func run() async throws {
      let config = try loadConfig()
      let plan = try book.plan(config: config)

      try preflight()
      let asset = try resolveVoice(config: config)

      let bitrateKbps = bitrate ?? config.defaultBitrateKbps
      guard AudiobookConfig.allowedBitratesKbps.contains(bitrateKbps) else {
        throw ValidationError(
          "--bitrate must be one of "
            + AudiobookConfig.allowedBitratesKbps.map(String.init).joined(separator: ", "))
      }
      let workerCount = workers ?? config.resolvedMaxWorkers
      guard (1...16).contains(workerCount) else {
        throw ValidationError("--workers must be between 1 and 16")
      }
      let paragraphPauseSeconds = paragraphPause ?? config.paragraphPauseSeconds
      let chapterPauseSeconds = chapterPause ?? config.chapterPauseSeconds
      guard (0...10).contains(paragraphPauseSeconds), (0...10).contains(chapterPauseSeconds)
      else {
        throw ValidationError("pauses must be between 0 and 10 seconds")
      }

      let outputURL = try resolveOutputURL(plan: plan)

      let epubURL = URL(fileURLWithPath: (book.epub as NSString).expandingTildeInPath)
      let inputs = AudiobookJobInputs(
        epubSHA256: try AudiobookJobInputs.hashEPUB(at: epubURL),
        voiceID: asset.id,
        voiceVersion: asset.version,
        bitRate: bitrateKbps * 1_000,
        includedSections: plan.sections.filter(\.included).map { "\($0.spineIndex):\($0.slug)" },
        paragraphPauseMs: Int(paragraphPauseSeconds * 1_000),
        chapterPauseMs: Int(chapterPauseSeconds * 1_000),
        announceTitles: book.effectiveAnnounceTitles(config: config),
        maxChapters: book.maxChapters,
        formatIdentifier: "m4b-aac-v2")
      let workRoot = (workDir ?? config.workDirectory)
        .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
      let job = try AudiobookJob.open(inputs: inputs, workRoot: workRoot, force: force)

      let writer = M4BAudiobookWriter(
        settings: AACEncodingSettings(bitRate: inputs.bitRate),
        fingerprint: inputs.fingerprint,
        overwriteExisting: overwrite)
      // Units are whole paragraphs; the per-request deadline scales with the
      // longest one so a long paragraph is never mistaken for a hung worker.
      let deadline = NarrationUnitPlanner.deadlineSeconds(
        maximumUnitCharacters: plan.maxUnitCharacterCount)
      let pool = SiriWorkerPool(
        maxWorkers: workerCount, maxQueued: 4 * workerCount + 16, deadlineSeconds: deadline)
      defer { Task { await pool.shutdown() } }

      let synthesizer = AudiobookSynthesizer(
        sentences: WorkerPoolSynthesizer(pool: pool),
        writer: writer,
        settings: SynthesisSettings(
          voiceID: asset.id,
          narratorName: asset.displayName,
          maxWorkers: workerCount,
          paragraphPauseSeconds: paragraphPauseSeconds,
          chapterPauseSeconds: chapterPauseSeconds))

      let renderer: any ProgressSink =
        progressFormat == .ndjson
        ? NDJSONProgressWriter()
        : ProgressRenderer(plan: plan, quiet: quiet)
      // Cancelling the consuming task ends the stream with nil, NOT with
      // CancellationError, so success must be proven by the .finished event —
      // never inferred from the loop ending.
      let runTask = Task { () -> Bool in
        var finished = false
        for try await event in synthesizer.run(plan: plan, job: job, outputURL: outputURL) {
          if case .finished = event { finished = true }
          renderer.render(event)
        }
        return finished
      }

      // Ctrl-C cancels the run; completed chapters stay durable.
      signal(SIGINT, SIG_IGN)
      let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
      sigint.setEventHandler { runTask.cancel() }
      sigint.resume()
      defer { sigint.cancel() }

      do {
        let finished = try await runTask.value
        guard finished else { throw CancellationError() }
      } catch is CancellationError {
        renderer.finishLine()
        await pool.shutdown()
        throw CLIFailure(
          message:
            "interrupted — completed chapters are saved; re-run the same command to resume",
          exitCode: 130)
      } catch let error as AudiobookRunError {
        renderer.finishLine()
        await pool.shutdown()
        throw CLIFailure(message: error.localizedDescription, exitCode: 69 /* EX_UNAVAILABLE */)
      } catch let error as AudiobookAudioError {
        renderer.finishLine()
        await pool.shutdown()
        throw CLIFailure(message: error.localizedDescription, exitCode: 73 /* EX_CANTCREAT */)
      }

      if !keepWork { job.removeWorkDirectory() }
      await pool.shutdown()
      // In ndjson mode stdout carries only events; the .finished event
      // already delivered the output path.
      if !quiet, progressFormat == .human { print("Created \(outputURL.path)") }
    }

    private func loadConfig() throws -> AudiobookConfig {
      do {
        return try AudiobookConfig.load()
      } catch {
        throw CLIFailure(
          message: "invalid audiobook configuration: \(error.localizedDescription)",
          exitCode: 78 /* EX_CONFIG */)
      }
    }

    /// Doctor-equivalent checks before any synthesis work.
    private func preflight() throws {
      do {
        try SiriPermissionPreflight.verifyModelAccess()
      } catch {
        throw CLIFailure(
          message:
            "Full Disk Access is required to read Apple's installed Siri models "
            + "(run 'siri-tts-server doctor' for details)",
          exitCode: 69)
      }
    }

    private func resolveVoice(config: AudiobookConfig) throws -> SiriVoiceAsset {
      let assets = SiriVoiceCatalog.discover()
      guard !assets.isEmpty else {
        throw CLIFailure(
          message:
            "no compatible Siri voices installed — download one in System Settings and run "
            + "'siri-tts-server doctor'",
          exitCode: 69)
      }
      let requested = voice ?? config.defaultVoice ?? (try? ServerConfig.load())?.defaultVoice
      guard let requested else {
        return SiriVoiceCatalog.preferred(assets)!
      }
      let lookup = SiriVoiceCatalog.makeVoiceLookup(assets)
      guard let canonical = lookup[requested.lowercased()],
        let asset = assets.first(where: { $0.id == canonical })
      else {
        let matches = assets.filter { $0.name == requested.lowercased() }
        let hint = matches.isEmpty
          ? "run 'siri-tts-server audiobook voices' to list voices"
          : "did you mean: " + matches.map(\.displayName).joined(separator: ", ") + "?"
        throw CLIFailure(
          message: "voice '\(requested)' is not installed or is ambiguous — \(hint)",
          exitCode: 69)
      }
      return asset
    }

    private func resolveOutputURL(plan: AudiobookPlan) throws -> URL {
      let url: URL
      if let output {
        url = URL(fileURLWithPath: (output as NSString).expandingTildeInPath)
      } else {
        let epubURL = URL(fileURLWithPath: (book.epub as NSString).expandingTildeInPath)
        let author = plan.metadata.author.map { " - \($0)" } ?? ""
        let name = sanitizeFilename("\(plan.metadata.title)\(author)") + ".m4b"
        url = epubURL.deletingLastPathComponent().appendingPathComponent(name)
      }
      if FileManager.default.fileExists(atPath: url.path), !overwrite {
        throw CLIFailure(
          message: "'\(url.path)' already exists — pass --overwrite to replace it",
          exitCode: 73)
      }
      return url
    }
  }

  // MARK: - verify

  struct Verify: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Read an audiobook file back and print its metadata and chapters.")

    @Argument(help: "Path to an .m4b file.", completion: .file(extensions: ["m4b", "m4a"]))
    var file: String

    @Flag(inversion: .prefixedNo, help: "Decode every audio frame (default: true).")
    var decode = true

    func run() async throws {
      let url = URL(fileURLWithPath: (file as NSString).expandingTildeInPath)
      guard FileManager.default.fileExists(atPath: url.path) else {
        throw CLIFailure(message: "no such file: \(url.path)", exitCode: 66)
      }
      try await AudiobookVerifier.printReport(for: url, decodeAudio: decode)
    }
  }
}

// MARK: - Progress rendering

enum ProgressFormat: String, ExpressibleByArgument, CaseIterable {
  case human
  case ndjson
}

protocol ProgressSink: Sendable {
  func render(_ event: AudiobookProgressEvent)
  func finishLine()
}

/// `--progress ndjson`: one JSON object per event on stdout, written
/// line-atomically. Everything human-readable stays on stderr, so a parent
/// process can decode stdout unconditionally.
final class NDJSONProgressWriter: ProgressSink, @unchecked Sendable {
  private let lock = NSLock()
  private let output: FileHandle
  private let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }()
  private var outputAvailable = true

  init(output: FileHandle = .standardOutput) {
    self.output = output
  }

  func render(_ event: AudiobookProgressEvent) {
    lock.withLock {
      guard outputAvailable else { return }
      guard var data = try? encoder.encode(ProgressEventWire(event)) else { return }
      data = Self.escapingUnicodeLineBreaks(data)
      data.append(UInt8(ascii: "\n"))
      do {
        try output.write(contentsOf: data)
      } catch {
        // A GUI crash closes stdout. Progress is optional; synthesis must
        // continue so the isolated child can finish or leave resumable work.
        outputAvailable = false
      }
    }
  }

  func finishLine() {}

  /// JSONEncoder leaves U+2028/U+2029/U+0085 as raw UTF-8 even though
  /// line-oriented readers treat them as breaks. Escaping byte-wise is safe:
  /// UTF-8 is self-synchronizing, so these sequences cannot occur inside any
  /// other scalar's encoding.
  static func escapingUnicodeLineBreaks(_ data: Data) -> Data {
    let replacements: [(sequence: [UInt8], escape: [UInt8])] = [
      ([0xE2, 0x80, 0xA8], Array("\\u2028".utf8)),
      ([0xE2, 0x80, 0xA9], Array("\\u2029".utf8)),
      ([0xC2, 0x85], Array("\\u0085".utf8)),
    ]
    guard replacements.contains(where: { data.range(of: Data($0.sequence)) != nil }) else {
      return data
    }
    var result = Data(capacity: data.count + 16)
    var index = data.startIndex
    outer: while index < data.endIndex {
      for (sequence, escape) in replacements {
        if data.count - data.distance(from: data.startIndex, to: index) >= sequence.count,
          data[index..<data.index(index, offsetBy: sequence.count)].elementsEqual(sequence)
        {
          result.append(contentsOf: escape)
          index = data.index(index, offsetBy: sequence.count)
          continue outer
        }
      }
      result.append(data[index])
      index = data.index(after: index)
    }
    return result
  }
}

/// One-line TTY progress bar, or one line per event when piped/quiet.
final class ProgressRenderer: ProgressSink, @unchecked Sendable {
  private let lock = NSLock()
  private let quiet: Bool
  private let isTTY = isatty(STDERR_FILENO) == 1
  private let totalCharacters: Int
  private let chapterCharacters: [Int]
  private let startedAt = Date()
  private var completedCharacters = 0
  private var currentChapterUnitsDone = 0
  private var currentChapterUnitsTotal = 0
  private var currentChapterIndex = 0
  private var wroteBar = false

  init(plan: AudiobookPlan, quiet: Bool) {
    self.quiet = quiet
    chapterCharacters = plan.chapters.map(\.characterCount)
    totalCharacters = plan.totalCharacterCount
  }

  func render(_ event: AudiobookProgressEvent) {
    guard !quiet else { return }
    lock.withLock {
      switch event {
      case .started(let chapters, _, let reused, _):
        line("Synthesizing \(chapters) chapters (\(reused) already complete)")
      case .chapterStarted(let index, let title):
        currentChapterIndex = index
        currentChapterUnitsDone = 0
        currentChapterUnitsTotal = 0
        if !isTTY { line("chapter \(index + 1): \(title)") }
      case .unitCompleted(let index, let done, let total):
        currentChapterIndex = index
        currentChapterUnitsDone = done
        currentChapterUnitsTotal = total
        drawBar()
      case .chapterCompleted(let index, let title, let reused):
        completedCharacters += chapterCharacters.indices.contains(index)
          ? chapterCharacters[index] : 0
        currentChapterUnitsDone = 0
        currentChapterUnitsTotal = 0
        if !isTTY || reused {
          line("chapter \(index + 1) \(reused ? "reused" : "done"): \(title)")
        } else {
          drawBar()
        }
      case .assemblyStarted:
        line("Assembling audiobook…")
      case .finished:
        break
      case .warning(let message):
        line("warning: \(message)")
      }
    }
  }

  private func drawBar() {
    guard isTTY else { return }
    var done = Double(completedCharacters)
    if currentChapterUnitsTotal > 0, chapterCharacters.indices.contains(currentChapterIndex) {
      done += Double(chapterCharacters[currentChapterIndex])
        * Double(currentChapterUnitsDone) / Double(currentChapterUnitsTotal)
    }
    let fraction = totalCharacters > 0 ? min(1, done / Double(totalCharacters)) : 0
    let elapsed = Date().timeIntervalSince(startedAt)
    let eta = fraction > 0.01 ? elapsed / fraction - elapsed : .nan
    let barWidth = 24
    let filled = Int(fraction * Double(barWidth))
    let bar = String(repeating: "█", count: filled)
      + String(repeating: "░", count: barWidth - filled)
    let text = String(
      format: "\rChapter %d/%d %@ %3.0f%% | elapsed %@ | ETA %@   ",
      currentChapterIndex + 1, chapterCharacters.count, bar, fraction * 100,
      Self.clock(elapsed), eta.isNaN ? "--:--" : Self.clock(eta))
    FileHandle.standardError.write(Data(text.utf8))
    wroteBar = true
  }

  /// Callable from outside `render` only — `line`/`drawBar` already run
  /// inside the lock, and NSLock does not recurse.
  func finishLine() {
    lock.withLock {
      if wroteBar {
        FileHandle.standardError.write(Data("\n".utf8))
        wroteBar = false
      }
    }
  }

  private func line(_ text: String) {
    if wroteBar {
      FileHandle.standardError.write(Data("\n".utf8))
      wroteBar = false
    }
    FileHandle.standardError.write(Data((text + "\n").utf8))
  }

  private static func clock(_ interval: TimeInterval) -> String {
    let seconds = max(0, Int(interval))
    if seconds >= 3_600 {
      return String(format: "%d:%02d:%02d", seconds / 3_600, (seconds / 60) % 60, seconds % 60)
    }
    return String(format: "%02d:%02d", seconds / 60, seconds % 60)
  }
}

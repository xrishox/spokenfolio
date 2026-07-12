import ArgumentParser
import AudiobookKit
import Darwin
import Dispatch
import Foundation
import SiriTTSCore
import TTSKit

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
      let appConfig = try loadConfig()
      let config = appConfig.audiobook
      let plan = try book.plan(config: config)

      try preflight()
      let selection = try resolveVoice(
        config: config, serverDefault: appConfig.server.defaultVoice)
      let backend = selection.backend
      let selectedVoice = selection.voice

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
        sourceSHA256: try AudiobookJobInputs.hashSource(at: epubURL),
        sourceFormat: plan.sourceFormat,
        importerVersion: plan.importerVersion,
        backendID: SiriTTSBackend.backendID.rawValue,
        modelID: SiriTTSBackend.modelID,
        modelRevision: selectedVoice.modelRevision,
        voiceID: selectedVoice.key.voiceID,
        voiceRevision: selectedVoice.voiceRevision,
        bitRate: bitrateKbps * 1_000,
        includedSections: plan.sections.filter(\.included).map { "\($0.id):\($0.slug)" },
        paragraphPauseMs: Int(paragraphPauseSeconds * 1_000),
        chapterPauseMs: Int(chapterPauseSeconds * 1_000),
        announceTitles: book.effectiveAnnounceTitles(config: config),
        maxChapters: book.maxChapters,
        formatIdentifier: "m4b-aac-v2")
      let workRoot = (workDir ?? config.workDirectory)
        .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
        ?? AppPaths.audiobookWorkRoot
      let job = try AudiobookJob.open(inputs: inputs, workRoot: workRoot, force: force)

      let writer = M4BAudiobookWriter(
        settings: AACEncodingSettings(bitRate: inputs.bitRate),
        fingerprint: inputs.fingerprint,
        overwriteExisting: overwrite)
      // Units are whole paragraphs; the per-request deadline scales with the
      // longest one so a long paragraph is never mistaken for a hung worker.
      let deadline = NarrationUnitPlanner.deadlineSeconds(
        maximumUnitCharacters: plan.maxUnitCharacterCount)
      let session = try backend.makeSession(
        configuration: TTSWorkloadConfiguration(
          purpose: .audiobook,
          maxConcurrency: workerCount,
          maxQueuedRequests: 4 * workerCount + 16,
          deadlineSeconds: deadline))
      try await session.prepare(voice: selectedVoice.key)
      defer { Task { await session.shutdown() } }

      let synthesizer = AudiobookSynthesizer(
        sentences: SiriNarrationSynthesizer(session: session, voice: selectedVoice.key),
        writer: writer,
        settings: SynthesisSettings(
          narratorName: selectedVoice.name,
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
        await session.shutdown()
        throw CLIFailure(
          message:
            "interrupted — completed chapters are saved; re-run the same command to resume",
          exitCode: 130)
      } catch let error as AudiobookRunError {
        renderer.finishLine()
        await session.shutdown()
        throw CLIFailure(message: error.localizedDescription, exitCode: 69 /* EX_UNAVAILABLE */)
      } catch let error as AudiobookAudioError {
        renderer.finishLine()
        await session.shutdown()
        throw CLIFailure(message: error.localizedDescription, exitCode: 73 /* EX_CANTCREAT */)
      }

      if !keepWork { job.removeWorkDirectory() }
      await session.shutdown()
      // In ndjson mode stdout carries only events; the .finished event
      // already delivered the output path.
      if !quiet, progressFormat == .human { print("Created \(outputURL.path)") }
    }

    private func loadConfig() throws -> AppConfig {
      do {
        return try AppConfig.load()
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

    private func resolveVoice(
      config: AudiobookConfig, serverDefault: String?
    ) throws -> (backend: SiriTTSBackend, voice: VoiceDescriptor) {
      let backend: SiriTTSBackend
      do {
        backend = try SiriTTSBackend()
      } catch {
        throw CLIFailure(
          message:
            "no compatible Siri voices installed — download one in System Settings and run "
            + "'siri-tts-server doctor'",
          exitCode: 69)
      }
      let requested = voice ?? config.defaultVoice ?? serverDefault
      guard let requested else {
        let selected = backend.voices.first { $0.key == backend.defaultVoice }!
        return (backend, selected)
      }
      guard let key = backend.resolveVoice(requested),
        let selected = backend.voices.first(where: { $0.key == key })
      else {
        throw CLIFailure(
          message:
            "voice '\(requested)' is not installed or is ambiguous — run "
            + "'siri-tts-server audiobook voices' to list voices",
          exitCode: 69)
      }
      return (backend, selected)
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

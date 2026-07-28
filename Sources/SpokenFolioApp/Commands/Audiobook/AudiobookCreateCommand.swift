import ArgumentParser
import AudiobookKit
import Darwin
import Dispatch
import Foundation
import GoldenGateTTSCore
import SiriTTSCore
import TTSKit

extension AudiobookCommand {
  struct Create: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Synthesize an EPUB into an M4B audiobook with chapters, cover, and metadata.")

    @OptionGroup var book: BookArguments

    @Option(help: "TTS backend: siri or siri-fm (default: inferred from model).")
    var backend: String?

    @Option(help: "TTS model: siri-private or siri-expressive (default: siri-private).")
    var model: String?

    @Option(help: "Voice: canonical ID or an unambiguous name.")
    var voice: String?

    @Option(help: "Expressive pace preset, 1-5 (default: 3).")
    var pace: Int?

    @Option(help: "Expressivity preset, 1-5 (default: 3).")
    var expressivity: Int?

    @Option(help: "AAC bitrate in kbps: 32, 64, 128, or 256.")
    var bitrate: Int?

    @Option(
      help:
        "Siri worker processes, 1-8 (default: auto; Siri Expressive production is fixed at 1).")
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

    @Flag(
      name: .customLong("emit-timeline"), inversion: .prefixedNo,
      help:
        "Write the digest-bound synthesis timeline sidecar next to the M4B (default: on; ReadAloud exact alignment requires it).")
    var emitTimeline = true

    @Flag(help: "Discard previous progress and start over.")
    var force = false

    @Flag(help: "Replace an existing output file.")
    var overwrite = false

    @Option(
      name: .customLong("replace-existing-sha256"),
      help: "Replace only if the existing output still has this SHA-256 digest.")
    var replaceExistingSHA256: String?

    @Flag(name: .shortAndLong, help: "Only report errors.")
    var quiet = false

    @Option(
      name: .customLong("progress"),
      help: "Progress output: human (stderr, default) or ndjson (one JSON event per line on stdout).")
    var progressFormat: ProgressFormat = .human

    func run() async throws {
      let appConfig = try loadConfig()
      let config = appConfig.audiobook
      let epubURL = URL(fileURLWithPath: (book.epub as NSString).expandingTildeInPath)
      let sourceHashBeforeImport = try AudiobookJobInputs.hashSource(at: epubURL)
      let plan = try book.plan(config: config)
      let sourceHashAfterImport = try AudiobookJobInputs.hashSource(at: epubURL)
      guard sourceHashBeforeImport == sourceHashAfterImport else {
        throw CLIFailure(
          message: "the EPUB changed while it was being imported; retry with a stable source file",
          exitCode: 74)
      }

      let resolved = try resolveSelection(
        config: config, serverConfig: appConfig.server)
      try preflight(backendID: resolved.selection.voice.backendID)
      let selectedBackend = resolved.backend
      let selectedVoice = resolved.voice
      let ttsSelection = resolved.selection

      let bitrateKbps = bitrate ?? config.defaultBitrateKbps
      guard AudiobookConfig.allowedBitratesKbps.contains(bitrateKbps) else {
        throw ValidationError(
          "--bitrate must be one of "
            + AudiobookConfig.allowedBitratesKbps.map(String.init).joined(separator: ", "))
      }
      let selectedModel = selectedBackend.models.first {
        $0.key.backendID == ttsSelection.voice.backendID
          && $0.key.modelID == ttsSelection.voice.modelID
      }
      let requestedWorkerCount = config.resolvedMaxWorkers(
        explicit: workers, recommended: selectedModel?.recommendedAudiobookWorkers)
      guard (1...AudiobookConfig.maximumWorkers).contains(requestedWorkerCount) else {
        throw ValidationError("--workers must be between 1 and \(AudiobookConfig.maximumWorkers)")
      }
      let workerCount = min(
        requestedWorkerCount,
        selectedModel?.maximumAudiobookWorkers ?? AudiobookConfig.maximumWorkers)
      let workerWarning =
        requestedWorkerCount == workerCount
        ? nil
        : "siri-expressive supports one production audiobook worker; "
          + "the requested \(requestedWorkerCount)-worker setting was reduced to \(workerCount)"
      let paragraphPauseSeconds = paragraphPause ?? config.paragraphPauseSeconds
      let chapterPauseSeconds = chapterPause ?? config.chapterPauseSeconds
      guard (0...10).contains(paragraphPauseSeconds), (0...10).contains(chapterPauseSeconds)
      else {
        throw ValidationError("pauses must be between 0 and 10 seconds")
      }

      let outputURL = try resolveOutputURL(plan: plan)
      if let expected = replaceExistingSHA256 {
        guard overwrite, expected.count == 64, expected == expected.lowercased(),
          expected.allSatisfy(\.isHexDigit)
        else {
          throw ValidationError(
            "--replace-existing-sha256 requires --overwrite and a SHA-256 digest")
        }
      }

      // Units are whole paragraphs; the per-request deadline scales with the
      // longest one so a long paragraph is never mistaken for a hung worker.
      let deadline = NarrationUnitPlanner.deadlineSeconds(
        maximumUnitCharacters: plan.maxUnitCharacterCount)
      let session = try selectedBackend.makeSession(
        configuration: TTSWorkloadConfiguration(
          purpose: .audiobook,
          maxConcurrency: workerCount,
          maxQueuedRequests: 4 * workerCount + 16,
          deadlineSeconds: deadline))
      defer { Task { await session.shutdown() } }
      let runtimeProvenance = try await session.prepare(selection: ttsSelection)

      let inputs = AudiobookJobInputs(
        sourceSHA256: sourceHashAfterImport,
        sourceFormat: plan.sourceFormat,
        importerVersion: plan.importerVersion,
        backendID: ttsSelection.voice.backendID.rawValue,
        modelID: ttsSelection.voice.modelID,
        modelRevision: selectedVoice.modelRevision,
        voiceID: selectedVoice.key.voiceID,
        voiceRevision: selectedVoice.voiceRevision,
        runtimeProvenance: runtimeProvenance,
        pacePreset: ttsSelection.controls.pace?.rawValue,
        expressivityPreset: ttsSelection.controls.expressivity?.rawValue,
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
        overwriteExisting: overwrite, expectedExistingSHA256: replaceExistingSHA256)
      let synthesizer = AudiobookSynthesizer(
        sentences: SessionNarrationSynthesizer(
          session: session, selection: ttsSelection,
          expectedProvenance: runtimeProvenance),
        writer: writer,
        settings: SynthesisSettings(
          narratorName: selectedVoice.name,
          maxWorkers: workerCount,
          paragraphPauseSeconds: paragraphPauseSeconds,
          chapterPauseSeconds: chapterPauseSeconds,
          emitTimeline: emitTimeline))

      let renderer: any ProgressSink =
        progressFormat == .ndjson
        ? NDJSONProgressWriter()
        : ProgressRenderer(plan: plan, quiet: quiet)
      if let workerWarning { renderer.render(.warning(workerWarning)) }
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
    private func preflight(backendID: TTSBackendID) throws {
      guard backendID == SiriTTSBackend.backendID else { return }
      do {
        try SiriPermissionPreflight.verifyModelAccess()
      } catch {
        throw CLIFailure(
          message:
            "Full Disk Access is required to read Apple's installed Siri models "
            + "(run 'spokenfolio doctor' for details)",
          exitCode: 69)
      }
    }

    private func resolveSelection(
      config: AudiobookConfig, serverConfig: ServerConfig
    ) throws -> (
      backend: any TTSBackendFactory, voice: VoiceDescriptor,
      selection: TTSVoiceSelection
    ) {
      let composition: LocalTTSComposition
      do { composition = try LocalTTSComposition.live() } catch {
        throw CLIFailure(
          message: "no compatible local TTS backend is available: \(error.localizedDescription)",
          exitCode: 69)
      }
      let resolver = TTSSelectionResolver(composition: composition)
      let configured: TTSSelectionResolver.Resolved
      do {
        configured = try resolver.configuredDefault(
          configuredVoice: config.defaultVoice ?? serverConfig.defaultVoice,
          configuredDefault: serverConfig.defaultTTS)
      } catch {
        throw CLIFailure(message: error.localizedDescription, exitCode: 78)
      }

      let selectedPublicModelID: String
      if let requestedModel = model {
        if composition.publicModel(requestedModel) != nil {
          selectedPublicModelID = requestedModel
        } else {
          let candidates = composition.registry.models.filter { descriptor in
            descriptor.key.modelID == requestedModel
              && (backend == nil || descriptor.key.backendID.rawValue == backend)
          }
          guard candidates.count == 1, let descriptor = candidates.first,
            let publicID = composition.primaryPublicModelID(for: descriptor.key)
          else { throw ValidationError("--model does not identify one available TTS model") }
          selectedPublicModelID = publicID
        }
      } else if let backend {
        let candidates = composition.registry.models.filter {
          $0.key.backendID.rawValue == backend
        }
        guard candidates.count == 1, let descriptor = candidates.first,
          let publicID = composition.primaryPublicModelID(for: descriptor.key)
        else { throw ValidationError("--backend does not identify one available TTS model") }
        selectedPublicModelID = publicID
      } else {
        selectedPublicModelID = configured.publicModelID
      }

      guard let selectedModel = composition.publicModel(selectedPublicModelID),
        backend == nil || selectedModel.key.backendID.rawValue == backend
      else { throw ValidationError("--backend and --model select different TTS engines") }

      let resolved: TTSSelectionResolver.Resolved
      do {
        resolved = try resolver.publicSelection(
          model: selectedPublicModelID, voice: voice, pace: pace,
          expressivity: expressivity, configuredDefault: configured.selection)
      } catch TTSSelectionResolverError.unsupportedControls {
        throw ValidationError("--pace and --expressivity require a model that supports them")
      } catch TTSSelectionResolverError.invalidControls {
        throw ValidationError("--pace and --expressivity must be between 1 and 5")
      } catch {
        throw CLIFailure(message: error.localizedDescription, exitCode: 69)
      }
      guard let selectedBackend = composition.factory(resolved.selection.voice.backendID) else {
        throw CLIFailure(message: "the selected TTS backend disappeared", exitCode: 69)
      }
      return (selectedBackend, resolved.voice, resolved.selection)
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

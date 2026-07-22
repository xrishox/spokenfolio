import CryptoKit
import Darwin
import Foundation

package protocol ReadAloudBackend: Sendable {
  func create(
    request: ReadAloudRequest,
    progress: @escaping @Sendable (ReadAloudProgress) -> Void
  ) async throws -> ReadAloudVerificationReport
}

package final class StalignReadAloudBackend: ReadAloudBackend, @unchecked Sendable {
  private let tools: ReadAloudToolchain
  private let runner: ExternalProcessRunner

  package init(tools: ReadAloudToolchain, runner: ExternalProcessRunner = .init()) {
    self.tools = tools
    self.runner = runner
  }

  package func create(
    request: ReadAloudRequest,
    progress: @escaping @Sendable (ReadAloudProgress) -> Void
  ) async throws -> ReadAloudVerificationReport {
    try request.validate()
    let fm = FileManager.default
    guard fm.fileExists(atPath: request.epubPath), fm.fileExists(atPath: request.audiobookPath)
    else {
      throw ReadAloudError.invalidRequest("EPUB or audiobook input does not exist")
    }
    let output = URL(fileURLWithPath: request.outputPath)
    if fm.fileExists(atPath: output.path), !request.overwrite {
      throw ReadAloudError.outputExists(output.path)
    }
    let work = URL(fileURLWithPath: request.workDirectory, isDirectory: true)
    try fm.createDirectory(at: work, withIntermediateDirectories: true)
    let input = work.appendingPathComponent("input", isDirectory: true)
    let processed = work.appendingPathComponent("processed", isDirectory: true)
    let transcriptions = work.appendingPathComponent("transcriptions", isDirectory: true)
    let markedup = work.appendingPathComponent("markedup.epub")
    let staged = work.appendingPathComponent("output.partial.epub")
    let report = work.appendingPathComponent("alignment-report.json")
    let manifestURL = work.appendingPathComponent("readaloud-manifest.json")
    let expectedEPUBHash = try ReadAloudTools.sha256(URL(fileURLWithPath: request.epubPath))
    let expectedAudioHash = try ReadAloudTools.sha256(URL(fileURLWithPath: request.audiobookPath))
    // stalign splits processed tracks over 120 minutes by default. The
    // synthesis transcriber maps sidecar chapters onto tracks 1:1, so
    // synthesis runs forbid re-chunking; ASR engines keep the default and
    // their cached processed audio stays valid (fingerprint unchanged).
    let processMaxLengthMinutes: Int? =
      request.asr.engine == .synthesis ? 100_000 : nil
    let processingFingerprint = hashStrings(
      [
        "process-v1", expectedAudioHash, String(request.opusBitrateKbps),
        tools.stalignVersion, tools.stalignSHA256,
      ] + (processMaxLengthMinutes.map { ["max-length-\($0)"] } ?? []))
    let markupFingerprint = hashStrings([
      "markup-v1", expectedEPUBHash, request.language, tools.stalignVersion, tools.stalignSHA256,
    ])
    let transcriber = try makeTranscriber(
      request.asr, audiobook: URL(fileURLWithPath: request.audiobookPath))
    let transcriptionFingerprint = hashStrings([
      "transcribe-v1", transcriber.identity, request.language, processingFingerprint,
    ])
    var manifest = try loadManifest(
      manifestURL, request: request, processingFingerprint: processingFingerprint,
      transcriptionFingerprint: transcriptionFingerprint, markupFingerprint: markupFingerprint)

    let environment = try childEnvironment(work: work)
    progress(
      .init(
        stage: .preparing, stageFraction: 0, overallFraction: 0,
        message: "Preparing ReadAloud tools"))
    // External tools consume immutable work copies. This prevents a source
    // replacement during a long alignment run from mixing two input versions.
    try reset(input)
    let stagedAudio = input.appendingPathComponent(
      URL(fileURLWithPath: request.audiobookPath).lastPathComponent)
    let stagedEPUB = work.appendingPathComponent("source.epub")
    try stageInput(
      from: URL(fileURLWithPath: request.audiobookPath), to: stagedAudio,
      expectedSHA256: expectedAudioHash)
    try stageInput(
      from: URL(fileURLWithPath: request.epubPath), to: stagedEPUB,
      expectedSHA256: expectedEPUBHash)

    // Whole-book stage deadlines scale with the source audio length: an
    // 87-hour audiobook cannot fit the default 30-minute deadline (the
    // Bible failed transcoding at exactly 1,800 s), and its markup scales
    // with the same book size.
    let sourceAudioSeconds = try await probeDuration(stagedAudio, environment: environment)
    let wholeBookDeadline = ReadAloudDeadlines.wholeBookStage(
      totalAudioSeconds: sourceAudioSeconds)

    let processedAudioIsValid = try await validateProcessed(processed, environment: environment)
    let existingProcessedIdentity = processedAudioIsValid
      ? try directoryIdentity(processed, extensions: ["mp4"]) : nil
    if !manifest.completed.contains(.processingAudio) || !processedAudioIsValid
      || manifest.processedIdentity != existingProcessedIdentity
    {
      try reset(processed)
      try await runStage(
        .processingAudio,
        arguments: [
          "process", "--parallel", "1", "--codec", "libopus", "--bitrate",
          "\(request.opusBitrateKbps)K",
        ]
          + (processMaxLengthMinutes.map { ["--max-length", String($0)] } ?? [])
          + [
            "--no-progress", "--log-level", "info",
            input.path, processed.path,
          ], environment: environment, base: 0.05, weight: 0.10,
        timeout: wholeBookDeadline, progress: progress)
      guard try await validateProcessed(processed, environment: environment) else {
        throw ReadAloudError.invalidArtifact("stalign produced no Opus audio")
      }
      manifest.completed.insert(.processingAudio)
      manifest.completed.remove(.transcribing)
      manifest.processedIdentity = try directoryIdentity(processed, extensions: ["mp4"])
      manifest.transcriptionArtifactIdentity = nil
      manifest.transcriptionInputIdentity = nil
      try save(manifest, to: manifestURL)
    }

    // Our Apple adapter must respect the audio duration (a violation is our
    // bug); stalign's own Whisper transcripts may overshoot track ends and
    // are accepted the way stalign itself accepts them.
    let enforceDurationCeiling = request.asr.engine != .whisper
    let transcriptionsAreValid = try await validateTranscriptions(
      transcriptions, processed: processed, environment: environment,
      enforceDurationCeiling: enforceDurationCeiling)
    let existingTranscriptionIdentity = transcriptionsAreValid
      ? try directoryIdentity(transcriptions, extensions: ["json"]) : nil
    if !manifest.completed.contains(.transcribing) || !transcriptionsAreValid
      || manifest.transcriptionArtifactIdentity != existingTranscriptionIdentity
      || manifest.transcriptionInputIdentity != manifest.processedIdentity
      || manifest.transcriptionFingerprint != transcriptionFingerprint
    {
      if manifest.transcriptionFingerprint != transcriptionFingerprint
        || manifest.transcriptionInputIdentity != manifest.processedIdentity
        || (manifest.transcriptionArtifactIdentity != nil
          && manifest.transcriptionArtifactIdentity != existingTranscriptionIdentity)
      {
        try reset(transcriptions)
      } else {
        try fm.createDirectory(at: transcriptions, withIntermediateDirectories: true)
      }
      manifest.completed.remove(.transcribing)
      manifest.transcriptionFingerprint = transcriptionFingerprint
      manifest.transcriptionArtifactIdentity = nil
      manifest.transcriptionInputIdentity = manifest.processedIdentity
      try save(manifest, to: manifestURL)
      try await pruneInvalidTranscriptions(
        transcriptions, processed: processed, environment: environment,
        enforceDurationCeiling: enforceDurationCeiling)
      progress(
        .init(
          stage: .transcribing, stageFraction: 0, overallFraction: 0.15,
          message: "Preparing \(request.asr.engine.rawValue) transcription"))
      let totalAudioDuration = try await totalProcessedDuration(
        processed, environment: environment)
      try await transcriber.transcribe(
        .init(
          processedAudio: processed, transcriptions: transcriptions, sourceEPUB: stagedEPUB,
          language: request.language,
          temporaryDirectory: work.appendingPathComponent("tmp/asr", isDirectory: true),
          environment: environment,
          totalAudioDuration: totalAudioDuration,
          sourceAudiobook: URL(fileURLWithPath: request.audiobookPath),
          sourceAudiobookSHA256: expectedAudioHash)
      ) { fraction, message in
        progress(
          .init(
            stage: .transcribing, stageFraction: fraction,
            overallFraction: 0.15 + 0.65 * fraction, message: message))
      }
      guard try await validateTranscriptions(
        transcriptions, processed: processed, environment: environment,
        enforceDurationCeiling: enforceDurationCeiling)
      else {
        throw ReadAloudError.invalidArtifact("stalign produced invalid transcriptions")
      }
      manifest.completed.insert(.transcribing)
      manifest.transcriptionArtifactIdentity = try directoryIdentity(
        transcriptions, extensions: ["json"])
      manifest.transcriptionInputIdentity = manifest.processedIdentity
      try save(manifest, to: manifestURL)
    }

    if !manifest.completed.contains(.markingUp) || !fm.fileExists(atPath: markedup.path)
      || manifest.markupFingerprint != markupFingerprint
    {
      try? fm.removeItem(at: markedup)
      try await runStage(
        .markingUp,
        arguments: [
          "markup", "--granularity", "sentence", "--language", request.language,
          "--no-progress", "--log-level", "info", stagedEPUB.path, markedup.path,
        ], environment: environment, base: 0.80, weight: 0.05,
        timeout: wholeBookDeadline, progress: progress)
      guard fm.fileExists(atPath: markedup.path) else {
        throw ReadAloudError.invalidArtifact("stalign did not produce a marked-up EPUB")
      }
      manifest.completed.insert(.markingUp)
      manifest.markupFingerprint = markupFingerprint
      try save(manifest, to: manifestURL)
    }

    let paired = work.appendingPathComponent("paired-alignment", isDirectory: true)
    try preparePairedAlignmentDirectory(
      paired, processed: processed, transcriptions: transcriptions)
    try? fm.removeItem(at: staged)
    try? fm.removeItem(at: report)
    // With ground-truth narration knowledge, spine documents the audiobook
    // provably never narrates are emptied in the copy stalign searches so
    // they cannot claim false anchors inside real narration, then restored
    // byte-for-byte in the aligned output.
    var alignEPUB = markedup
    var neutralizedTargets: [String] = []
    if request.asr.engine == .synthesis,
      let narrated = SynthesisTimelineTranscriber.narratedDocuments(
        audiobook: URL(fileURLWithPath: request.audiobookPath),
        expectedAudiobookSHA256: expectedAudioHash)
    {
      let targets = try AlignmentSearchNeutralizer.neutralizationTargets(
        markedup: markedup, narratedDocuments: narrated)
      if !targets.isEmpty {
        let neutralized = work.appendingPathComponent("markedup-neutralized.epub")
        try? fm.removeItem(at: neutralized)
        try AlignmentSearchNeutralizer.writeNeutralized(
          markedup: markedup, targets: targets, to: neutralized)
        alignEPUB = neutralized
        neutralizedTargets = targets
        progress(
          .init(
            stage: .aligning, stageFraction: 0, overallFraction: 0.85,
            message:
              "Excluding \(targets.count) never-narrated documents from alignment search"))
      }
    }
    try await runStage(
      .aligning,
      arguments: [
        "align", "--transcriptions", paired.path, "--output", staged.path,
        "--audiobook", paired.path, "--epub", alignEPUB.path, "--reports", report.path,
        "--language", request.language, "--granularity", "sentence",
        "--no-progress", "--log-level", "info",
      ], environment: environment, base: 0.85, weight: 0.10,
      timeout: ReadAloudDeadlines.wholeBookStage(
        totalAudioSeconds: try await totalProcessedDuration(processed, environment: environment)),
      progress: progress)
    guard fm.fileExists(atPath: staged.path), fm.fileExists(atPath: report.path) else {
      throw ReadAloudError.invalidArtifact("stalign did not produce an aligned EPUB and report")
    }
    if !neutralizedTargets.isEmpty {
      try AlignmentSearchNeutralizer.restore(
        targets: neutralizedTargets, markedup: markedup, staged: staged)
    }
    // Isolated repair for narrated documents global search still missed
    // (duplicated-passage books): one alignment run per document against
    // exactly its own tracks, with every other document neutralized, then
    // graft the overlay. The verifier and audit below run on the merged
    // artifact, so a bad graft cannot slip through.
    if request.asr.engine == .synthesis,
      let chapterDocuments = SynthesisTimelineTranscriber.chapterSourceDocuments(
        audiobook: URL(fileURLWithPath: request.audiobookPath),
        expectedAudiobookSHA256: expectedAudioHash)
    {
      let narrated = chapterDocuments.reduce(into: Set<String>()) { $0.formUnion($1) }
      let stems = try fm.contentsOfDirectory(atPath: processed.path)
        .filter { $0.hasSuffix(".mp4") }
        .map { String($0.dropLast(4)) }
        .sorted()
      let spineXHTML = try AlignmentSearchNeutralizer.spinePaths(markedup: markedup)
      for document in try AlignmentRepair.documentsMissingOverlays(
        staged: staged, narratedDocuments: narrated)
      {
        guard
          try AlignmentRepair.wordCount(of: document, markedup: markedup)
            >= AlignmentRepair.materialTokenFloor
        else { continue }
        let tracks = AlignmentRepair.trackStems(
          narrating: document, chapterSourceDocuments: chapterDocuments, stems: stems)
        guard !tracks.isEmpty else { continue }
        progress(
          .init(
            stage: .aligning, stageFraction: 1, overallFraction: 0.95,
            message: "Repairing alignment for \((document as NSString).lastPathComponent)"))
        let stem = (document as NSString).lastPathComponent
          .replacingOccurrences(of: ".xhtml", with: "")
        let repairDir = work.appendingPathComponent("repair-\(stem)", isDirectory: true)
        try reset(repairDir)
        let repairPaired = repairDir.appendingPathComponent("paired", isDirectory: true)
        try fm.createDirectory(at: repairPaired, withIntermediateDirectories: true)
        for track in tracks {
          try fm.copyItem(
            at: processed.appendingPathComponent("\(track).mp4"),
            to: repairPaired.appendingPathComponent("\(track).mp4"))
          try fm.copyItem(
            at: transcriptions.appendingPathComponent("\(track).json"),
            to: repairPaired.appendingPathComponent("\(track).json"))
        }
        let repairEPUB = repairDir.appendingPathComponent("isolated.epub")
        try AlignmentSearchNeutralizer.writeNeutralized(
          markedup: markedup, targets: spineXHTML.filter { $0 != document },
          to: repairEPUB)
        let repairStaged = repairDir.appendingPathComponent("aligned.epub")
        let repairReport = repairDir.appendingPathComponent("report.json")
        try await runStage(
          .aligning,
          arguments: [
            "align", "--transcriptions", repairPaired.path, "--output", repairStaged.path,
            "--audiobook", repairPaired.path, "--epub", repairEPUB.path,
            "--reports", repairReport.path,
            "--language", request.language, "--granularity", "sentence",
            "--no-progress", "--log-level", "info",
          ], environment: environment, base: 0.95, weight: 0.0,
          timeout: wholeBookDeadline, progress: progress)
        guard fm.fileExists(atPath: repairStaged.path) else {
          throw ReadAloudError.invalidArtifact(
            "repair alignment produced no output for \(document)")
        }
        try AlignmentRepair.graft(document: document, from: repairStaged, into: staged)
      }
    }

    progress(
      .init(
        stage: .verifying, stageFraction: 0, overallFraction: 0.95,
        message: "Verifying embedded Media Overlays"))
    let verification = try await ReadAloudVerifier.verifyPublished(
      epub: staged, ffprobe: tools.ffprobe, environment: environment)
    let quality = try await verifyQuality(
      epub: staged, sourceEPUB: stagedEPUB, transcriptions: transcriptions,
      workDirectory: work.appendingPathComponent("quality-audit", isDirectory: true)
    ) { value in
      progress(
        .init(
          stage: .verifying, stageFraction: value.fraction,
          overallFraction: 0.95 + value.fraction * 0.04,
          message: value.message))
    }
    let qualityData = try JSONEncoder().encode(quality)
    try qualityData.write(
      to: work.appendingPathComponent("quality-report.json"), options: .atomic)
    try Self.requireAcceptableQuality(quality)
    try Task.checkCancellation()
    try fm.createDirectory(
      at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    let publish = output.deletingLastPathComponent().appendingPathComponent(
      ".\(UUID().uuidString).readaloud")
    try? fm.removeItem(at: publish)
    defer { try? fm.removeItem(at: publish) }
    try fm.copyItem(at: staged, to: publish)
    if fm.fileExists(atPath: output.path) {
      guard request.overwrite else { throw ReadAloudError.outputExists(output.path) }
      if let expected = request.expectedExistingSHA256 {
        guard try ReadAloudTools.sha256(output) == expected else {
          throw ReadAloudError.outputChanged(output.path)
        }
      }
      _ = try fm.replaceItemAt(output, withItemAt: publish)
    } else {
      try fm.moveItem(at: publish, to: output)
    }
    progress(
      .init(stage: .verifying, stageFraction: 1, overallFraction: 1, message: "ReadAloud verified"))
    return verification
  }

  package func verifyQuality(
    epub: URL, sourceEPUB: URL, transcriptions: URL, workDirectory: URL,
    progress: @escaping @Sendable (ReadAloudAuditProgress) -> Void = { _ in }
  ) async throws -> ReadAloudAuditReport {
    try await ReadAloudQualityAuditor(runner: runner).audit(
      .init(
        epub: epub, sourceEPUB: sourceEPUB, mode: .standard,
        retainedTranscriptions: transcriptions,
        retainedTranscriptionsAreBound: true,
        workDirectory: workDirectory,
        useFreshASR: false),
      tools: .init(
        stalign: nil, ffmpeg: tools.ffmpeg, ffprobe: tools.ffprobe,
        stalignIdentity: "stalign:\(tools.stalignVersion):\(tools.stalignSHA256)",
        ffmpegIdentity: tools.ffmpeg.path), progress: progress)
  }

  package static func requireAcceptableQuality(_ quality: ReadAloudAuditReport) throws {
    guard quality.verdict != .broken, quality.verdict != .likelyBroken else {
      let reason =
        quality.findings.first(where: {
          $0.verdict == .broken || $0.verdict == .likelyBroken
        })?.summary ?? "ReadAloud quality evidence indicates a fundamental mismatch"
      throw ReadAloudError.invalidArtifact(reason)
    }
  }

  private func runStage(
    _ stage: ReadAloudStage, arguments: [String], environment: [String: String],
    base: Double, weight: Double, timeout: Duration = .seconds(1_800),
    progress: @escaping @Sendable (ReadAloudProgress) -> Void
  ) async throws {
    progress(.init(stage: stage, stageFraction: 0, overallFraction: base, message: stage.rawValue))
    let parser = AdvisoryProgressParser { fraction in
      progress(
        .init(
          stage: stage, stageFraction: fraction, overallFraction: base + weight * fraction,
          message: stage.rawValue))
    }
    let result = try await runner.run(
      executable: tools.stalign, arguments: arguments, environment: environment,
      timeout: timeout, onStderr: { parser.consume($0) })
    try Task.checkCancellation()
    if result.status != 0 {
      throw ReadAloudError.processFailed(
        String(decoding: result.stderr.suffix(4_096), as: UTF8.self))
    }
    progress(
      .init(stage: stage, stageFraction: 1, overallFraction: base + weight, message: stage.rawValue)
    )
  }

  private func childEnvironment(work: URL) throws -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    let home = tools.stalign.deletingLastPathComponent().appendingPathComponent(
      "stalign-home", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    guard chmod(home.path, 0o700) == 0 else {
      throw ReadAloudError.processFailed("could not secure the managed stalign HOME")
    }
    let temporary = work.appendingPathComponent("tmp", isDirectory: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    environment["HOME"] = home.path
    environment["TMPDIR"] = temporary.path
    let toolDirectory = tools.ffmpeg.deletingLastPathComponent().path
    environment["PATH"] = toolDirectory + ":" + (environment["PATH"] ?? "")
    return environment
  }

  private func validateProcessed(
    _ directory: URL, environment: [String: String]
  ) async throws -> Bool {
    guard FileManager.default.fileExists(atPath: directory.path) else { return false }
    let files = try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: [.fileSizeKey]
    )
    .filter { $0.pathExtension.lowercased() == "mp4" }
    guard !files.isEmpty, files.count <= 4_096,
      files.allSatisfy({ ((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0 })
    else { return false }
    for file in files {
      let probe = try await runner.run(
        executable: tools.ffprobe,
        arguments: [
          "-v", "error", "-select_streams", "a:0",
          "-show_entries", "stream=codec_name,sample_rate,channels", "-of", "json", file.path,
        ], environment: environment)
      guard probe.status == 0,
        let object = try? JSONSerialization.jsonObject(with: probe.stdout) as? [String: Any],
        let streams = object["streams"] as? [[String: Any]], let stream = streams.first,
        stream["codec_name"] as? String == "opus",
        String(describing: stream["sample_rate"] ?? "") == "48000",
        (1...2).contains(stream["channels"] as? Int ?? 0)
      else { return false }
    }
    return true
  }

  private func validateTranscriptions(
    _ directory: URL, processed: URL, environment: [String: String],
    enforceDurationCeiling: Bool
  ) async throws -> Bool {
    guard FileManager.default.fileExists(atPath: directory.path) else { return false }
    let audio = try audioFiles(processed)
    let transcripts = try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
      .filter { $0.pathExtension.lowercased() == "json" }
    guard audio.count == transcripts.count,
      Set(audio.map { $0.deletingPathExtension().lastPathComponent })
        == Set(transcripts.map { $0.deletingPathExtension().lastPathComponent })
    else { return false }
    for file in audio {
      let stem = file.deletingPathExtension().lastPathComponent
      let transcriptURL = directory.appendingPathComponent(stem + ".json")
      guard let value = try? StalignTranscriptValidator.decode(transcriptURL),
        let duration = try? await probeDuration(file, environment: environment),
        (try? StalignTranscriptValidator.validate(
          value, audioDuration: duration,
          enforceDurationCeiling: enforceDurationCeiling)) != nil
      else { return false }
    }
    return true
  }

  private func pruneInvalidTranscriptions(
    _ directory: URL, processed: URL, environment: [String: String],
    enforceDurationCeiling: Bool
  ) async throws {
    let audio = try audioFiles(processed)
    let byStem = Dictionary(uniqueKeysWithValues: audio.map {
      ($0.deletingPathExtension().lastPathComponent, $0)
    })
    for transcript in try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil)
    where transcript.pathExtension.lowercased() == "json"
    {
      let stem = transcript.deletingPathExtension().lastPathComponent
      guard let audioURL = byStem[stem],
        let value = try? StalignTranscriptValidator.decode(transcript),
        let duration = try? await probeDuration(audioURL, environment: environment),
        (try? StalignTranscriptValidator.validate(
          value, audioDuration: duration,
          enforceDurationCeiling: enforceDurationCeiling)) != nil
      else {
        try FileManager.default.removeItem(at: transcript)
        continue
      }
    }
  }

  /// Sum of decoded track durations, for workload-scaled stage deadlines.
  private func totalProcessedDuration(
    _ processed: URL, environment: [String: String]
  ) async throws -> Double {
    var total = 0.0
    for file in try audioFiles(processed) {
      total += try await probeDuration(file, environment: environment)
    }
    return total
  }

  private func probeDuration(_ audio: URL, environment: [String: String]) async throws -> Double {
    let probe = try await runner.run(
      executable: tools.ffprobe,
      arguments: [
        "-v", "error", "-select_streams", "a:0", "-show_entries", "stream=duration",
        "-of", "json", audio.path,
      ], environment: environment, timeout: .seconds(60))
    guard probe.status == 0,
      let object = try? JSONSerialization.jsonObject(with: probe.stdout) as? [String: Any],
      let streams = object["streams"] as? [[String: Any]], let stream = streams.first,
      let duration = Double(String(describing: stream["duration"] ?? "")), duration.isFinite,
      duration > 0
    else { throw ReadAloudError.invalidArtifact("processed audio duration is unavailable") }
    return duration
  }

  private func makeTranscriber(
    _ settings: ReadAloudASRSettings, audiobook: URL
  ) throws -> any ReadAloudTranscriber {
    switch settings.engine {
    case .synthesis:
      return try SynthesisTimelineTranscriber(
        tools: tools, runner: runner, audiobook: audiobook)
    case .apple:
      guard #available(macOS 26.0, *) else {
        throw ReadAloudError.unsupportedTool(
          "Apple Speech transcription requires macOS 26; choose Whisper ASR")
      }
      return AppleSpeechReadAloudTranscriber(tools: tools, runner: runner)
    case .whisper:
      guard let model = settings.whisperModel else {
        throw ReadAloudError.invalidRequest("Whisper ASR requires a model")
      }
      return StalignWhisperTranscriber(model: model, tools: tools, runner: runner)
    }
  }

  private func audioFiles(_ directory: URL) throws -> [URL] {
    let files = try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
      .filter { $0.pathExtension.lowercased() == "mp4" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
    guard !files.isEmpty, files.count <= StalignTranscriptValidator.maximumTrackCount else {
      throw ReadAloudError.invalidArtifact("processed audio track set is empty or too large")
    }
    for file in files {
      let values = try file.resourceValues(forKeys: [
        .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
      ])
      guard values.isRegularFile == true, values.isSymbolicLink != true,
        let size = values.fileSize, size > 0
      else { throw ReadAloudError.invalidArtifact("processed audio is not a regular file") }
    }
    return files
  }

  private func reset(_ url: URL) throws {
    try? FileManager.default.removeItem(at: url)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }

  private func stageInput(from source: URL, to destination: URL, expectedSHA256: String) throws {
    let fm = FileManager.default
    try? fm.removeItem(at: destination)
    let temporary = destination.appendingPathExtension(UUID().uuidString + ".partial")
    defer { try? fm.removeItem(at: temporary) }
    try fm.copyItem(at: source, to: temporary)
    guard try ReadAloudTools.sha256(temporary) == expectedSHA256,
      try ReadAloudTools.sha256(source) == expectedSHA256
    else { throw ReadAloudError.invalidRequest("an input changed while it was being staged") }
    try fm.moveItem(at: temporary, to: destination)
  }

  private struct Manifest: Codable {
    var schemaVersion = 3
    var processingFingerprint: String
    var completed: Set<ReadAloudStage>
    var processedIdentity: String?
    var transcriptionFingerprint: String?
    var transcriptionArtifactIdentity: String?
    var transcriptionInputIdentity: String?
    var markupFingerprint: String?
  }

  private struct LegacyManifest: Decodable {
    var schemaVersion: Int
    var fingerprint: String
    var completed: Set<ReadAloudStage>
  }

  private struct LegacyRequest: Encodable {
    var schemaVersion = 1
    var epubPath: String
    var audiobookPath: String
    var outputPath = ""
    var workDirectory = ""
    var opusBitrateKbps: Int
    var language: String
    var whisperModel: String
    var overwrite: Bool
  }

  private func loadManifest(
    _ url: URL, request: ReadAloudRequest, processingFingerprint: String,
    transcriptionFingerprint: String, markupFingerprint: String
  ) throws -> Manifest {
    let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    if values?.isRegularFile == true, let size = values?.fileSize, size <= 1 << 20,
      let data = try? Data(contentsOf: url, options: [.mappedIfSafe])
    {
      if let value = try? JSONDecoder().decode(Manifest.self, from: data),
        value.schemaVersion == 3, value.processingFingerprint == processingFingerprint
      {
        return value
      }
      if request.asr.engine == .whisper,
        let legacy = try? JSONDecoder().decode(LegacyManifest.self, from: data),
        legacy.schemaVersion == 1,
        legacy.fingerprint == legacyRequestFingerprint(request)
      {
        let root = url.deletingLastPathComponent()
        let processed = root.appendingPathComponent("processed", isDirectory: true)
        let transcriptions = root.appendingPathComponent("transcriptions", isDirectory: true)
        let processedIdentity = try? directoryIdentity(processed, extensions: ["mp4"])
        return Manifest(
          processingFingerprint: processingFingerprint, completed: legacy.completed,
          processedIdentity: processedIdentity,
          transcriptionFingerprint: transcriptionFingerprint,
          transcriptionArtifactIdentity: try? directoryIdentity(
            transcriptions, extensions: ["json"]),
          transcriptionInputIdentity: processedIdentity,
          markupFingerprint: markupFingerprint)
      }
    }
    try? FileManager.default.removeItem(
      at: url.deletingLastPathComponent().appendingPathComponent("processed"))
    try? FileManager.default.removeItem(
      at: url.deletingLastPathComponent().appendingPathComponent("transcriptions"))
    return Manifest(
      processingFingerprint: processingFingerprint, completed: [], processedIdentity: nil,
      transcriptionFingerprint: transcriptionFingerprint,
      transcriptionArtifactIdentity: nil, transcriptionInputIdentity: nil,
      markupFingerprint: markupFingerprint)
  }

  private func legacyRequestFingerprint(_ request: ReadAloudRequest) -> String? {
    guard request.asr.engine == .whisper, let model = request.asr.whisperModel else { return nil }
    let legacy = LegacyRequest(
      epubPath: request.epubPath, audiobookPath: request.audiobookPath,
      opusBitrateKbps: request.opusBitrateKbps, language: request.language,
      whisperModel: model.rawValue, overwrite: request.overwrite)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(legacy),
      let epubHash = try? ReadAloudTools.sha256(URL(fileURLWithPath: request.epubPath)),
      let audioHash = try? ReadAloudTools.sha256(URL(fileURLWithPath: request.audiobookPath))
    else { return nil }
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
      + ":\(epubHash):\(audioHash):\(tools.stalignVersion):\(tools.stalignSHA256)"
  }

  private func preparePairedAlignmentDirectory(
    _ directory: URL, processed: URL, transcriptions: URL
  ) throws {
    try reset(directory)
    for audio in try audioFiles(processed) {
      let stem = audio.deletingPathExtension().lastPathComponent
      let transcript = transcriptions.appendingPathComponent(stem + ".json")
      guard FileManager.default.fileExists(atPath: transcript.path) else {
        throw ReadAloudError.invalidArtifact("processed audio has no matching transcript")
      }
      try linkOrCopy(audio, to: directory.appendingPathComponent(audio.lastPathComponent))
      try linkOrCopy(transcript, to: directory.appendingPathComponent(transcript.lastPathComponent))
    }
    try Self.validatePairedStems(
      audio: try rawDirectoryStems(directory, extension: "mp4"),
      transcripts: try rawDirectoryStems(directory, extension: "json"))
  }

  /// stalign (a Node single-executable of Storyteller's aligner) lists the
  /// paired directory twice — once filtered to audio, once to `.json` — and
  /// pairs the two lists positionally. Node's readdir (libuv) returns names
  /// alphabetically sorted, and within one extension group sorting the full
  /// filename orders by stem, so identical stem sets always pair correctly.
  /// The comparison therefore sorts ordinally (matching libuv's bytewise
  /// alphasort) instead of trusting raw readdir(3) order: APFS enumerates in
  /// filename-hash order, which interleaves `.mp4` and `.json` differently
  /// and made this guard reject healthy directories at random.
  static func validatePairedStems(audio: [String], transcripts: [String]) throws {
    let audioOrder = audio.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    let transcriptOrder = transcripts.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    guard audioOrder == transcriptOrder, !audioOrder.isEmpty,
      Set(audioOrder).count == audioOrder.count
    else {
      throw ReadAloudError.invalidArtifact(
        "stalign input enumeration would pair audio with the wrong transcript")
    }
  }

  private func linkOrCopy(_ source: URL, to destination: URL) throws {
    do { try FileManager.default.linkItem(at: source, to: destination) } catch {
      try FileManager.default.copyItem(at: source, to: destination)
    }
  }

  private func rawDirectoryStems(_ directory: URL, extension wanted: String) throws -> [String] {
    guard let handle = opendir(directory.path) else {
      throw ReadAloudError.invalidArtifact("could not enumerate paired stalign input")
    }
    defer { closedir(handle) }
    var result: [String] = []
    while let entry = readdir(handle) {
      var nameTuple = entry.pointee.d_name
      let name = withUnsafePointer(to: &nameTuple) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
          String(cString: $0)
        }
      }
      let url = URL(fileURLWithPath: name)
      if url.pathExtension.lowercased() == wanted {
        result.append(url.deletingPathExtension().lastPathComponent)
      }
    }
    return result
  }

  private func hashStrings(_ values: [String]) -> String {
    var hash = SHA256()
    for value in values {
      hash.update(data: Data(value.utf8))
      hash.update(data: Data([0]))
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private func directoryIdentity(_ directory: URL, extensions: Set<String>) throws -> String {
    let files = try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
      .filter { extensions.contains($0.pathExtension.lowercased()) }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
    guard !files.isEmpty, files.count <= 4_096 else {
      throw ReadAloudError.invalidArtifact("a retained stage has an invalid file count")
    }
    var hash = SHA256()
    for file in files {
      let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
      guard values.isRegularFile == true, let size = values.fileSize, size > 0,
        size <= 128 << 20
      else { throw ReadAloudError.invalidArtifact("a retained stage contains an invalid file") }
      hash.update(data: Data(file.lastPathComponent.utf8))
      hash.update(data: Data([0]))
      hash.update(data: Data(String(size).utf8))
      hash.update(data: Data([0]))
      hash.update(data: Data((try ReadAloudTools.sha256(file)).utf8))
      hash.update(data: Data([10]))
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private func save(_ value: Manifest, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(value)
    let temporary = url.appendingPathExtension(UUID().uuidString)
    try data.write(to: temporary)
    if FileManager.default.fileExists(atPath: url.path) {
      _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    } else {
      try FileManager.default.moveItem(at: temporary, to: url)
    }
  }

  package func requestFingerprint(_ request: ReadAloudRequest) throws -> String {
    var value = request
    value.outputPath = ""
    value.workDirectory = ""
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(value)
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
      + ":\(try ReadAloudTools.sha256(URL(fileURLWithPath: request.epubPath)))"
      + ":\(try ReadAloudTools.sha256(URL(fileURLWithPath: request.audiobookPath)))"
      + ":\(tools.stalignVersion):\(tools.stalignSHA256)"
  }
}

private final class AdvisoryProgressParser: @unchecked Sendable {
  private let lock = NSLock()
  private var last = 0.0
  private let callback: @Sendable (Double) -> Void
  init(callback: @escaping @Sendable (Double) -> Void) { self.callback = callback }
  func consume(_ value: String) {
    let pattern = /Progress:\s*(\d{1,3})%/
    for match in value.matches(of: pattern) {
      guard let amount = Double(match.1), amount <= 100 else { continue }
      lock.withLock {
        let fraction = amount / 100
        guard fraction >= last else { return }
        last = fraction
        callback(fraction)
      }
    }
  }
}

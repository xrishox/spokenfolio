import CryptoKit
import DocumentIOKit
import EPUBKit
import Foundation
import PublicationKit

package struct ReadAloudAuditRequest: Sendable {
  package var epub: URL
  package var sourceEPUB: URL?
  package var mode: ReadAloudAuditMode
  package var retainedTranscriptions: URL?
  package var retainedTranscriptionsAreBound: Bool
  package var workDirectory: URL?
  package var useFreshASR: Bool

  package init(
    epub: URL, sourceEPUB: URL? = nil, mode: ReadAloudAuditMode = .standard,
    retainedTranscriptions: URL? = nil,
    retainedTranscriptionsAreBound: Bool = false,
    workDirectory: URL? = nil, useFreshASR: Bool = true
  ) {
    self.epub = epub
    self.sourceEPUB = sourceEPUB
    self.mode = mode
    self.retainedTranscriptions = retainedTranscriptions
    self.retainedTranscriptionsAreBound = retainedTranscriptionsAreBound
    self.workDirectory = workDirectory
    self.useFreshASR = useFreshASR
  }
}

package struct ReadAloudAuditTools: Sendable {
  package var stalign: URL?
  package var ffmpeg: URL
  package var ffprobe: URL
  package var epubcheck: URL
  package var modelHome: URL?
  package var stalignIdentity: String?
  package var ffmpegIdentity: String?
  package var epubcheckIdentity: String?

  package init(
    stalign: URL?, ffmpeg: URL, ffprobe: URL, epubcheck: URL,
    modelHome: URL? = nil, stalignIdentity: String? = nil,
    ffmpegIdentity: String? = nil, epubcheckIdentity: String? = nil
  ) {
    self.stalign = stalign
    self.ffmpeg = ffmpeg
    self.ffprobe = ffprobe
    self.epubcheck = epubcheck
    self.modelHome = modelHome
    self.stalignIdentity = stalignIdentity
    self.ffmpegIdentity = ffmpegIdentity
    self.epubcheckIdentity = epubcheckIdentity
  }
}

package final class ReadAloudQualityAuditor: @unchecked Sendable {
  package static let policyVersion = 5
  private let runner: ExternalProcessRunner

  package init(runner: ExternalProcessRunner = .init()) { self.runner = runner }

  package func audit(
    _ request: ReadAloudAuditRequest, tools: ReadAloudAuditTools,
    progress: @escaping @Sendable (ReadAloudAuditProgress) -> Void = { _ in }
  ) async throws -> ReadAloudAuditReport {
    let started = Date()
    let artifactHash = try Self.sha256(request.epub)
    let referenceHash = try request.sourceEPUB.map(Self.sha256)
    progress(.init(fraction: 0.01, message: "Checking EPUB 3 specification compliance"))
    let conformance: EPUBConformanceReport
    do {
      conformance = try await EPUBCompliance.validateEPUB3(
        at: request.epub, toolchain: .init(epubcheck: tools.epubcheck),
        archiveLimits: .readAloud)
    } catch {
      let finding = ReadAloudAuditFinding(
        dimension: .compatibility, code: .epubNonconforming,
        verdict: .broken, confidence: .confirmed,
        summary: "The ReadAloud does not pass EPUB 3 specification validation.")
      return ReadAloudAuditReport(
        policyVersion: Self.policyVersion, mode: request.mode,
        verdict: .broken, evidenceAdequacy: .insufficient,
        artifactSHA256: artifactHash, referenceSHA256: referenceHash,
        toolIdentity: tools.epubcheckIdentity, startedAt: started,
        metrics: .init(), findings: [finding])
    }
    progress(.init(fraction: 0.04, message: "Inspecting EPUB Media Overlays"))

    let inspection: ReadAloudInspection
    do {
      inspection = try ReadAloudInspector.inspect(request.epub)
    } catch let error as ZIPError {
      let policyRefusal: Bool
      switch error {
      case .archiveFileTooLarge, .tooManyEntries, .entryTooLarge,
        .archiveContentsTooLarge, .zip64ArchiveUnsupported,
        .unsupportedCompressionMethod:
        policyRefusal = true
      default: policyRefusal = false
      }
      let finding = ReadAloudAuditFinding(
        dimension: .structure,
        code: policyRefusal ? .safetyLimitExceeded : .missingManifestReference,
        verdict: policyRefusal ? .inconclusive : .broken,
        confidence: .confirmed, summary: error.localizedDescription)
      return ReadAloudAuditReport(
        policyVersion: Self.policyVersion, mode: request.mode,
        verdict: policyRefusal ? .inconclusive : .broken,
        evidenceAdequacy: .insufficient, artifactSHA256: artifactHash,
        referenceSHA256: referenceHash, epubConformance: conformance, startedAt: started,
        metrics: .init(), findings: [finding])
    } catch {
      let finding = ReadAloudAuditFinding(
        dimension: .structure, code: .missingManifestReference,
        verdict: .broken, confidence: .confirmed,
        summary: error.localizedDescription)
      return ReadAloudAuditReport(
        policyVersion: Self.policyVersion, mode: request.mode,
        verdict: .broken, evidenceAdequacy: .insufficient,
        artifactSHA256: artifactHash, referenceSHA256: referenceHash,
        epubConformance: conformance, startedAt: started,
        metrics: .init(), findings: [finding])
    }

    var metrics = inspection.metrics
    var findings = inspection.findings
    progress(.init(fraction: 0.12, message: "Checking embedded audio"))
    try await probeAudio(
      inspection: inspection, ffmpeg: tools.ffmpeg, ffprobe: tools.ffprobe,
      findings: &findings, progress: progress)

    if let source = request.sourceEPUB {
      progress(.init(fraction: 0.25, message: "Comparing source publication"))
      do {
        let publication = try EPUBImporter().load(url: source, archiveLimits: .readAloud)
        let sourceText = publication.sections.filter {
          $0.readingOrder == .primary && Self.isPrimary($0.role)
        }.flatMap(\.blocks).map(\.text).joined(separator: "\n")
        let identity = Self.identity(sourceText, inspection.narrativeText)
        if identity.leftCoverage < 0.70 || identity.rightCoverage < 0.70 {
          findings.append(
            ReadAloudAuditFinding(
              dimension: .identity, code: .sourcePublicationMismatch,
              verdict: .likelyBroken, confidence: .strong,
              summary: "The ReadAloud text does not match the supplied source EPUB.",
              metrics: [
                "sourceCoverage": identity.leftCoverage,
                "readAloudCoverage": identity.rightCoverage,
              ]))
        }
      } catch {
        findings.append(
          ReadAloudAuditFinding(
            dimension: .identity, code: .sourcePublicationMismatch,
            verdict: .needsReview, confidence: .tentative,
            summary: "The supplied source EPUB could not be compared safely."))
      }
    }

    var evidence: TranscriptEvidence?
    var boundEvidenceComplete = false
    if let directory = request.retainedTranscriptions {
      progress(.init(fraction: 0.32, message: "Evaluating retained transcript evidence"))
      if request.retainedTranscriptionsAreBound {
        try TranscriptBindingManifest.validate(
          transcriptions: directory, inspection: inspection)
        evidence = try TranscriptEvidence.load(directory)
        boundEvidenceComplete = evaluateFullEvidence(
          evidence!, inspection: inspection, metrics: &metrics, findings: &findings)
      } else {
        evidence = try? TranscriptEvidence.load(directory)
        findings.append(
          ReadAloudAuditFinding(
            dimension: .identity, code: .unboundTranscriptEvidence,
            verdict: .likelyCorrect, confidence: .confirmed,
            summary:
              "Retained transcripts are advisory because they are not bound to the embedded audio.")
        )
      }
    }

    var adequacy: ReadAloudEvidenceAdequacy =
      boundEvidenceComplete ? .complete : (evidence == nil ? .insufficient : .advisory)
    var freshASRUsed = false
    if request.mode == .thorough, request.useFreshASR {
      guard let stalign = tools.stalign else {
        findings.append(missingASRFinding())
        return report(
          request, artifactHash, referenceHash, started, metrics, findings,
          adequacy: .insufficient, tools: tools, conformance: conformance)
      }
      progress(.init(fraction: 0.38, message: "Transcribing all referenced audio"))
      let fresh = try await thoroughEvidence(
        inspection: inspection, request: request, tools: tools, stalign: stalign,
        progress: progress)
      freshASRUsed = true
      adequacy = evaluateFullEvidence(
        fresh, inspection: inspection, metrics: &metrics, findings: &findings)
        ? .complete : .insufficient
    } else if request.useFreshASR {
      guard let stalign = tools.stalign else {
        findings.append(missingASRFinding())
        return report(
          request, artifactHash, referenceHash, started, metrics, findings,
          adequacy: .insufficient, tools: tools, conformance: conformance)
      }
      progress(.init(fraction: 0.38, message: "Preparing distributed ASR samples"))
      let scores = try await sampleScores(
        inspection: inspection, request: request, tools: tools, stalign: stalign,
        progress: progress)
      applySampleScores(scores, metrics: &metrics, findings: &findings)
      freshASRUsed = !scores.isEmpty
      adequacy =
        scores.isEmpty ? .insufficient
        : boundEvidenceComplete ? .complete : .sampled
    }

    progress(.init(fraction: 0.98, message: "Adjudicating evidence"))
    return report(
      request, artifactHash, referenceHash, started, metrics, findings,
      adequacy: adequacy, tools: tools, freshASRUsed: freshASRUsed,
      conformance: conformance)
  }

  private func report(
    _ request: ReadAloudAuditRequest, _ artifactHash: String, _ referenceHash: String?,
    _ started: Date, _ metrics: ReadAloudAuditMetrics,
    _ findings: [ReadAloudAuditFinding], adequacy: ReadAloudEvidenceAdequacy,
    tools: ReadAloudAuditTools, freshASRUsed: Bool = false,
    conformance: EPUBConformanceReport
  ) -> ReadAloudAuditReport {
    let verdict = Self.verdict(findings: findings, adequacy: adequacy, metrics: metrics)
    return ReadAloudAuditReport(
      policyVersion: Self.policyVersion, mode: request.mode, verdict: verdict,
      evidenceAdequacy: adequacy, artifactSHA256: artifactHash,
      referenceSHA256: referenceHash,
      modelIdentity: freshASRUsed ? "whisper.cpp:small-multilingual" : nil,
      toolIdentity: [
        tools.stalignIdentity, tools.ffmpegIdentity, tools.epubcheckIdentity,
      ].compactMap { $0 }.joined(separator: "; "),
      epubConformance: conformance, startedAt: started,
      metrics: metrics, findings: findings)
  }

  private func probeAudio(
    inspection: ReadAloudInspection, ffmpeg: URL, ffprobe: URL,
    findings: inout [ReadAloudAuditFinding],
    progress: @escaping @Sendable (ReadAloudAuditProgress) -> Void
  ) async throws {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
      "readaloud-probe-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    var nonPreferredCount = 0
    var stereoCount = 0
    for (index, member) in inspection.audio.enumerated() {
      try Task.checkCancellation()
      let file = temporary.appendingPathComponent(
        "\(index).\(URL(fileURLWithPath: member.path).pathExtension)")
      try inspection.archive.extract(member.entry, to: file)
      let result = try await runner.run(
        executable: ffprobe,
        arguments: [
          "-v", "error", "-select_streams", "a:0",
          "-show_entries", "stream=codec_name,sample_rate,channels,duration",
          "-of", "json", file.path,
        ], environment: ProcessInfo.processInfo.environment)
      guard result.status == 0,
        let object = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any],
        let streams = object["streams"] as? [[String: Any]], streams.count == 1,
        let stream = streams.first,
        let duration = Double(String(describing: stream["duration"] ?? "")), duration > 0
      else {
        findings.append(
          ReadAloudAuditFinding(
            dimension: .compatibility, code: .unsupportedAudio,
            verdict: .inconclusive, confidence: .confirmed,
            summary: "A referenced audio member cannot be decoded.", audioPath: member.path))
        continue
      }
      let decode = try await runner.run(
        executable: ffmpeg,
        arguments: [
          "-hide_banner", "-loglevel", "error", "-xerror", "-i", file.path,
          "-map", "0:a:0", "-f", "null", "-",
        ], environment: ProcessInfo.processInfo.environment)
      guard decode.status == 0 else {
        findings.append(
          ReadAloudAuditFinding(
            dimension: .compatibility, code: .unsupportedAudio,
            verdict: .broken, confidence: .confirmed,
            summary: "A referenced audio member cannot be fully decoded.",
            audioPath: member.path))
        continue
      }
      let maximumClip =
        inspection.clips.filter { $0.audioPath == member.path }.map(\.end).max() ?? 0
      if maximumClip > duration + 0.05 {
        findings.append(
          ReadAloudAuditFinding(
            dimension: .structure, code: .clipOutsideMedia,
            verdict: .broken, confidence: .confirmed,
            summary: "A Media Overlay clip extends beyond the referenced audio.",
            audioPath: member.path, clipEnd: maximumClip,
            metrics: ["audioDuration": duration]))
      }
      let codec = stream["codec_name"] as? String ?? "unknown"
      let rate = Int(String(describing: stream["sample_rate"] ?? "")) ?? 0
      let channels = stream["channels"] as? Int ?? 0
      if codec != "opus" || rate != 48_000 || !(1...2).contains(channels) {
        nonPreferredCount += 1
      } else if channels == 2 {
        stereoCount += 1
      }
      try? FileManager.default.removeItem(at: file)
      progress(
        .init(
          fraction: 0.12 + 0.12 * Double(index + 1) / Double(max(1, inspection.audio.count)),
          message: "Checked audio \(index + 1) of \(inspection.audio.count)"))
    }
    if nonPreferredCount > 0 {
      findings.append(
        ReadAloudAuditFinding(
          dimension: .compatibility, code: .formatPortability,
          verdict: .needsReview, confidence: .confirmed,
          summary:
            "Some audio decodes but differs from the preferred Storyteller/SpokenFolio Opus profile.",
          metrics: ["affectedTracks": Double(nonPreferredCount)]))
    }
    if stereoCount > 0 {
      findings.append(
        ReadAloudAuditFinding(
          dimension: .compatibility, code: .formatPortability,
          verdict: .needsReview, confidence: .confirmed,
          summary:
            "Stereo Storyteller Opus is valid for auditing but is not SpokenFolio's mono production profile.",
          metrics: ["affectedTracks": Double(stereoCount)]))
    }
  }

  private func evaluateIdentityOnly(
    _ evidence: TranscriptEvidence, inspection: ReadAloudInspection,
    metrics: inout ReadAloudAuditMetrics, findings: inout [ReadAloudAuditFinding]
  ) {
    let identity = Self.identity(inspection.narrativeText, evidence.completeText)
    metrics.textToTranscriptCoverage = identity.leftCoverage
    metrics.transcriptToTextCoverage = identity.rightCoverage
    Self.applyIdentity(identity, findings: &findings)
  }

  @discardableResult
  private func evaluateFullEvidence(
    _ evidence: TranscriptEvidence, inspection: ReadAloudInspection,
    metrics: inout ReadAloudAuditMetrics, findings: inout [ReadAloudAuditFinding]
  ) -> Bool {
    let stems = inspection.audio.map {
      (URL(fileURLWithPath: $0.path).lastPathComponent as NSString).deletingPathExtension
    }
    guard Set(stems).count == stems.count else {
      findings.append(
        ReadAloudAuditFinding(
          dimension: .identity, code: .insufficientSemanticEvidence,
          verdict: .inconclusive, confidence: .confirmed,
          summary: "Transcript evidence is ambiguous because embedded audio basenames collide."))
      return false
    }
    evaluateIdentityOnly(evidence, inspection: inspection, metrics: &metrics, findings: &findings)
    var orderedScores: [(order: Int, score: Double, weight: Int)] = []
    var eligibleClipCount = 0
    var matchedClipCount = 0
    var clipsByStem: [String: [(offset: Int, element: ReadAloudClip)]] = [:]
    for (index, clip) in inspection.clips.enumerated() {
      let stem =
        (URL(fileURLWithPath: clip.audioPath).lastPathComponent as NSString)
        .deletingPathExtension
      clipsByStem[stem, default: []].append((index, clip))
    }
    for (stem, indexedClips) in clipsByStem {
      let clips = indexedClips.sorted {
        if $0.element.begin != $1.element.begin {
          return $0.element.begin < $1.element.begin
        }
        return $0.offset < $1.offset
      }
      for indexedClip in clips where Self.tokens(indexedClip.element.text).count >= 3 {
        eligibleClipCount += 1
      }
      guard let timeline = evidence.byAudioStem[stem] else { continue }

      // Word-granular evidence is judged at the overlay-clip boundary. A
      // synthesis segment may intentionally cover a whole paragraph while
      // stalign emits several sentence clips, so segment evidence is judged
      // against every clip it overlaps. Comparing each sentence to the full
      // paragraph makes correct Expressive timelines fail by construction.
      for indexedClip in clips {
        let clip = indexedClip.element
        let range = Self.wordRange(begin: clip.begin, end: clip.end, timeline: timeline)
        if Self.tokens(clip.text).count >= 3, !range.isEmpty {
          matchedClipCount += 1
        }
        let words = timeline.words[range].filter { $0.type == "word" }
        guard !words.isEmpty else { continue }
        let weight = Self.tokens(clip.text).count
        guard weight >= 3 else { continue }
        orderedScores.append(
          (
            indexedClip.offset,
            Self.sequenceSimilarity(
              clip.text, words.map(\.text).joined(separator: " ")),
            weight
          ))
      }

      var pendingSegments: [TranscriptEvidence.Word] = []
      var pendingClipRange: Range<Int>?
      func flushSegments() {
        guard let clipRange = pendingClipRange, !pendingSegments.isEmpty else {
          pendingSegments.removeAll(keepingCapacity: true)
          pendingClipRange = nil
          return
        }
        let referenced = clips[clipRange].map(\.element.text).joined(separator: " ")
        let spoken = pendingSegments.map(\.text).joined(separator: " ")
        let weight = Self.tokens(referenced).count
        if weight >= 3 {
          orderedScores.append(
            (
              clips[clipRange.lowerBound].offset,
              Self.sequenceSimilarity(referenced, spoken),
              weight
            ))
        }
        pendingSegments.removeAll(keepingCapacity: true)
        pendingClipRange = nil
      }
      for segment in timeline.words where segment.type == "segment" {
        let range = Self.clipRange(begin: segment.start, end: segment.end, clips: clips)
        guard !range.isEmpty else {
          flushSegments()
          continue
        }
        // Multiple coarse segments that cover precisely the same overlay
        // fragment set are one comparison unit. This supports an aligner clip
        // spanning adjacent synthesis pieces without allowing small boundary
        // overlaps to merge an entire track and hide displaced timing.
        if pendingClipRange != range {
          flushSegments()
          pendingClipRange = range
        }
        pendingSegments.append(segment)
      }
      flushSegments()
    }
    let coverage = eligibleClipCount == 0
      ? 0 : Double(matchedClipCount) / Double(eligibleClipCount)
    if coverage < 0.95 {
      findings.append(
        ReadAloudAuditFinding(
          dimension: .identity, code: .insufficientSemanticEvidence,
          verdict: .inconclusive, confidence: .confirmed,
          summary: "Bound transcript evidence does not cover the embedded narration tracks.",
          metrics: ["clipEvidenceCoverage": coverage]))
    }
    let scores = orderedScores.sorted { $0.order < $1.order }
    guard !scores.isEmpty else { return false }
    let totalWeight = scores.reduce(0) { $0 + $1.weight }
    let weighted = scores.reduce(0.0) { $0 + $1.score * Double($1.weight) } / Double(totalWeight)
    let low = Double(scores.filter { $0.score < 0.50 }.count) / Double(scores.count)
    var longest = 0
    var run = 0
    for value in scores {
      if value.score < 0.50 {
        run += 1
        longest = max(longest, run)
      } else {
        run = 0
      }
    }
    metrics.clipWeightedSimilarity = weighted
    metrics.lowClipFraction = low
    metrics.longestLowClipRun = longest
    if weighted < 0.60 || low > 0.20 {
      findings.append(
        ReadAloudAuditFinding(
          dimension: .timing, code: .broadlyDisplacedTiming,
          verdict: .likelyBroken, confidence: .strong,
          summary: "Bound transcript words do not agree with the referenced text intervals.",
          metrics: ["weightedSimilarity": weighted, "lowClipFraction": low]))
    } else if weighted < 0.85 || low > 0.05 || longest >= 10 {
      findings.append(
        ReadAloudAuditFinding(
          dimension: .timing, code: .localizedTimingDefect,
          verdict: .needsReview, confidence: .strong,
          summary: "The alignment contains localized or borderline timing defects.",
          metrics: [
            "weightedSimilarity": weighted, "lowClipFraction": low,
            "longestLowRun": Double(longest),
          ]))
    }
    return coverage >= 0.95
  }

  private static func wordRange(
    begin: Double, end: Double, timeline: TranscriptEvidence.Timeline
  ) -> Range<Int> {
    let values = timeline.words
    var lower = 0
    var upper = values.count
    while lower < upper {
      let middle = lower + (upper - lower) / 2
      if values[middle].end <= begin {
        lower = middle + 1
      } else {
        upper = middle
      }
    }
    let start = lower
    while lower < values.count, values[lower].start < end { lower += 1 }
    return start..<lower
  }

  private static func clipRange(
    begin: Double, end: Double,
    clips: [(offset: Int, element: ReadAloudClip)]
  ) -> Range<Int> {
    var lower = 0
    var upper = clips.count
    while lower < upper {
      let middle = lower + (upper - lower) / 2
      if clips[middle].element.end <= begin {
        lower = middle + 1
      } else {
        upper = middle
      }
    }
    let start = lower
    while lower < clips.count, clips[lower].element.begin < end { lower += 1 }
    return start..<lower
  }

  private static func applyIdentity(
    _ identity: IdentityScore, findings: inout [ReadAloudAuditFinding]
  ) {
    if identity.leftCoverage < 0.10 && identity.rightCoverage < 0.10 {
      findings.append(
        ReadAloudAuditFinding(
          dimension: .identity, code: .possibleWorkTranslationOrLanguageMismatch,
          verdict: .likelyBroken, confidence: .strong,
          summary:
            "Audio and text likely represent different works, translations, editions, or languages; the evidence cannot identify which asset is incorrect.",
          metrics: [
            "textCoverage": identity.leftCoverage,
            "transcriptCoverage": identity.rightCoverage,
          ]))
    } else if identity.rightCoverage >= 0.70 && identity.leftCoverage < 0.60 {
      findings.append(
        ReadAloudAuditFinding(
          dimension: .identity, code: .possibleAbridgedOrIncompatibleEdition,
          verdict: .likelyBroken, confidence: .strong,
          summary:
            "The spoken material is largely contained in the text, but substantial text is absent from the audio.",
          metrics: [
            "textCoverage": identity.leftCoverage,
            "transcriptCoverage": identity.rightCoverage,
          ]))
    } else if identity.leftCoverage < 0.70 || identity.rightCoverage < 0.70 {
      findings.append(
        ReadAloudAuditFinding(
          dimension: .identity, code: .possibleAbridgedOrIncompatibleEdition,
          verdict: .needsReview, confidence: .tentative,
          summary: "Text/audio identity is incomplete or ambiguous.",
          metrics: [
            "textCoverage": identity.leftCoverage,
            "transcriptCoverage": identity.rightCoverage,
          ]))
    }
  }

  private func sampleScores(
    inspection: ReadAloudInspection, request: ReadAloudAuditRequest,
    tools: ReadAloudAuditTools, stalign: URL,
    progress: @escaping @Sendable (ReadAloudAuditProgress) -> Void
  ) async throws -> [Double] {
    let work =
      request.workDirectory
      ?? FileManager.default.temporaryDirectory
      .appendingPathComponent("readaloud-audit-\(UUID().uuidString)", isDirectory: true)
    let disposable = request.workDirectory == nil
    defer { if disposable { try? FileManager.default.removeItem(at: work) } }
    let input = work.appendingPathComponent("samples", isDirectory: true)
    let output = work.appendingPathComponent("sample-transcriptions", isDirectory: true)
    // Audit work directories are user-selectable and may outlive an earlier
    // artifact. Until a cache manifest can prove identity, never reuse them.
    try? FileManager.default.removeItem(at: input)
    try? FileManager.default.removeItem(at: output)
    try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

    let primary = inspection.clips.filter(\.primary)
    guard !primary.isEmpty else { return [] }
    let sectionCount = Set(primary.map(\.documentPath)).count
    let duration = Dictionary(grouping: primary, by: \.audioPath).values.reduce(0.0) {
      $0 + (($1.map(\.end).max() ?? 0) - ($1.map(\.begin).min() ?? 0))
    }
    let target = duration > 12 * 3_600 || sectionCount > 24 ? 24 : 12
    let clipDurations = primary.map { max(0.001, $0.end - $0.begin) }
    let totalClipDuration = clipDurations.reduce(0, +)
    let points = (0..<target).map {
      totalClipDuration * (Double($0) + 0.5) / Double(target)
    }
    var indices: [Int] = []
    var cumulative = 0.0
    var pointIndex = 0
    for (index, value) in clipDurations.enumerated() where pointIndex < points.count {
      cumulative += value
      while pointIndex < points.count, cumulative >= points[pointIndex] {
        indices.append(index)
        pointIndex += 1
      }
    }
    var references: [String: String] = [:]
    let grouped = Dictionary(grouping: Array(Set(indices)).sorted().enumerated()) {
      primary[$0.element].audioPath
    }
    var sampleNumber = 0
    for (audioPath, selected) in grouped.sorted(by: { $0.key < $1.key }) {
      guard let member = inspection.audio.first(where: { $0.path == audioPath }) else { continue }
      let track = work.appendingPathComponent(
        "track.\(URL(fileURLWithPath: audioPath).pathExtension)")
      try inspection.archive.extract(member.entry, to: track)
      let audioClips = primary.filter { $0.audioPath == audioPath }
      for pair in selected {
        sampleNumber += 1
        let anchor = primary[pair.element]
        let tentativeStart = max(0, (anchor.begin + anchor.end) / 2 - 22.5)
        let candidates = audioClips.filter {
          $0.end >= tentativeStart && $0.begin <= tentativeStart + 45
        }
        guard let first = candidates.first, let last = candidates.last else { continue }
        let start = first.begin
        let end = min(last.end, start + 45)
        let reference = candidates.filter { $0.begin < end }.map(\.text).joined(separator: " ")
        let name = String(format: "sample-%03d", sampleNumber)
        let wav = input.appendingPathComponent(name + ".wav")
        if !FileManager.default.fileExists(atPath: wav.path) {
          let result = try await runner.run(
            executable: tools.ffmpeg,
            arguments: [
              "-hide_banner", "-loglevel", "error", "-y", "-ss", "\(start)",
              "-i", track.path, "-t", "\(max(0.1, end - start))",
              "-ar", "16000", "-ac", "1", wav.path,
            ], environment: auditEnvironment(tools.modelHome, work: work))
          guard result.status == 0 else {
            throw ReadAloudError.processFailed("ffmpeg could not prepare an audit sample")
          }
        }
        references[name] = reference
      }
      try? FileManager.default.removeItem(at: track)
    }
    guard !references.isEmpty else { return [] }
    let result = try await runWhisper(
      stalign: stalign, arguments: [
        "transcribe", "--parallel", "1", "--engine", "whisper.cpp",
        "--model", "small", "--no-progress", "--log-level", "info",
        input.path, output.path,
      ], modelHome: tools.modelHome, work: work)
    guard result.status == 0 else {
      throw ReadAloudError.processFailed(
        String(decoding: result.stderr.suffix(4_096), as: UTF8.self))
    }
    var scores: [Double] = []
    for (index, pair) in references.sorted(by: { $0.key < $1.key }).enumerated() {
      let file = output.appendingPathComponent(pair.key + ".json")
      guard let value = try? StalignTranscriptValidator.decode(file),
        let duration = value.timeline.last?.endTime,
        (try? StalignTranscriptValidator.validate(value, audioDuration: duration)) != nil
      else { continue }
      scores.append(Self.sequenceSimilarity(pair.value, value.transcript))
      progress(
        .init(
          fraction: 0.45 + 0.45 * Double(index + 1) / Double(references.count),
          message: "Scored ASR sample \(index + 1) of \(references.count)"))
    }
    let minimum = max(1, Int(ceil(Double(references.count) * 0.75)))
    return scores.count >= minimum ? scores : []
  }

  private func thoroughEvidence(
    inspection: ReadAloudInspection, request: ReadAloudAuditRequest,
    tools: ReadAloudAuditTools, stalign: URL,
    progress: @escaping @Sendable (ReadAloudAuditProgress) -> Void
  ) async throws -> TranscriptEvidence {
    let work =
      request.workDirectory
      ?? FileManager.default.temporaryDirectory
      .appendingPathComponent("readaloud-thorough-\(UUID().uuidString)", isDirectory: true)
    let disposable = request.workDirectory == nil
    defer { if disposable { try? FileManager.default.removeItem(at: work) } }
    let input = work.appendingPathComponent("full-input", isDirectory: true)
    let output = work.appendingPathComponent("full-transcriptions", isDirectory: true)
    try? FileManager.default.removeItem(at: input)
    try? FileManager.default.removeItem(at: output)
    try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    for (index, member) in inspection.audio.enumerated() {
      try Task.checkCancellation()
      let name = URL(fileURLWithPath: member.path).lastPathComponent
      let expected = output.appendingPathComponent(
        (name as NSString).deletingPathExtension + ".json")
      if !FileManager.default.fileExists(atPath: expected.path) {
        let track = input.appendingPathComponent(name)
        try inspection.archive.extract(member.entry, to: track)
        let result = try await runWhisper(
          stalign: stalign, arguments: [
            "transcribe", "--parallel", "1", "--engine", "whisper.cpp",
            "--model", "small", "--no-progress", "--log-level", "info",
            input.path, output.path,
          ], modelHome: tools.modelHome, work: work)
        try? FileManager.default.removeItem(at: track)
        guard result.status == 0 else {
          throw ReadAloudError.processFailed(
            String(decoding: result.stderr.suffix(4_096), as: UTF8.self))
        }
      }
      progress(
        .init(
          fraction: 0.38 + 0.55 * Double(index + 1) / Double(max(1, inspection.audio.count)),
          message: "Transcribed audio \(index + 1) of \(inspection.audio.count)"))
    }
    return try TranscriptEvidence.load(output)
  }

  private func applySampleScores(
    _ scores: [Double], metrics: inout ReadAloudAuditMetrics,
    findings: inout [ReadAloudAuditFinding]
  ) {
    guard !scores.isEmpty else {
      findings.append(missingASRFinding())
      return
    }
    let weighted = scores.reduce(0, +) / Double(scores.count)
    let severe = scores.filter { $0 < 0.50 }.count
    metrics.freshASRWeightedSimilarity = weighted
    metrics.freshASRSampleCount = scores.count
    metrics.freshASRSevereSampleCount = severe
    if weighted < 0.55 || (scores.count >= 6 && severe * 2 >= scores.count) {
      findings.append(
        ReadAloudAuditFinding(
          dimension: .timing, code: .broadlyDisplacedTiming,
          verdict: .likelyBroken, confidence: .strong,
          summary: "Distributed fresh ASR repeatedly disagrees with the referenced text.",
          metrics: ["weightedSimilarity": weighted, "severeSamples": Double(severe)]))
    } else if weighted < 0.80 || Double(severe) / Double(scores.count) > 0.10 {
      findings.append(
        ReadAloudAuditFinding(
          dimension: .timing, code: .localizedTimingDefect,
          verdict: .needsReview, confidence: .strong,
          summary: "Fresh ASR found borderline or localized text/timing disagreement.",
          metrics: ["weightedSimilarity": weighted, "severeSamples": Double(severe)]))
    }
  }

  private func missingASRFinding() -> ReadAloudAuditFinding {
    ReadAloudAuditFinding(
      dimension: .identity, code: .insufficientSemanticEvidence,
      verdict: .inconclusive, confidence: .confirmed,
      summary:
        "Independent semantic evidence is unavailable; install the managed ASR tools or provide bound transcripts."
    )
  }

  private func auditEnvironment(_ modelHome: URL?, work: URL) -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    if let modelHome {
      try? FileManager.default.createDirectory(at: modelHome, withIntermediateDirectories: true)
      environment["HOME"] = modelHome.path
    }
    let temporary = work.appendingPathComponent("tmp", isDirectory: true)
    try? FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    environment["TMPDIR"] = temporary.path
    return environment
  }

  private func runWhisper(
    stalign: URL, arguments: [String], modelHome: URL?, work: URL
  ) async throws -> ExternalProcessResult {
    let home = modelHome ?? work.appendingPathComponent("stalign-home", isDirectory: true)
    let environment = auditEnvironment(home, work: work)
    return try await ReadAloudCacheLock.withLock(home: home) {
      try await self.runner.run(
        executable: stalign, arguments: arguments, environment: environment)
    }
  }

  private static func verdict(
    findings: [ReadAloudAuditFinding], adequacy: ReadAloudEvidenceAdequacy,
    metrics: ReadAloudAuditMetrics
  ) -> ReadAloudAuditVerdict {
    if findings.contains(where: { $0.verdict == .broken }) { return .broken }
    if findings.contains(where: { $0.verdict == .likelyBroken }) { return .likelyBroken }
    if findings.contains(where: { $0.verdict == .inconclusive }) || adequacy == .insufficient {
      return .inconclusive
    }
    let materialReview = findings.contains {
      $0.verdict == .needsReview && $0.dimension != .compatibility
    }
    if materialReview { return .needsReview }
    guard (metrics.primaryCoverage ?? 0) >= 0.95,
      metrics.freshASRWeightedSimilarity != nil || metrics.clipWeightedSimilarity != nil
    else { return .needsReview }
    return .likelyCorrect
  }

  private struct IdentityScore {
    var leftCoverage: Double
    var rightCoverage: Double
  }

  private static func identity(_ left: String, _ right: String) -> IdentityScore {
    let leftValues = tokens(left, limit: 500_004)
    let rightValues = tokens(right, limit: 500_004)
    let leftGrams = shingles(leftValues)
    let rightGrams = shingles(rightValues)
    let shared = leftGrams.intersection(rightGrams).count
    return IdentityScore(
      leftCoverage: leftGrams.isEmpty ? 0 : Double(shared) / Double(leftGrams.count),
      rightCoverage: rightGrams.isEmpty ? 0 : Double(shared) / Double(rightGrams.count))
  }

  private static func shingles(_ tokens: [String]) -> Set<UInt64> {
    guard tokens.count >= 5 else { return [] }
    var result = Set<UInt64>()
    result.reserveCapacity(min(500_000, tokens.count))
    for index in 0...(tokens.count - 5) {
      var hash: UInt64 = 1_469_598_103_934_665_603
      for token in tokens[index..<(index + 5)] {
        for byte in token.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        hash = (hash ^ 0xFF) &* 1_099_511_628_211
      }
      result.insert(hash)
      if result.count == 500_000 { break }
    }
    return result
  }

  private static func sequenceSimilarity(_ left: String, _ right: String) -> Double {
    // Clip and sample comparison is deliberately bounded. The whole-book
    // identity path uses shingles instead of this quadratic algorithm.
    let a = tokens(left, limit: 4_096)
    let b = tokens(right, limit: 4_096)
    guard !a.isEmpty, !b.isEmpty else { return 0 }
    var previous = [Int](repeating: 0, count: b.count + 1)
    for token in a {
      var current = [Int](repeating: 0, count: b.count + 1)
      for index in b.indices {
        current[index + 1] =
          token == b[index]
          ? previous[index] + 1 : max(previous[index + 1], current[index])
      }
      previous = current
    }
    return 2 * Double(previous[b.count]) / Double(a.count + b.count)
  }

  private static func tokens(_ value: String, limit: Int = 1_000_000) -> [String] {
    guard limit > 0 else { return [] }
    var result: [String] = []
    result.reserveCapacity(min(limit, 4_096))
    var token = String.UnicodeScalarView()
    token.reserveCapacity(32)

    func flush() {
      guard !token.isEmpty, result.count < limit else {
        token.removeAll(keepingCapacity: true)
        return
      }
      result.append(
        String(token).folding(
          options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")))
      token.removeAll(keepingCapacity: true)
    }

    for scalar in value.unicodeScalars {
      if CharacterSet.alphanumerics.contains(scalar) {
        // A pathological unbroken token must not defeat the whole-book bound.
        if token.count < 256 { token.append(scalar) }
      } else {
        flush()
        if result.count == limit { break }
      }
    }
    flush()
    return result
  }

  private static func isPrimary(_ role: SectionRole) -> Bool {
    ![
      .cover, .titlePage, .copyright, .printedTOC, .notes, .bibliography,
      .index, .aboutAuthor, .alsoBy, .excerpt, .promotional,
    ].contains(role)
  }

  package static func sha256(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var digest = SHA256()
    while true {
      let data = try handle.read(upToCount: 1 << 20) ?? Data()
      if data.isEmpty { break }
      digest.update(data: data)
    }
    return digest.finalize().map { String(format: "%02x", $0) }.joined()
  }
}

private struct TranscriptEvidence {
  struct Word {
    var type: String
    var text: String
    var start: Double
    var end: Double
  }
  struct Timeline {
    var transcript: String
    var words: [Word]
  }
  var byAudioStem: [String: Timeline]
  var completeText: String {
    byAudioStem.keys.sorted().compactMap { byAudioStem[$0]?.transcript }.joined(separator: " ")
  }

  static func load(_ directory: URL) throws -> TranscriptEvidence {
    let files = try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
    )
    .filter { $0.pathExtension.lowercased() == "json" }.sorted {
      $0.lastPathComponent < $1.lastPathComponent
    }
    guard files.count <= 1_024 else {
      throw ReadAloudError.invalidArtifact("too many transcript files")
    }
    var total = 0
    var totalWords = 0
    var values: [String: Timeline] = [:]
    for file in files {
      let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
      guard size > 0, size <= StalignTranscriptValidator.maximumFileSize else {
        throw ReadAloudError.invalidArtifact("a transcript exceeds the size limit")
      }
      total += size
      guard total <= 256 << 20 else {
        throw ReadAloudError.invalidArtifact("transcripts exceed the total size limit")
      }
      let value = try StalignTranscriptValidator.decode(file)
      let duration = value.timeline.last?.endTime ?? 0
      try StalignTranscriptValidator.validate(value, audioDuration: duration)
      let words = value.timeline.map {
        Word(type: $0.type, text: $0.text, start: $0.startTime, end: $0.endTime)
      }
      totalWords += words.count
      guard totalWords <= 5_000_000 else {
        throw ReadAloudError.invalidArtifact("transcript timelines exceed the word limit")
      }
      values[(file.lastPathComponent as NSString).deletingPathExtension] = Timeline(
        transcript: value.transcript, words: words)
    }
    return TranscriptEvidence(byAudioStem: values)
  }
}

import CryptoKit
import Foundation
import PublicationKit
import TTSKit

/// Ground-truth narration timing captured during synthesis. All frame values
/// are 48 kHz sample frames relative to the start of the chapter artifact
/// (head pad included). Fine-grained spans come only from validated engine or
/// independently synthesized-piece anchors; when neither exists the exact
/// utterance span is retained as one segment. Character-proportional estimates
/// are deliberately unsupported.
extension String {
  fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}

package struct ChapterSynthesisTimeline: Codable, Sendable, Equatable {
  package static let schemaVersion = 3

  package enum UnitKind: String, Codable, Sendable {
    case prose
    case announcement
    case speechlessSilence
  }

  package enum SentenceDerivation: String, Codable, Sendable {
    case unit
    case words
    /// Decoded only so diagnostics can identify legacy schema-1 artifacts.
    /// Schema-2 writers never emit it.
    case interpolated
  }

  package struct UnitTiming: Codable, Sendable, Equatable {
    package var unitIndex: Int
    package var text: String
    package var kind: UnitKind
    package var startFrame: Int
    package var frameCount: Int
    package var pauseAfterFrames: Int
  }

  /// One request that actually completed in the synthesis backend. Ordinary
  /// units contribute one segment; failure-only fallback contributes each
  /// independently synthesized piece with its exact concatenation boundary.
  package struct SegmentTiming: Codable, Sendable, Equatable {
    package var text: String
    package var kind: UnitKind
    package var startFrame: Int
    package var endFrame: Int
    package var sourceLocator: SourceLocator?
    package var sourceRange: SourceTextRange?

    package init(
      text: String, kind: UnitKind, startFrame: Int, endFrame: Int,
      sourceLocator: SourceLocator?, sourceRange: SourceTextRange?
    ) {
      self.text = text
      self.kind = kind
      self.startFrame = startFrame
      self.endFrame = endFrame
      self.sourceLocator = sourceLocator
      self.sourceRange = sourceRange
    }
  }

  package struct WordSpan: Codable, Sendable, Equatable {
    package var text: String
    package var startFrame: Int
    package var endFrame: Int
  }

  package struct SentenceTiming: Codable, Sendable, Equatable {
    package var text: String
    package var startFrame: Int
    package var endFrame: Int
    package var derivation: SentenceDerivation
    package var kind: UnitKind
    /// Engine-reported word spans inside the sentence, present when the
    /// derivation is word-based. Lets transcript fabrication emit
    /// word-granular entries the audits expect.
    package var words: [WordSpan]?

    package init(
      text: String, startFrame: Int, endFrame: Int,
      derivation: SentenceDerivation, kind: UnitKind, words: [WordSpan]? = nil
    ) {
      self.text = text
      self.startFrame = startFrame
      self.endFrame = endFrame
      self.derivation = derivation
      self.kind = kind
      self.words = words
    }
  }

  package var schemaVersion: Int
  package var jobKey: String
  package var chapterIndex: Int
  package var title: String
  package var sampleRate: Int
  package var headPauseFrames: Int
  package var artifactSHA256: String
  /// Source-archive document paths this chapter narrates, in reading order.
  /// Lets ReadAloud know which spine documents provably have no narration.
  package var sourceDocuments: [String]
  package var units: [UnitTiming]
  package var segments: [SegmentTiming]
  package var sentences: [SentenceTiming]

  package init(
    jobKey: String, chapterIndex: Int, title: String, sampleRate: Int,
    headPauseFrames: Int, artifactSHA256: String, sourceDocuments: [String],
    units: [UnitTiming], segments: [SegmentTiming], sentences: [SentenceTiming]
  ) {
    self.schemaVersion = Self.schemaVersion
    self.jobKey = jobKey
    self.chapterIndex = chapterIndex
    self.title = title
    self.sampleRate = sampleRate
    self.headPauseFrames = headPauseFrames
    self.artifactSHA256 = artifactSHA256
    self.sourceDocuments = sourceDocuments
    self.units = units
    self.segments = segments
    self.sentences = sentences
  }

  package init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
    jobKey = try container.decode(String.self, forKey: .jobKey)
    chapterIndex = try container.decode(Int.self, forKey: .chapterIndex)
    title = try container.decode(String.self, forKey: .title)
    sampleRate = try container.decode(Int.self, forKey: .sampleRate)
    headPauseFrames = try container.decode(Int.self, forKey: .headPauseFrames)
    artifactSHA256 = try container.decode(String.self, forKey: .artifactSHA256)
    sourceDocuments =
      try container.decodeIfPresent([String].self, forKey: .sourceDocuments) ?? []
    units = try container.decode([UnitTiming].self, forKey: .units)
    segments = try container.decodeIfPresent(
      [SegmentTiming].self, forKey: .segments) ?? []
    sentences = try container.decode([SentenceTiming].self, forKey: .sentences)
  }

  package enum TimingError: Error, LocalizedError, Equatable {
    case missingEngineTiming(unit: Int)
    case sentenceNotFound(unit: Int, sentence: Int)
    case sentenceNotAnchored(unit: Int, sentence: Int)
    case invalidEngineTiming(unit: Int)

    package var errorDescription: String? {
      switch self {
      case .missingEngineTiming(let unit):
        "synthesis unit \(unit + 1) returned no engine timing"
      case .sentenceNotFound(let unit, let sentence):
        "sentence \(sentence + 1) in synthesis unit \(unit + 1) could not be rebound to its input"
      case .sentenceNotAnchored(let unit, let sentence):
        "sentence \(sentence + 1) in synthesis unit \(unit + 1) has no engine timing anchor"
      case .invalidEngineTiming(let unit):
        "synthesis unit \(unit + 1) returned timing that cannot describe its sentences"
      }
    }
  }

  /// Derives fine-grained spans from validated anchors. When a private engine
  /// exposes no timing, preserves the exact synthesized utterance as one
  /// segment rather than inventing sentence boundaries. Speechless units
  /// contribute nothing.
  package static func deriveSentences(
    sentencesByUnit: [[String]], units: [UnitTiming],
    wordsByUnit: [[SpokenWordTiming]?] = [], sampleRate: Int = 48_000
  ) throws -> [SentenceTiming] {
    var result: [SentenceTiming] = []
    for (index, pair) in zip(units, sentencesByUnit).enumerated() {
      let (unit, unitSentences) = pair
      guard unit.kind != .speechlessSilence, unit.frameCount > 0 else { continue }
      guard index < wordsByUnit.count, let words = wordsByUnit[index], !words.isEmpty else {
        result.append(exactUnitSegment(unit))
        continue
      }
      do {
        result.append(
          contentsOf: try wordDerivedSentences(
            unitSentences.isEmpty ? [unit.text] : unitSentences,
            unitIndex: index, unit: unit, words: words, sampleRate: sampleRate))
      } catch TimingError.sentenceNotAnchored {
        result.append(exactUnitSegment(unit))
      }
    }
    return result
  }

  private static func exactUnitSegment(_ unit: UnitTiming) -> SentenceTiming {
    SentenceTiming(
      text: unit.text, startFrame: unit.startFrame,
      endFrame: unit.startFrame + unit.frameCount,
      derivation: .unit, kind: unit.kind)
  }

  /// Exact sentence boundaries from engine start anchors. Text for each
  /// anchor-to-anchor segment is sliced from the actual synthesized request;
  /// grouped private-engine events remain segments instead of pretending to
  /// be individual word timings.
  private static func wordDerivedSentences(
    _ sentences: [String], unitIndex: Int, unit: UnitTiming,
    words: [SpokenWordTiming],
    sampleRate: Int
  ) throws -> [SentenceTiming] {
    let request = unit.text as NSString
    var spans: [(start: Int, end: Int, text: String)] = []
    var searchStart = 0
    for (sentenceIndex, sentence) in sentences.enumerated() {
      let remaining = NSRange(location: searchStart, length: request.length - searchStart)
      let range = request.range(of: sentence, options: [], range: remaining)
      guard range.location != NSNotFound else {
        throw TimingError.sentenceNotFound(unit: unitIndex, sentence: sentenceIndex)
      }
      spans.append((range.location, NSMaxRange(range), sentence))
      searchStart = NSMaxRange(range)
    }

    let unitEnd = unit.startFrame + unit.frameCount
    var result: [SentenceTiming] = []
    for (index, span) in spans.enumerated() {
      let anchors = words.filter {
        $0.utf16Offset >= span.start && $0.utf16Offset < span.end
      }
      guard !anchors.isEmpty else {
        throw TimingError.sentenceNotAnchored(unit: unitIndex, sentence: index)
      }
      let sentenceStart = unit.startFrame
        + min(Int(anchors[0].startSeconds * Double(sampleRate)), unit.frameCount)
      let sentenceEnd: Int
      if index + 1 < spans.count {
        guard let next = words.first(where: {
          $0.utf16Offset >= spans[index + 1].start
            && $0.utf16Offset < spans[index + 1].end
        }) else {
          throw TimingError.sentenceNotAnchored(unit: unitIndex, sentence: index + 1)
        }
        sentenceEnd = unit.startFrame
          + min(Int(next.startSeconds * Double(sampleRate)), unit.frameCount)
      } else {
        sentenceEnd = unitEnd
      }
      guard sentenceEnd > sentenceStart else {
        throw TimingError.invalidEngineTiming(unit: unitIndex)
      }

      var timedSegments: [WordSpan] = []
      for (anchorIndex, anchor) in anchors.enumerated() {
        let textStart = anchorIndex == 0 ? span.start : anchor.utf16Offset
        let textEnd = anchorIndex + 1 < anchors.count
          ? anchors[anchorIndex + 1].utf16Offset : span.end
        guard textEnd > textStart else {
          throw TimingError.invalidEngineTiming(unit: unitIndex)
        }
        let segmentText = request.substring(
          with: NSRange(location: textStart, length: textEnd - textStart))
        let start = unit.startFrame
          + min(Int(anchor.startSeconds * Double(sampleRate)), unit.frameCount)
        let end = anchorIndex + 1 < anchors.count
          ? unit.startFrame
            + min(
              Int(anchors[anchorIndex + 1].startSeconds * Double(sampleRate)),
              unit.frameCount)
          : sentenceEnd
        guard end > start, !segmentText.isEmpty else {
          throw TimingError.invalidEngineTiming(unit: unitIndex)
        }
        timedSegments.append(
          WordSpan(text: segmentText, startFrame: start, endFrame: min(end, sentenceEnd)))
      }
      result.append(
        SentenceTiming(
          text: span.text, startFrame: sentenceStart, endFrame: sentenceEnd,
          derivation: .words, kind: unit.kind,
          words: timedSegments))
    }
    return result
  }

  package static func sha256(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
      hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }
}

/// The combined, digest-bound sidecar written next to the final M4B.
/// Sentence frames here are rebased to the final audiobook timeline via the
/// authoritative chapter-start math (packet sums minus encoder priming).
package struct BookSynthesisTimeline: Codable, Sendable {
  package static let schemaVersion = 3

  package struct Chapter: Codable, Sendable {
    package var index: Int
    package var title: String
    package var artifactSHA256: String
    package var startFrame: Int
    package var presentedFrames: Int
    /// Offset from the processed track's first presented frame to chapter
    /// timeline frame zero. The first M4B track is zero because the global
    /// edit list already removes its encoder priming.
    package var contentOffsetFrames: Int
    /// Source-archive document paths this chapter narrates. Empty for
    /// uncovered chapters (reused artifacts without timelines).
    package var sourceDocuments: [String]
    package var segments: [ChapterSynthesisTimeline.SegmentTiming]
    package var sentences: [ChapterSynthesisTimeline.SentenceTiming]

    package init(
      index: Int, title: String, artifactSHA256: String, startFrame: Int,
      presentedFrames: Int, contentOffsetFrames: Int, sourceDocuments: [String],
      segments: [ChapterSynthesisTimeline.SegmentTiming],
      sentences: [ChapterSynthesisTimeline.SentenceTiming]
    ) {
      self.index = index
      self.title = title
      self.artifactSHA256 = artifactSHA256
      self.startFrame = startFrame
      self.presentedFrames = presentedFrames
      self.contentOffsetFrames = contentOffsetFrames
      self.sourceDocuments = sourceDocuments
      self.segments = segments
      self.sentences = sentences
    }

    package init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      index = try container.decode(Int.self, forKey: .index)
      title = try container.decode(String.self, forKey: .title)
      artifactSHA256 = try container.decode(String.self, forKey: .artifactSHA256)
      startFrame = try container.decode(Int.self, forKey: .startFrame)
      presentedFrames = try container.decode(Int.self, forKey: .presentedFrames)
      contentOffsetFrames = try container.decode(Int.self, forKey: .contentOffsetFrames)
      sourceDocuments =
        try container.decodeIfPresent([String].self, forKey: .sourceDocuments) ?? []
      segments = try container.decodeIfPresent(
        [ChapterSynthesisTimeline.SegmentTiming].self, forKey: .segments) ?? []
      sentences = try container.decode(
        [ChapterSynthesisTimeline.SentenceTiming].self, forKey: .sentences)
    }
  }

  package var schemaVersion: Int
  package var generator: String
  package var jobKey: String
  package var fingerprint: String
  package var sourceEPUBSHA256: String
  package var m4bSHA256: String
  package var sampleRate: Int
  package var timelineCoverage: Double
  package var chapters: [Chapter]

  package init(
    jobKey: String, fingerprint: String, sourceEPUBSHA256: String,
    m4bSHA256: String, sampleRate: Int,
    timelineCoverage: Double, chapters: [Chapter]
  ) {
    self.schemaVersion = Self.schemaVersion
    self.generator = "spokenfolio-synthesis-timeline/3"
    self.jobKey = jobKey
    self.fingerprint = fingerprint
    self.sourceEPUBSHA256 = sourceEPUBSHA256
    self.m4bSHA256 = m4bSHA256
    self.sampleRate = sampleRate
    self.timelineCoverage = timelineCoverage
    self.chapters = chapters
  }

  package static func sidecarURL(for m4b: URL) -> URL {
    m4b.deletingPathExtension().appendingPathExtension("synthesis-timeline.json")
  }
}

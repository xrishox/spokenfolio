import CryptoKit
import Foundation
import PublicationKit
import TTSKit

/// Ground-truth narration timing captured during synthesis. The synthesizer
/// knows every emitted frame exactly (head pad, per-unit PCM, inserted
/// pauses), so unit spans are exact by construction; sentence spans inside a
/// multi-sentence unit are proportional interpolations until engine word
/// timings enrich them. All frame values are 48 kHz sample frames relative
/// to the start of the chapter artifact (head pad included).
package struct ChapterSynthesisTimeline: Codable, Sendable, Equatable {
  package static let schemaVersion = 1

  package enum UnitKind: String, Codable, Sendable {
    case prose
    case announcement
    case speechlessSilence
  }

  package enum SentenceDerivation: String, Codable, Sendable {
    case unit
    case words
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

  package struct SentenceTiming: Codable, Sendable, Equatable {
    package var text: String
    package var startFrame: Int
    package var endFrame: Int
    package var derivation: SentenceDerivation
    package var kind: UnitKind
  }

  package var schemaVersion: Int
  package var jobKey: String
  package var chapterIndex: Int
  package var title: String
  package var sampleRate: Int
  package var headPauseFrames: Int
  package var artifactSHA256: String
  package var units: [UnitTiming]
  package var sentences: [SentenceTiming]

  package init(
    jobKey: String, chapterIndex: Int, title: String, sampleRate: Int,
    headPauseFrames: Int, artifactSHA256: String,
    units: [UnitTiming], sentences: [SentenceTiming]
  ) {
    self.schemaVersion = Self.schemaVersion
    self.jobKey = jobKey
    self.chapterIndex = chapterIndex
    self.title = title
    self.sampleRate = sampleRate
    self.headPauseFrames = headPauseFrames
    self.artifactSHA256 = artifactSHA256
    self.units = units
    self.sentences = sentences
  }

  /// Sentence spans from unit spans: a unit whose text equals one sentence
  /// maps exactly; a unit packing several sentences interpolates their
  /// boundaries proportionally by character count. Announcement units
  /// contribute announcement-kind sentences so downstream consumers can
  /// account for audio that has no EPUB text.
  package static func deriveSentences(
    sentencesByUnit: [[String]], units: [UnitTiming],
    wordsByUnit: [[SpokenWordTiming]?] = [], sampleRate: Int = 48_000
  ) -> [SentenceTiming] {
    var result: [SentenceTiming] = []
    for (index, pair) in zip(units, sentencesByUnit).enumerated() {
      let (unit, unitSentences) = pair
      guard unit.kind != .speechlessSilence, unit.frameCount > 0 else { continue }
      if unitSentences.count > 1,
        index < wordsByUnit.count, let words = wordsByUnit[index], !words.isEmpty,
        let derived = wordDerivedSentences(
          unitSentences, unit: unit, words: words, sampleRate: sampleRate)
      {
        result.append(contentsOf: derived)
        continue
      }
      if unitSentences.count <= 1 {
        result.append(
          SentenceTiming(
            text: unitSentences.first ?? unit.text,
            startFrame: unit.startFrame,
            endFrame: unit.startFrame + unit.frameCount,
            derivation: .unit,
            kind: unit.kind))
        continue
      }
      let totalCharacters = unitSentences.reduce(0) { $0 + $1.count }
        + max(0, unitSentences.count - 1)  // joining spaces
      var characterCursor = 0
      for sentence in unitSentences {
        let start = unit.startFrame
          + Int(Double(unit.frameCount) * Double(characterCursor) / Double(max(1, totalCharacters)))
        characterCursor += sentence.count + 1
        let end = unit.startFrame
          + Int(Double(unit.frameCount) * Double(min(characterCursor, totalCharacters))
            / Double(max(1, totalCharacters)))
        result.append(
          SentenceTiming(
            text: sentence, startFrame: start, endFrame: end,
            derivation: .interpolated, kind: unit.kind))
      }
    }
    return result
  }

  /// Exact sentence boundaries from engine word timings: the engine reports
  /// UTF-16 ranges into the unit text it spoke, and the planner joins
  /// sentences with single spaces, so each sentence's UTF-16 span is exact.
  /// A sentence starts at the first word timing at or past its span start;
  /// it ends where the next sentence starts. Returns nil when the timings
  /// don't cover the sentence starts (engine payload change or truncation),
  /// so the caller falls back to interpolation honestly.
  private static func wordDerivedSentences(
    _ sentences: [String], unit: UnitTiming, words: [SpokenWordTiming],
    sampleRate: Int
  ) -> [SentenceTiming]? {
    var spans: [(start: Int, text: String)] = []
    var offset = 0
    for sentence in sentences {
      spans.append((offset, sentence))
      offset += sentence.utf16.count + 1  // joining space
    }
    guard let lastWord = words.last,
      lastWord.startSeconds * Double(sampleRate) <= Double(unit.frameCount) + Double(sampleRate)
    else { return nil }

    var startFrames: [Int] = []
    for span in spans {
      guard let word = words.first(where: { $0.utf16Offset + $0.utf16Length > span.start })
      else { return nil }
      let frame = unit.startFrame
        + min(Int(word.startSeconds * Double(sampleRate)), unit.frameCount)
      startFrames.append(frame)
    }
    guard startFrames == startFrames.sorted() else { return nil }
    var result: [SentenceTiming] = []
    for (index, span) in spans.enumerated() {
      let end = index + 1 < startFrames.count
        ? startFrames[index + 1]
        : unit.startFrame + unit.frameCount
      guard end > startFrames[index] else { return nil }
      result.append(
        SentenceTiming(
          text: span.text, startFrame: startFrames[index], endFrame: end,
          derivation: .words, kind: unit.kind))
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
  package static let schemaVersion = 1

  package struct Chapter: Codable, Sendable {
    package var index: Int
    package var title: String
    package var artifactSHA256: String
    package var startFrame: Int
    package var presentedFrames: Int
    /// This chapter's own AAC encoder priming: its packets begin with this
    /// many non-content frames, so in-track sentence times shift by it.
    package var leadingFrames: Int
    package var sentences: [ChapterSynthesisTimeline.SentenceTiming]
  }

  package var schemaVersion: Int
  package var generator: String
  package var jobKey: String
  package var fingerprint: String
  package var m4bSHA256: String
  package var sampleRate: Int
  package var timelineCoverage: Double
  package var chapters: [Chapter]

  package init(
    jobKey: String, fingerprint: String, m4bSHA256: String, sampleRate: Int,
    timelineCoverage: Double, chapters: [Chapter]
  ) {
    self.schemaVersion = Self.schemaVersion
    self.generator = "spokenfolio-synthesis-timeline/1"
    self.jobKey = jobKey
    self.fingerprint = fingerprint
    self.m4bSHA256 = m4bSHA256
    self.sampleRate = sampleRate
    self.timelineCoverage = timelineCoverage
    self.chapters = chapters
  }

  package static func sidecarURL(for m4b: URL) -> URL {
    m4b.deletingPathExtension().appendingPathExtension("synthesis-timeline.json")
  }
}

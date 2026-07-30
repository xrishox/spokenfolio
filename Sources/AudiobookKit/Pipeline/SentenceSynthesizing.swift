import Foundation
import PublicationKit
import TTSKit

/// The synthesis seam between the pipeline and a selected local backend.
/// Tests inject a mock; application composition supplies the real session.
package protocol NarrationSynthesizing: Sendable {
  /// Returns one complete, explicitly described PCM utterance. The selected
  /// backend/model/voice belongs to the injected synthesizer, not this pipeline.
  func synthesize(text: String) async throws -> PCM16Audio
  /// Audio plus the backend's ground-truth word timings when available.
  func synthesizeDetailed(
    text: String
  ) async throws -> (audio: PCM16Audio, timings: [SpokenWordTiming]?)
}

extension NarrationSynthesizing {
  package func synthesizeDetailed(
    text: String
  ) async throws -> (audio: PCM16Audio, timings: [SpokenWordTiming]?) {
    (try await synthesize(text: text), nil)
  }
}

enum SilencePCM {
  /// Zeroed PCM16 mono frames — digital silence.
  static func data(seconds: Double, sampleRate: Int) -> Data {
    let frames = Int((seconds * Double(sampleRate)).rounded())
    guard frames > 0 else { return Data() }
    return Data(count: frames * MemoryLayout<Int16>.size)
  }
}

/// Very long sentences (run-on prose or tables flattened to text) are split
/// at clause boundaries before they cross a backend request limit.
package enum SentenceLimiter {
  package static func split(_ sentence: String, limit: Int = 1_000) -> [String] {
    guard sentence.count > limit else { return [sentence] }

    let midpoint = sentence.index(sentence.startIndex, offsetBy: sentence.count / 2)
    let clauseBoundaries: Set<Character> = [",", ";", ":", "—", "–"]

    var best: String.Index?
    var cursor = sentence.startIndex
    while cursor < sentence.endIndex {
      if clauseBoundaries.contains(sentence[cursor]) {
        if let currentBest = best {
          if abs(sentence.distance(from: cursor, to: midpoint))
            < abs(sentence.distance(from: currentBest, to: midpoint))
          {
            best = cursor
          }
        } else {
          best = cursor
        }
      }
      cursor = sentence.index(after: cursor)
    }

    let splitIndex: String.Index
    if let best, best > sentence.startIndex, best < sentence.index(before: sentence.endIndex) {
      splitIndex = sentence.index(after: best)
    } else if let space = nearestWhitespace(in: sentence, around: midpoint) {
      splitIndex = space
    } else {
      splitIndex = midpoint
    }

    let head = String(sentence[..<splitIndex]).trimmingCharacters(in: .whitespaces)
    let tail = String(sentence[splitIndex...]).trimmingCharacters(in: .whitespaces)
    var result: [String] = []
    if !head.isEmpty { result.append(contentsOf: split(head, limit: limit)) }
    if !tail.isEmpty { result.append(contentsOf: split(tail, limit: limit)) }
    return result.isEmpty ? [sentence] : result
  }

  private static func nearestWhitespace(
    in text: String, around target: String.Index
  ) -> String.Index? {
    var forward = target
    var backward = target
    while forward < text.endIndex || backward > text.startIndex {
      if forward < text.endIndex, text[forward].isWhitespace { return forward }
      if backward > text.startIndex {
        backward = text.index(before: backward)
        if text[backward].isWhitespace { return backward }
      }
      if forward < text.endIndex { forward = text.index(after: forward) }
    }
    return nil
  }

  /// Bisect a request that the backend has already rejected. Prefer a clause
  /// boundary, then whitespace nearest the midpoint. Both returned pieces
  /// must still contain speech so punctuation is never submitted alone.
  package static func bisectRejected(_ text: String) -> [String] {
    guard text.count > 1 else { return [text] }
    let midpoint = text.index(text.startIndex, offsetBy: text.count / 2)
    let clauseBoundaries: Set<Character> = [",", ";", ":", "—", "–"]

    var clauseCandidates: [String.Index] = []
    var whitespaceCandidates: [String.Index] = []
    var cursor = text.startIndex
    while cursor < text.endIndex {
      if clauseBoundaries.contains(text[cursor]) {
        clauseCandidates.append(text.index(after: cursor))
      } else if text[cursor].isWhitespace {
        whitespaceCandidates.append(cursor)
      }
      cursor = text.index(after: cursor)
    }

    func distance(_ index: String.Index) -> Int {
      abs(text.distance(from: index, to: midpoint))
    }
    func pieces(at index: String.Index) -> [String]? {
      let head = String(text[..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
      let tail = String(text[index...]).trimmingCharacters(in: .whitespacesAndNewlines)
      guard !head.isEmpty, !tail.isEmpty, isSpeakable(head), isSpeakable(tail) else {
        return nil
      }
      return [head, tail]
    }

    for index in clauseCandidates.sorted(by: { distance($0) < distance($1) }) {
      if let result = pieces(at: index) { return result }
    }
    for index in whitespaceCandidates.sorted(by: { distance($0) < distance($1) }) {
      if let result = pieces(at: index) { return result }
    }
    return [text]
  }

  private static func isSpeakable(_ text: String) -> Bool {
    text.unicodeScalars.contains {
      $0.properties.isAlphabetic || $0.properties.numericType != nil
    }
  }
}

/// The single source of truth for audiobook request sizing. Ordinary
/// paragraphs stay intact; pathological run-ons are split deterministically
/// before they can exceed the worker IPC frame.
package enum NarrationUnitGranularity: String, Codable, Sendable {
  case paragraph
  case sentence
}

package enum NarrationUnitPlanner {
  package static let maximumCharacters = 4_000
  package static let synthesisPolicyVersion = 8

  /// True when the text has no Unicode letter and no numeric character:
  /// nothing the engine could put into words. Only such units are eligible
  /// for the silence fallback when the engine refuses them — decoration like
  /// a scene-break "—" or a fill-in rule "____". Numeric covers Nd/Nl/No, so
  /// "Ⅻ" and "½" remain speakable and are never eligible.
  package static func isSpeechless(_ text: String) -> Bool {
    !text.unicodeScalars.contains {
      $0.properties.isAlphabetic || $0.properties.numericType != nil
    }
  }

  package struct Unit: Sendable, Equatable {
    package let text: String
    package let sourceLocator: SourceLocator?
    package let sourceRange: SourceTextRange?
  }

  package static func units(for paragraph: NarrationParagraph) -> [Unit] {
    units(for: paragraph, granularity: .paragraph)
  }

  package static func units(
    for paragraph: NarrationParagraph, granularity: NarrationUnitGranularity
  ) -> [Unit] {
    let boundedSentences = paragraph.sentences.flatMap {
      SentenceLimiter.split($0, limit: maximumCharacters)
    }
    if granularity == .sentence {
      return locatedUnits(
        boundedSentences.filter { !$0.isEmpty }, paragraph: paragraph)
    }
    var chunks: [String] = []
    var current = ""
    for piece in boundedSentences where !piece.isEmpty {
      if current.isEmpty {
        current = piece
      } else if current.count + 1 + piece.count <= maximumCharacters {
        current += " " + piece
      } else {
        chunks.append(current)
        current = piece
      }
    }
    if !current.isEmpty { chunks.append(current) }
    return locatedUnits(chunks, paragraph: paragraph)
  }

  private static func locatedUnits(
    _ chunks: [String], paragraph: NarrationParagraph
  ) -> [Unit] {
    guard let source = paragraph.sourceText, paragraph.sourceLocator != nil else {
      return chunks.map {
        Unit(text: $0, sourceLocator: paragraph.sourceLocator, sourceRange: nil)
      }
    }
    let value = source as NSString
    var cursor = 0
    return chunks.map { chunk in
      let remaining = NSRange(location: cursor, length: max(0, value.length - cursor))
      let found = value.range(of: chunk, options: [], range: remaining)
      let range =
        found.location == NSNotFound
        ? nil : SourceTextRange(location: found.location, length: found.length)
      if found.location != NSNotFound { cursor = NSMaxRange(found) }
      return Unit(text: chunk, sourceLocator: paragraph.sourceLocator, sourceRange: range)
    }
  }

  package static func chunks(for paragraph: NarrationParagraph) -> [String] {
    units(for: paragraph).map(\.text)
  }

  package static func maximumUnitCharacters(in plan: AudiobookPlan) -> Int {
    maximumUnitCharacters(in: plan, granularity: .paragraph)
  }

  package static func maximumUnitCharacters(
    in plan: AudiobookPlan, granularity: NarrationUnitGranularity
  ) -> Int {
    plan.chapters.flatMap(\.allParagraphs).flatMap {
      units(for: $0, granularity: granularity)
    }.map(\.text.count).max() ?? 0
  }

  package static func deadlineSeconds(maximumUnitCharacters: Int) -> Double {
    min(300, max(60, ceil(Double(maximumUnitCharacters) / 8)))
  }
}

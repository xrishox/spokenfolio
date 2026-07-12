import Foundation
import SiriTTSCore

/// The synthesis seam between the pipeline and an engine. Tests inject a
/// mock; production adapts a dedicated SiriWorkerPool.
package protocol SentenceSynthesizing: Sendable {
  /// Returns raw PCM16-LE mono audio for one sentence.
  func synthesize(text: String, voiceID: String) async throws -> Data
}

package struct WorkerPoolSynthesizer: SentenceSynthesizing {
  private let pool: SiriWorkerPool

  package init(pool: SiriWorkerPool) {
    self.pool = pool
  }

  package func synthesize(text: String, voiceID: String) async throws -> Data {
    // Units are whole paragraphs: the engine receives each as ONE utterance
    // and paces sentence transitions itself (measured: better prosody flow,
    // throughput-neutral).
    try await pool.synthesize(text: text, voiceID: voiceID, splitSentencesInWorker: false)
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

/// The private Siri engine handles sentence-sized requests; very long
/// sentences (run-on prose, tables flattened to text) are split at clause
/// boundaries before synthesis.
package enum SentenceLimiter {
  package static func split(_ sentence: String, limit: Int = 1_000) -> [String] {
    guard sentence.count > limit else { return [sentence] }

    let midpoint = sentence.index(sentence.startIndex, offsetBy: sentence.count / 2)
    let clauseBoundaries: Set<Character> = [",", ";", ":", "—", "–"]

    var best: String.Index?
    var cursor = sentence.startIndex
    while cursor < sentence.endIndex {
      if clauseBoundaries.contains(sentence[cursor]) {
        if best == nil {
          best = cursor
        } else if abs(sentence.distance(from: cursor, to: midpoint))
          < abs(sentence.distance(from: best!, to: midpoint))
        {
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
}

/// The single source of truth for audiobook request sizing. Ordinary
/// paragraphs stay intact; pathological run-ons are split deterministically
/// before they can exceed the worker IPC frame.
package enum NarrationUnitPlanner {
  package static let maximumCharacters = 4_000
  package static let synthesisPolicyVersion = 1

  package static func chunks(for paragraph: NarrationParagraph) -> [String] {
    let boundedSentences = paragraph.sentences.flatMap {
      SentenceLimiter.split($0, limit: maximumCharacters)
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
    return chunks
  }

  package static func maximumUnitCharacters(in plan: AudiobookPlan) -> Int {
    plan.chapters.flatMap(\.allParagraphs).flatMap(chunks(for:)).map(\.count).max() ?? 0
  }

  package static func deadlineSeconds(maximumUnitCharacters: Int) -> Double {
    min(300, max(60, ceil(Double(maximumUnitCharacters) / 8)))
  }
}

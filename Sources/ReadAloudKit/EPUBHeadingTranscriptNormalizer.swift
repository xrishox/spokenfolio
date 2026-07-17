import EPUBKit
import Foundation

package struct EPUBHeadingTranscriptNormalizer: Sendable {
  package struct Result: Sendable, Equatable {
    package var transcript: StalignTranscript
    package var repairCount: Int
  }

  private let candidates: [[String]]

  package init(sourceEPUB: URL) throws {
    let publication = try EPUBImporter().load(url: sourceEPUB)
    var values: [String] = publication.navigation.map(\.title)
    for section in publication.sections where [.part, .chapter].contains(section.role) {
      values.append(section.title)
      let text = section.blocks.map(\.text).joined(separator: " ")
      if Self.tokens(text).count <= 32 { values.append(text) }
    }
    candidates = Self.canonicalCandidates(values)
  }

  package init(candidates: [String]) {
    self.candidates = Self.canonicalCandidates(candidates)
  }

  package func normalize(_ value: StalignTranscript, audioDuration: Double) -> Result {
    guard audioDuration <= 30, value.timeline.count >= 2, value.timeline.count <= 32,
      let first = value.timeline.first, let roman = Self.romanValue(first.text),
      (1...100).contains(roman)
    else { return .init(transcript: value, repairCount: 0) }
    let spokenRemainder = value.timeline.dropFirst().flatMap { Self.tokens($0.text) }
    let matches = candidates.filter { candidate in
      guard candidate.count >= 3, Self.labels.contains(candidate[0]),
        Self.numberValue(candidate[1]) == roman
      else { return false }
      return Array(candidate.dropFirst(2)) == spokenRemainder
    }
    guard matches.count == 1, let label = matches[0].first else {
      return .init(transcript: value, repairCount: 0)
    }
    var entries = value.timeline
    entries[0].type = "segment"
    entries[0].text = label.prefix(1).uppercased() + label.dropFirst() + " \(roman)."
    return .init(transcript: StalignTranscript(timedEntries: entries), repairCount: 1)
  }

  private static let labels: Set<String> = ["part", "book", "chapter"]

  private static func canonicalCandidates(_ values: [String]) -> [[String]] {
    Array(Set(values.map(tokens).filter { $0.count >= 3 && $0.count <= 32 }))
  }

  private static func tokens(_ text: String) -> [String] {
    text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      .lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
  }

  private static func numberValue(_ text: String) -> Int? {
    if let number = Int(text) { return number }
    return wordNumbers[text] ?? romanValue(text)
  }

  private static func romanValue(_ text: String) -> Int? {
    let value = text.uppercased().trimmingCharacters(in: .punctuationCharacters)
    guard !value.isEmpty, value.allSatisfy({ "IVXLCDM".contains($0) }) else { return nil }
    let numbers: [Character: Int] = [
      "I": 1, "V": 5, "X": 10, "L": 50, "C": 100, "D": 500, "M": 1_000,
    ]
    var total = 0
    var previous = 0
    for character in value.reversed() {
      guard let current = numbers[character] else { return nil }
      if current < previous { total -= current } else { total += current; previous = current }
    }
    return total > 0 ? total : nil
  }

  private static let wordNumbers: [String: Int] = [
    "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
    "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12,
    "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
    "seventeen": 17, "eighteen": 18, "nineteen": 19, "twenty": 20,
  ]
}

import EPUBKit
import Foundation
import PublicationKit

/// Book-derived vocabulary hints for speech recognition. A term qualifies
/// when it appears capitalized and its lowercase form never occurs in the
/// book — the signal a narrator uses when pre-reading a book to learn its
/// proper names. Purely mechanical and book-agnostic: the hints come from
/// the text being narrated, never from a hard-coded list.
package enum BookVocabulary {
  package static let maximumTerms = 1_000

  package static func terms(sourceEPUB: URL) -> [String] {
    guard let publication = try? EPUBImporter().load(url: sourceEPUB) else { return [] }
    let text = publication.sections
      .filter { $0.readingOrder == .primary }
      .flatMap(\.blocks).map(\.text).joined(separator: "\n")
    return terms(in: text)
  }

  package static func terms(in text: String) -> [String] {
    var lowercase = Set<String>()
    var capitalized: [String: Int] = [:]
    for raw in text.split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "’" }) {
      var token = String(raw)
      for suffix in ["'s", "’s"] where token.hasSuffix(suffix) {
        token = String(token.dropLast(2))
      }
      token = token.trimmingCharacters(in: CharacterSet(charactersIn: "'’"))
      guard token.count >= 3, let first = token.first else { continue }
      if first.isUppercase {
        capitalized[token, default: 0] += 1
      } else {
        lowercase.insert(token.lowercased())
      }
    }
    return
      capitalized
      .filter { !lowercase.contains($0.key.lowercased()) }
      .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
      .prefix(maximumTerms)
      .map(\.key)
  }
}

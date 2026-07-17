import Foundation

/// Decides whether a chapter's TOC title is spoken and which leading body
/// paragraphs it absorbs.
///
/// The two reference shapes: Three-Body chapter text already opens with
/// number, title, and setting — the announcement is skipped. Mistborn titles
/// exist only in the TOC and the body opens with a bare number — the title
/// is announced and the bare-number paragraph absorbed so the listener hears
/// "Chapter 1." exactly once.
enum TitleAnnouncement {
  struct Decision: Equatable {
    let announce: Bool
    /// Leading body paragraphs subsumed by the announcement.
    let absorbedParagraphCount: Int
  }

  nonisolated(unsafe) private static let titleShape =
    /^\s*(?:(?:chapter|part|book|prologue|epilogue)\b[\s.:\-–—]*)?(?:[0-9]+|[ivxlcdm]+\b)?[\s.:\-–—]*(.*)$/
    .ignoresCase()

  static func decide(title: String, bodyParagraphs: [String]) -> Decision {
    let normalizedTitle = normalize(title)
    guard !normalizedTitle.isEmpty else {
      return Decision(announce: false, absorbedParagraphCount: 0)
    }

    let opening = Array(bodyParagraphs.prefix(3))
    let progressive = opening.indices.map {
      normalize(opening[...$0].joined(separator: " "))
    }

    // Only a complete leading heading may suppress an announcement. Substring
    // containment destroys short real prose (for example title "Night" and
    // paragraph "I") and is intentionally never used here.
    if hasEnoughSignal(normalizedTitle), progressive.contains(normalizedTitle) {
      return Decision(announce: false, absorbedParagraphCount: 0)
    }
    if let match = title.wholeMatch(of: titleShape) {
      let rest = normalize(String(match.1))
      if hasEnoughSignal(rest), opening.map(normalize).contains(rest) {
        return Decision(announce: false, absorbedParagraphCount: 0)
      }
    }

    // Announce, absorbing leading paragraphs the title already covers
    // (e.g. the bare "1" heading when the title is "Chapter 1").
    let first = bodyParagraphs.first.map(normalize) ?? ""
    let absorbed = shouldAbsorbLeadingHeading(
      first, normalizedTitle: normalizedTitle, rawTitle: title) ? 1 : 0
    return Decision(announce: true, absorbedParagraphCount: absorbed)
  }

  private static func shouldAbsorbLeadingHeading(
    _ paragraph: String, normalizedTitle: String, rawTitle: String
  ) -> Bool {
    guard !paragraph.isEmpty else { return false }
    if paragraph == normalizedTitle { return true }
    guard let match = rawTitle.wholeMatch(of: titleShape) else { return false }
    let structuralPrefix = rawTitle.prefix(upTo: match.1.startIndex)
    let prefix = normalize(String(structuralPrefix))
    guard prefix.hasPrefix("chapter") || prefix.hasPrefix("part") || prefix.hasPrefix("book")
    else { return false }
    let titleWords = normalizedWords(rawTitle)
    guard titleWords.count >= 2 else { return false }
    return paragraph == titleWords[1]
      && titleWords[1].allSatisfy { $0.isNumber || "ivxlcdm".contains($0.lowercased()) }
  }

  private static func hasEnoughSignal(_ normalized: String) -> Bool {
    normalized.count >= 4
      || (normalized.count >= 2 && normalized.unicodeScalars.contains { $0.value > 0x7F })
  }

  private static func normalizedWords(_ text: String) -> [String] {
    let folded = text.decomposedStringWithCompatibilityMapping
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    var words: [String] = []
    var current = String.UnicodeScalarView()
    for scalar in folded.unicodeScalars {
      if CharacterSet.alphanumerics.contains(scalar) {
        current.append(scalar)
      } else if !current.isEmpty {
        words.append(String(current))
        current = String.UnicodeScalarView()
      }
    }
    if !current.isEmpty { words.append(String(current)) }
    return words
  }

  /// Compatibility fold → lowercase → retain every Unicode letter/number.
  /// Separators are removed for stable heading equality, but non-Latin titles
  /// remain meaningful instead of normalizing to an empty string.
  static func normalize(_ text: String) -> String {
    normalizedWords(text).joined()
  }
}

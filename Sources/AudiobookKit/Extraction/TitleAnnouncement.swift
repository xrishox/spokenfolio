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

    let window = String(
      normalize(bodyParagraphs.prefix(3).joined(separator: " ")).prefix(400))

    // Containment needs enough signal to mean anything: a bare "1" or roman
    // "I" title matches almost any prose, which would suppress announcements
    // erratically. Short titles are announced and rely on absorption.
    if normalizedTitle.count >= 4, window.contains(normalizedTitle) {
      return Decision(announce: false, absorbedParagraphCount: 0)
    }
    if let match = title.wholeMatch(of: titleShape) {
      let rest = normalize(String(match.1))
      if rest.count >= 4, window.contains(rest) {
        return Decision(announce: false, absorbedParagraphCount: 0)
      }
    }

    // Announce, absorbing leading paragraphs the title already covers
    // (e.g. the bare "1" heading when the title is "Chapter 1").
    var absorbed = 0
    for paragraph in bodyParagraphs {
      let normalized = normalize(paragraph)
      guard !normalized.isEmpty, normalizedTitle.contains(normalized) else { break }
      absorbed += 1
    }
    return Decision(announce: true, absorbedParagraphCount: absorbed)
  }

  /// NFKD → lowercase → keep only [a-z0-9]. Decomposition runs first because
  /// compatibility mappings can introduce new uppercase letters ("№" → "No").
  static func normalize(_ text: String) -> String {
    let decomposed = text.decomposedStringWithCompatibilityMapping.lowercased()
    return String(decomposed.unicodeScalars.filter { scalar in
      ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar)
    })
  }
}

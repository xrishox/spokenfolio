import Foundation

package struct NarrationParagraph: Sendable, Equatable {
  package let sentences: [String]

  package init(sentences: [String]) {
    self.sentences = sentences
  }

  package var characterCount: Int {
    sentences.reduce(0) { $0 + $1.count }
  }
}

/// One audiobook chapter ready for synthesis: an optional spoken title
/// announcement followed by body paragraphs in reading order.
package struct NarrationChapter: Sendable, Equatable {
  package let title: String
  /// The spoken announcement paragraph, present only when the title should
  /// be read aloud (never for synthetic titles; suppressed by dedupe when the
  /// body already opens with the title).
  package let announcement: NarrationParagraph?
  package let paragraphs: [NarrationParagraph]
  package let spineIndices: [Int]

  package init(
    title: String, announcement: NarrationParagraph?,
    paragraphs: [NarrationParagraph], spineIndices: [Int]
  ) {
    self.title = title
    self.announcement = announcement
    self.paragraphs = paragraphs
    self.spineIndices = spineIndices
  }

  package var allParagraphs: [NarrationParagraph] {
    (announcement.map { [$0] } ?? []) + paragraphs
  }

  package var characterCount: Int {
    allParagraphs.reduce(0) { $0 + $1.characterCount }
  }
}

/// What a spine item is, for the default include/exclude policy.
package enum SectionRole: String, Sendable, CaseIterable {
  case cover
  case titlePage = "title-page"
  case copyright
  case printedTOC = "printed-toc"
  case dedication
  case epigraph
  case acknowledgments
  case foreword
  case preface
  case prologue
  case part
  case chapter
  case epilogue
  case afterword
  case notes
  case appendix
  case glossary
  case bibliography
  case index
  case aboutAuthor = "about-author"
  case alsoBy = "also-by"
  case excerpt
  case unknown

  /// Only these are excluded by default. Everything else — including
  /// `unknown` — is narrated, so unclassified prose is never silently lost.
  package var includedByDefault: Bool {
    switch self {
    case .cover, .titlePage, .copyright, .printedTOC, .index, .notes,
      .aboutAuthor, .alsoBy, .excerpt:
      false
    default:
      true
    }
  }
}

/// One spine item's classification, shown by the `chapters` dry run and
/// toggled by section overrides. `slug` is stable for a given book. After
/// planning, `included` reflects what is actually narrated — an item inside
/// an excluded chapter's range reads false even when its own default was
/// true.
package struct SectionInfo: Sendable, Equatable {
  package let spineIndex: Int
  package let role: SectionRole
  package let title: String
  package let slug: String
  package let characterCount: Int
  package let includedByDefault: Bool
  package var included: Bool
  /// True only when the user named this section in an include override;
  /// such sections are narrated even inside an excluded chapter's range.
  package var explicitlyIncluded = false
}

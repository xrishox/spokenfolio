import Foundation
import PublicationKit

package struct NarrationParagraph: Sendable, Equatable {
  package let sentences: [String]
  package let sourceLocator: SourceLocator?
  /// Exact normalized block text from which `sentences` were sliced.
  package let sourceText: String?

  package init(
    sentences: [String], sourceLocator: SourceLocator? = nil, sourceText: String? = nil
  ) {
    self.sentences = sentences
    self.sourceLocator = sourceLocator
    self.sourceText = sourceText
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
  package let sectionIDs: [String]

  package init(
    title: String, announcement: NarrationParagraph?,
    paragraphs: [NarrationParagraph], sectionIDs: [String]
  ) {
    self.title = title
    self.announcement = announcement
    self.paragraphs = paragraphs
    self.sectionIDs = sectionIDs
  }

  package var allParagraphs: [NarrationParagraph] {
    (announcement.map { [$0] } ?? []) + paragraphs
  }

  package var characterCount: Int {
    allParagraphs.reduce(0) { $0 + $1.characterCount }
  }
}

/// One source section's classification, shown by the `chapters` dry run and
/// toggled by section overrides. `slug` is stable for a given book. After
/// planning, `included` reflects what is actually narrated — an item inside
/// an excluded chapter's range reads false even when its own default was
/// true.
package struct SectionInfo: Sendable, Equatable {
  package let id: String
  package let index: Int
  package let role: SectionRole
  package let title: String
  package let slug: String
  package let characterCount: Int
  package let includedByDefault: Bool
  package var included: Bool
  /// True only when the user named this section in an include override;
  /// such sections are narrated even inside an excluded chapter's range.
  package var explicitlyIncluded = false

  package init(
    id: String, index: Int, role: SectionRole, title: String, slug: String,
    characterCount: Int, includedByDefault: Bool, included: Bool,
    explicitlyIncluded: Bool = false
  ) {
    self.id = id
    self.index = index
    self.role = role
    self.title = title
    self.slug = slug
    self.characterCount = characterCount
    self.includedByDefault = includedByDefault
    self.included = included
    self.explicitlyIncluded = explicitlyIncluded
  }
}

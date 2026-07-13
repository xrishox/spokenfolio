import Foundation
import PublicationKit
import TTSKit

package struct PlanOptions: Sendable, Equatable {
  package var announceTitles = true
  /// Section overrides: source indices ("7") or displayed slugs.
  /// Includes are applied before excludes.
  package var includeSections: [String] = []
  package var excludeSections: [String] = []
  package var maxChapters: Int?

  package init() {}
}

package struct AudiobookPlan: Sendable {
  package let sourceFormat: String
  package let importerVersion: Int
  package let metadata: PublicationMetadata
  package let cover: PublicationCover?
  package let sections: [SectionInfo]
  package let chapters: [NarrationChapter]
  package let warnings: [String]

  package var totalCharacterCount: Int {
    chapters.reduce(0) { $0 + $1.characterCount }
  }

  package var maxUnitCharacterCount: Int {
    NarrationUnitPlanner.maximumUnitCharacters(in: self)
  }
}

package enum AudiobookPlanError: Error, LocalizedError {
  case noNarratableContent
  case unknownSection(String)

  package var errorDescription: String? {
    switch self {
    case .noNarratableContent:
      "No narratable text remains after section selection."
    case .unknownSection(let token):
      "Unknown section '\(token)' (use a section index or slug from the chapters listing)."
    }
  }
}

package enum AudiobookPlanner {
  package static func plan(
    publication: Publication, options: PlanOptions = PlanOptions()
  ) throws -> AudiobookPlan {
    var sections = makeSectionInfo(publication.sections)
    try applyOverrides(&sections, options: options)
    let chapters = buildChapters(
      publication: publication, sections: sections, options: options)
    guard !chapters.isEmpty else { throw AudiobookPlanError.noNarratableContent }
    let limited = options.maxChapters.map { Array(chapters.prefix($0)) } ?? chapters

    let narrated = Set(limited.flatMap(\.sectionIDs))
    for index in sections.indices where sections[index].included {
      if !narrated.contains(sections[index].id) { sections[index].included = false }
    }
    return AudiobookPlan(
      sourceFormat: publication.sourceFormat,
      importerVersion: publication.importerVersion,
      metadata: publication.metadata,
      cover: publication.cover,
      sections: sections,
      chapters: limited,
      warnings: publication.warnings)
  }

  private static func makeSectionInfo(_ source: [PublicationSection]) -> [SectionInfo] {
    var usedSlugs: Set<String> = []
    return source.map { section in
      let slug = uniqueSlug(for: section.title, index: section.index, used: &usedSlugs)
      return SectionInfo(
        id: section.id,
        index: section.index,
        role: section.role,
        title: section.title,
        slug: slug,
        characterCount: section.blocks.reduce(0) { $0 + $1.text.count },
        includedByDefault: section.role.includedByDefault,
        included: section.role.includedByDefault)
    }
  }

  private static func applyOverrides(
    _ sections: inout [SectionInfo], options: PlanOptions
  ) throws {
    func indices(for token: String) throws -> [Int] {
      let matches = sections.indices.filter {
        String(sections[$0].index) == token || sections[$0].slug == token
      }
      guard !matches.isEmpty else { throw AudiobookPlanError.unknownSection(token) }
      return matches
    }
    for token in options.includeSections {
      for index in try indices(for: token) {
        sections[index].included = true
        sections[index].explicitlyIncluded = true
      }
    }
    for token in options.excludeSections {
      for index in try indices(for: token) {
        sections[index].included = false
        sections[index].explicitlyIncluded = false
      }
    }
  }

  private struct Position: Comparable, Hashable {
    let section: Int
    let block: Int

    static func < (lhs: Position, rhs: Position) -> Bool {
      lhs.section == rhs.section ? lhs.block < rhs.block : lhs.section < rhs.section
    }
  }

  private struct Anchor {
    let title: String
    let position: Position
  }

  private static func buildChapters(
    publication: Publication,
    sections info: [SectionInfo],
    options: PlanOptions
  ) -> [NarrationChapter] {
    let source = publication.sections
    let infoByID = Dictionary(uniqueKeysWithValues: info.map { ($0.id, $0) })
    let sourcePositionByID = Dictionary(
      uniqueKeysWithValues: source.enumerated().map { ($0.element.id, $0.offset) })

    var anchors: [Anchor] = []
    var seen: Set<Position> = []
    for entry in publication.navigation {
      guard let sectionPosition = sourcePositionByID[entry.sectionID] else { continue }
      let block = min(max(0, entry.locator.blockIndex), source[sectionPosition].blocks.count)
      let position = Position(section: sectionPosition, block: block)
      guard seen.insert(position).inserted else { continue }
      anchors.append(Anchor(title: entry.title, position: position))
    }
    anchors.sort { $0.position < $1.position }

    var chapters: [NarrationChapter] = []
    let endOfBook = Position(section: source.count, block: 0)

    func appendChapter(title: String, start: Position, end: Position, synthetic: Bool) {
      guard start < end, start.section < source.count else { return }
      var blocks: [PublicationBlock] = []
      var sectionIDs: [String] = []
      let lastSection = min(end.section, source.count - 1)
      guard start.section <= lastSection else { return }

      for sectionPosition in start.section...lastSection {
        let section = source[sectionPosition]
        guard infoByID[section.id]?.included == true else { continue }
        let lower = sectionPosition == start.section ? min(start.block, section.blocks.count) : 0
        let upper = sectionPosition == end.section ? min(end.block, section.blocks.count) : section.blocks.count
        guard lower < upper else { continue }
        blocks.append(contentsOf: section.blocks[lower..<upper])
        if !sectionIDs.contains(section.id) { sectionIDs.append(section.id) }
      }
      guard !blocks.isEmpty else { return }

      var announcement: NarrationParagraph?
      if options.announceTitles, !synthetic {
        let decision = TitleAnnouncement.decide(title: title, bodyParagraphs: blocks.map(\.text))
        if decision.announce {
          announcement = NarrationParagraph(sentences: detectSentences(title))
          blocks.removeFirst(min(decision.absorbedParagraphCount, blocks.count))
        }
      }
      guard announcement != nil || !blocks.isEmpty else { return }
      chapters.append(
        NarrationChapter(
          title: title,
          announcement: announcement,
          paragraphs: blocks.map {
            NarrationParagraph(sentences: splitSentences($0.text), sourceLocator: $0.locator)
          },
          sectionIDs: sectionIDs))
    }

    if anchors.isEmpty {
      for (position, section) in source.enumerated() {
        appendChapter(
          title: section.title,
          start: Position(section: position, block: 0),
          end: Position(section: position + 1, block: 0),
          synthetic: true)
      }
      return chapters
    }

    let first = anchors[0].position
    for position in 0..<first.section {
      appendChapter(
        title: source[position].title,
        start: Position(section: position, block: 0),
        end: Position(section: position + 1, block: 0),
        synthetic: true)
    }
    if first.block > 0 {
      appendChapter(
        title: source[first.section].title,
        start: Position(section: first.section, block: 0),
        end: first,
        synthetic: true)
    }

    for (index, anchor) in anchors.enumerated() {
      let end = index + 1 < anchors.count ? anchors[index + 1].position : endOfBook
      let anchorSection = source[anchor.position.section]
      guard infoByID[anchorSection.id]?.included == true else {
        // An excluded sample/marketing anchor owns the unanchored material
        // that follows it, so only an explicit override may rescue that
        // range. Structural front matter (cover/TOC/copyright/notes) must not
        // accidentally swallow later, default-included spine documents.
        let role = infoByID[anchorSection.id]?.role
        let ownsFollowingRange = role == .excerpt || role == .alsoBy || role == .promotional
        if anchor.position.section + 1 < end.section {
          for position in (anchor.position.section + 1)..<end.section
          where ownsFollowingRange
            ? infoByID[source[position].id]?.explicitlyIncluded == true
            : infoByID[source[position].id]?.included == true
          {
            appendChapter(
              title: source[position].title,
              start: Position(section: position, block: 0),
              end: Position(section: position + 1, block: 0),
              synthetic: true)
          }
        }
        continue
      }
      appendChapter(
        title: anchor.title, start: anchor.position, end: end, synthetic: false)
    }
    return chapters
  }

  private static func uniqueSlug(
    for title: String, index: Int, used: inout Set<String>
  ) -> String {
    var base = title.lowercased()
      .map { $0.isLetter || $0.isNumber ? String($0) : "-" }
      .joined()
    while base.contains("--") { base = base.replacingOccurrences(of: "--", with: "-") }
    base = base.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    if base.count > 40 { base = String(base.prefix(40)) }
    if base.isEmpty { base = "section" }
    var slug = base
    if used.contains(slug) { slug = "\(base)-\(index)" }
    used.insert(slug)
    return slug
  }
}

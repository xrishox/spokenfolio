import Foundation
import SiriTTSCore

package struct PlanOptions: Sendable, Equatable {
  package var announceTitles = true
  /// Section overrides: spine indices ("7") or slugs ("about-the-author").
  /// Includes are applied before excludes.
  package var includeSections: [String] = []
  package var excludeSections: [String] = []
  /// Testing aid: keep only the first N chapters.
  package var maxChapters: Int?

  package init() {}
}

/// Everything the pipeline, CLI, and GUI need to know about a planned book.
package struct AudiobookPlan: Sendable {
  package let metadata: EPUBMetadata
  package let cover: EPUBCover?
  package let sections: [SectionInfo]
  package let chapters: [NarrationChapter]
  package let warnings: [String]

  package var totalCharacterCount: Int {
    chapters.reduce(0) { $0 + $1.characterCount }
  }

  /// Longest single synthesis unit (a joined paragraph); the worker deadline
  /// scales with it so long paragraphs are never mistaken for hung workers.
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
      "Unknown section '\(token)' (use a spine index or slug from the chapters listing)."
    }
  }
}

package enum AudiobookPlanner {
  /// Parses and classifies the book, applies section overrides, and produces
  /// source-ordered chapters ready for synthesis.
  package static func plan(book: EPUBBook, options: PlanOptions = PlanOptions()) throws
    -> AudiobookPlan
  {
    var warnings = book.warnings

    var extractions: [Int: ExtractedDocument] = [:]
    for item in book.spine where item.isXHTML {
      do {
        let document = try XHTMLDocument.parse(book.documentData(at: item.path))
        extractions[item.index] = NarrationExtractor.extract(from: document)
      } catch {
        warnings.append("skipping unreadable document '\(item.path)': \(error.localizedDescription)")
      }
    }

    var sections = SectionClassifier.classify(book: book, extractions: extractions)
    try applyOverrides(&sections, options: options)

    let chapters = buildChapters(
      book: book, sections: sections, extractions: extractions,
      options: options, warnings: &warnings)
    guard !chapters.isEmpty else { throw AudiobookPlanError.noNarratableContent }

    let limited = options.maxChapters.map { Array(chapters.prefix($0)) } ?? chapters

    // Reconcile the section list with what planning actually narrates, so
    // the listing, the GUI checkboxes, and the resume fingerprint never
    // claim content the audio does not contain.
    let narrated = Set(limited.flatMap(\.spineIndices))
    for index in sections.indices where sections[index].included {
      if !narrated.contains(sections[index].spineIndex) {
        sections[index].included = false
      }
    }

    return AudiobookPlan(
      metadata: book.metadata,
      cover: book.cover,
      sections: sections,
      chapters: limited,
      warnings: warnings)
  }

  private static func applyOverrides(
    _ sections: inout [SectionInfo], options: PlanOptions
  ) throws {
    func indices(for token: String) throws -> [Int] {
      let matches = sections.indices.filter {
        String(sections[$0].spineIndex) == token || sections[$0].slug == token
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

  private static func buildChapters(
    book: EPUBBook,
    sections: [SectionInfo],
    extractions: [Int: ExtractedDocument],
    options: PlanOptions,
    warnings: inout [String]
  ) -> [NarrationChapter] {
    let includedByIndex = Dictionary(
      uniqueKeysWithValues: sections.map { ($0.spineIndex, $0.included) })
    let spineIndexByPath = Dictionary(
      book.spine.map { ($0.path, $0.index) }, uniquingKeysWith: { first, _ in first })

    // TOC entries in reading order, deduplicated to their first spine item.
    var anchors: [(title: String, spineIndex: Int)] = []
    var seenSpineIndices: Set<Int> = []
    for entry in book.toc.flatMap(\.flattened) {
      guard let spineIndex = spineIndexByPath[entry.path] else {
        warnings.append("table of contents entry '\(entry.title)' points outside the spine")
        continue
      }
      guard seenSpineIndices.insert(spineIndex).inserted else { continue }
      anchors.append((entry.title, spineIndex))
    }
    anchors.sort { $0.spineIndex < $1.spineIndex }

    var chapters: [NarrationChapter] = []

    func appendChapter(
      title: String, spineRange: Range<Int>, synthetic: Bool
    ) {
      var paragraphs: [String] = []
      var spineIndices: [Int] = []
      for index in spineRange {
        guard includedByIndex[index] == true, let extraction = extractions[index],
          !extraction.paragraphs.isEmpty
        else { continue }
        paragraphs.append(contentsOf: extraction.paragraphs)
        spineIndices.append(index)
      }
      guard !paragraphs.isEmpty else { return }

      var announcement: NarrationParagraph?
      if options.announceTitles, !synthetic {
        let decision = TitleAnnouncement.decide(title: title, bodyParagraphs: paragraphs)
        if decision.announce {
          announcement = NarrationParagraph(sentences: detectSentences(title))
          paragraphs.removeFirst(decision.absorbedParagraphCount)
        }
      }
      guard announcement != nil || !paragraphs.isEmpty else { return }

      chapters.append(
        NarrationChapter(
          title: title,
          announcement: announcement,
          paragraphs: paragraphs.map { NarrationParagraph(sentences: splitSentences($0)) },
          spineIndices: spineIndices))
    }

    if anchors.isEmpty {
      // No TOC: one chapter per included document, synthetic titles.
      for item in book.spine {
        let title = extractions[item.index]?.firstHeading ?? "Section \(item.index + 1)"
        appendChapter(
          title: title, spineRange: item.index..<(item.index + 1), synthetic: true)
      }
      return chapters
    }

    // Leading spine items before the first TOC anchor.
    for index in 0..<anchors[0].spineIndex {
      let title = extractions[index]?.firstHeading ?? "Section \(index + 1)"
      appendChapter(title: title, spineRange: index..<(index + 1), synthetic: true)
    }
    let explicitlyIncluded = Set(
      sections.filter(\.explicitlyIncluded).map(\.spineIndex))
    for (position, anchor) in anchors.enumerated() {
      let end = position + 1 < anchors.count ? anchors[position + 1].spineIndex : book.spine.count
      // An excluded anchor drops its whole range: unreferenced continuation
      // files belong to their chapter, so excluding "Excerpt: …" also
      // excludes the excerpt body that spills into the next spine file.
      // A section the user explicitly included survives as its own chapter.
      guard includedByIndex[anchor.spineIndex] == true else {
        for index in (anchor.spineIndex + 1)..<end where explicitlyIncluded.contains(index) {
          let title = extractions[index]?.firstHeading ?? "Section \(index + 1)"
          appendChapter(title: title, spineRange: index..<(index + 1), synthetic: true)
        }
        continue
      }
      appendChapter(title: anchor.title, spineRange: anchor.spineIndex..<end, synthetic: false)
    }
    return chapters
  }
}

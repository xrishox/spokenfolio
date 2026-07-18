import DocumentIOKit
import Foundation
import PublicationKit

package struct EPUBImporter: PublicationImporting {
  private static let maximumNarrativeUTF8Bytes = 128 << 20
  package let formatIdentifier = "epub"
  package let importerVersion = 1

  package init() {}

  package func load(url: URL) throws -> Publication {
    try load(url: url, archiveLimits: .publication)
  }

  package func load(
    url: URL, archiveLimits: ZIPArchive.Limits
  ) throws -> Publication {
    let book = try EPUBBook.load(url: url, archiveLimits: archiveLimits)
    var warnings = book.warnings
    var extractions: [Int: ExtractedDocument] = [:]
    var narrativeUTF8Bytes = 0
    let apparatusClasses = ApparatusNumberDetection.apparatusClasses(css: book.stylesheetCSS())
    for item in book.spine {
      guard item.isXHTML else {
        if item.linear {
          throw EPUBError.invalidDocument(
            item.path, "primary spine content has unsupported media type '\(item.mediaType)'")
        }
        warnings.append("skipping auxiliary non-XHTML document '\(item.path)'")
        continue
      }
      do {
        let document = try XHTMLDocument.parse(book.documentData(at: item.path))
        let extraction = NarrationExtractor.extract(
          from: document, documentID: item.path, apparatusClasses: apparatusClasses)
        for block in extraction.blocks {
          let next = narrativeUTF8Bytes.addingReportingOverflow(block.text.utf8.count)
          guard !next.overflow, next.partialValue <= Self.maximumNarrativeUTF8Bytes else {
            throw EPUBError.invalidDocument(
              item.path, "aggregate narratable text exceeds the supported size")
          }
          narrativeUTF8Bytes = next.partialValue
        }
        extractions[item.index] = extraction
        warnings.append(contentsOf: extraction.warnings)
      } catch {
        if item.linear { throw EPUBError.invalidDocument(item.path, error.localizedDescription) }
        warnings.append(
          "skipping unreadable auxiliary document '\(item.path)': \(error.localizedDescription)")
      }
    }

    let capsEvidence = CapsFoldDetection.evidence(in: Array(extractions.values))
    for (index, extraction) in extractions {
      extractions[index] = CapsFoldDetection.fold(extraction, evidence: capsEvidence)
    }
    let classified = SectionClassifier.classify(book: book, extractions: extractions)
    let sections = classified.map { classified in
      PublicationSection(
        id: Self.sectionID(for: classified.item),
        index: classified.item.index,
        title: classified.title,
        role: classified.role,
        readingOrder: classified.item.linear ? .primary : .auxiliary,
        blocks: classified.extraction?.blocks ?? [])
    }
    var sectionByPath: [String: PublicationSection] = [:]
    for (item, section) in zip(book.spine, sections) where sectionByPath[item.path] == nil {
      sectionByPath[item.path] = section
    }
    var navigation: [PublicationNavigationEntry] = []
    for entry in book.toc.flatMap(\.flattened) {
      guard let section = sectionByPath[entry.path] else {
        warnings.append("table of contents entry '\(entry.title)' points outside the spine")
        continue
      }
      let blockIndex: Int
      if let fragment = entry.fragment,
        let matched = section.blocks.first(where: { $0.locator.fragmentID == fragment })
      {
        blockIndex = matched.locator.blockIndex
      } else {
        blockIndex = 0
      }
      navigation.append(
        PublicationNavigationEntry(
          title: entry.title,
          sectionID: section.id,
          locator: SourceLocator(
            documentID: entry.path,
            fragmentID: entry.fragment,
            blockIndex: blockIndex),
          depth: entry.depth))
    }

    return Publication(
      sourceURL: url,
      sourceFormat: formatIdentifier,
      importerVersion: importerVersion,
      metadata: PublicationMetadata(
        title: book.metadata.title,
        author: book.metadata.author,
        language: book.metadata.language,
        publisher: book.metadata.publisher,
        date: book.metadata.date,
        description: book.metadata.description,
        subject: book.metadata.subject,
        identifiers: book.metadata.identifiers.map {
          PublicationIdentifier(kind: $0.kind, value: $0.value)
        }),
      cover: book.cover.map {
        PublicationCover(
          data: $0.data,
          kind: $0.kind == .jpeg ? .jpeg : .png)
      },
      sections: sections,
      navigation: navigation,
      warnings: warnings)
  }

  private static func sectionID(for item: SpineItem) -> String {
    "epub:\(item.index):\(item.idref):\(item.path)"
  }
}

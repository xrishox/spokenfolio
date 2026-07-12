import Foundation
import PublicationKit

package struct EPUBImporter: PublicationImporting {
  package let formatIdentifier = "epub"
  package let importerVersion = 1

  package init() {}

  package func load(url: URL) throws -> Publication {
    let book = try EPUBBook.load(url: url)
    var warnings = book.warnings
    var extractions: [Int: ExtractedDocument] = [:]
    for item in book.spine where item.isXHTML {
      do {
        let document = try XHTMLDocument.parse(book.documentData(at: item.path))
        extractions[item.index] = NarrationExtractor.extract(
          from: document, documentID: item.path)
      } catch {
        warnings.append("skipping unreadable document '\(item.path)': \(error.localizedDescription)")
      }
    }

    let classified = SectionClassifier.classify(book: book, extractions: extractions)
    let sections = classified.map { classified in
      PublicationSection(
        id: Self.sectionID(for: classified.item),
        index: classified.item.index,
        title: classified.title,
        role: classified.role,
        blocks: classified.extraction?.blocks ?? [])
    }
    let sectionByPath = Dictionary(
      uniqueKeysWithValues: zip(book.spine, sections).map { ($0.path, $1) })
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
        subject: book.metadata.subject),
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

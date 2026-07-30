import Foundation

package struct PublicationIdentifier: Codable, Hashable, Sendable {
  package let kind: String?
  package let value: String

  package init(kind: String? = nil, value: String) {
    self.kind = kind
    self.value = value
  }
}

package struct PublicationMetadata: Sendable, Equatable {
  package let title: String
  package let author: String?
  package let language: String?
  package let publisher: String?
  package let date: String?
  package let description: String?
  package let subject: String?
  package let identifiers: [PublicationIdentifier]

  package init(
    title: String, author: String? = nil, language: String? = nil,
    publisher: String? = nil, date: String? = nil, description: String? = nil,
    subject: String? = nil, identifiers: [PublicationIdentifier] = []
  ) {
    self.title = title
    self.author = author
    self.language = language
    self.publisher = publisher
    self.date = date
    self.description = description
    self.subject = subject
    self.identifiers = identifiers
  }
}

package struct PublicationCover: Sendable, Equatable {
  package enum Kind: String, Sendable { case jpeg, png }
  package let data: Data
  package let kind: Kind

  package init(data: Data, kind: Kind) {
    self.data = data
    self.kind = kind
  }
}

package struct SourceLocator: Codable, Hashable, Sendable {
  package let documentID: String
  package let fragmentID: String?
  package let blockIndex: Int

  package init(documentID: String, fragmentID: String?, blockIndex: Int) {
    self.documentID = documentID
    self.fragmentID = fragmentID
    self.blockIndex = blockIndex
  }
}

/// UTF-16 range inside the normalized text of one `PublicationBlock`.
/// Offsets use the same representation as NSString and private-engine timing
/// callbacks, so sentence packing and ReadAloud provenance share one unit.
package struct SourceTextRange: Codable, Hashable, Sendable {
  package let location: Int
  package let length: Int

  package init(location: Int, length: Int) {
    self.location = location
    self.length = length
  }
}

package struct PublicationBlock: Sendable, Equatable {
  package let text: String
  package let locator: SourceLocator

  package init(text: String, locator: SourceLocator) {
    self.text = text
    self.locator = locator
  }
}

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
  case promotional
  case unknown

}

package enum PublicationReadingOrder: String, Sendable {
  case primary
  case auxiliary
}

package struct PublicationSection: Sendable, Equatable {
  package let id: String
  package let index: Int
  package let title: String
  package let role: SectionRole
  package let readingOrder: PublicationReadingOrder
  package let blocks: [PublicationBlock]

  package init(
    id: String, index: Int, title: String, role: SectionRole,
    readingOrder: PublicationReadingOrder = .primary, blocks: [PublicationBlock]
  ) {
    self.id = id
    self.index = index
    self.title = title
    self.role = role
    self.readingOrder = readingOrder
    self.blocks = blocks
  }
}

package struct PublicationNavigationEntry: Sendable, Equatable {
  package let title: String
  package let sectionID: String
  package let locator: SourceLocator
  package let depth: Int

  package init(title: String, sectionID: String, locator: SourceLocator, depth: Int) {
    self.title = title
    self.sectionID = sectionID
    self.locator = locator
    self.depth = depth
  }
}

package struct Publication: Sendable {
  package let sourceURL: URL
  package let sourceFormat: String
  package let importerVersion: Int
  package let metadata: PublicationMetadata
  package let cover: PublicationCover?
  package let sections: [PublicationSection]
  package let navigation: [PublicationNavigationEntry]
  package let warnings: [String]

  package init(
    sourceURL: URL, sourceFormat: String, importerVersion: Int,
    metadata: PublicationMetadata, cover: PublicationCover?,
    sections: [PublicationSection], navigation: [PublicationNavigationEntry],
    warnings: [String]
  ) {
    self.sourceURL = sourceURL
    self.sourceFormat = sourceFormat
    self.importerVersion = importerVersion
    self.metadata = metadata
    self.cover = cover
    self.sections = sections
    self.navigation = navigation
    self.warnings = warnings
  }
}

package protocol PublicationImporting: Sendable {
  var formatIdentifier: String { get }
  var importerVersion: Int { get }
  func load(url: URL) throws -> Publication
}

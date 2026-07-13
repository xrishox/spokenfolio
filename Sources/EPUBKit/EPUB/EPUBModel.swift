import Foundation

/// Book-level metadata from the OPF package document.
package struct EPUBMetadata: Sendable, Equatable {
  package struct Identifier: Sendable, Equatable {
    package let kind: String?
    package let value: String
  }
  package let title: String
  package let author: String?
  package let language: String?
  package let publisher: String?
  package let date: String?
  package let description: String?
  package let subject: String?
  package let identifiers: [Identifier]
}

/// One spine itemref resolved to its manifest entry. `index` is the stable
/// position in the spine and is the identity used by section overrides and
/// job manifests.
package struct SpineItem: Sendable, Equatable {
  package let index: Int
  package let idref: String
  package let path: String
  package let mediaType: String
  package let linear: Bool

  package var isXHTML: Bool {
    mediaType == "application/xhtml+xml" || mediaType == "text/html"
  }
}

/// One table-of-contents entry. `path` is a normalized zip path; a `fragment`
/// points inside that document.
package struct TOCEntry: Sendable, Equatable {
  package let title: String
  package let path: String
  package let fragment: String?
  package let depth: Int
  package let children: [TOCEntry]

  package init(title: String, path: String, fragment: String?, depth: Int, children: [TOCEntry]) {
    self.title = title
    self.path = path
    self.fragment = fragment
    self.depth = depth
    self.children = children
  }

  /// Depth-first flattening in reading order.
  package var flattened: [TOCEntry] {
    [self] + children.flatMap(\.flattened)
  }
}

package enum TOCSource: String, Sendable {
  case navDocument
  case ncx
  case none
}

/// A semantic boundary from the EPUB 3 landmarks nav or the EPUB 2 guide,
/// normalized to EPUB 3 vocabulary (`bodymatter`, `cover`, `toc`, …).
package struct EPUBLandmark: Sendable, Equatable {
  package let epubType: String
  package let path: String
  package let fragment: String?
}

package struct EPUBCover: Sendable, Equatable {
  package enum Kind: String, Sendable {
    case jpeg
    case png
  }

  package let data: Data
  package let kind: Kind

  /// nil when the image is neither JPEG nor PNG (audiobook covers support
  /// only those two container types).
  package init?(data: Data) {
    if data.starts(with: [0xFF, 0xD8, 0xFF]) {
      kind = .jpeg
    } else if data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
      kind = .png
    } else {
      return nil
    }
    self.data = data
  }
}

package enum EPUBError: Error, LocalizedError {
  case notAZipArchive(String)
  case missingContainerXML
  case invalidContainerXML(String)
  case missingPackageDocument(String)
  case invalidPackageDocument(String)
  case emptySpine
  case missingDocument(String)
  case invalidDocument(String, String)

  package var errorDescription: String? {
    switch self {
    case .notAZipArchive(let detail):
      "The file is not a readable EPUB (zip) archive: \(detail)"
    case .missingContainerXML:
      "The EPUB has no META-INF/container.xml."
    case .invalidContainerXML(let detail):
      "META-INF/container.xml is invalid: \(detail)"
    case .missingPackageDocument(let path):
      "The EPUB package document '\(path)' is missing."
    case .invalidPackageDocument(let detail):
      "The EPUB package document is invalid: \(detail)"
    case .emptySpine:
      "The EPUB spine lists no readable documents."
    case .missingDocument(let path):
      "The EPUB references a missing document: '\(path)'."
    case .invalidDocument(let path, let detail):
      "The EPUB document '\(path)' could not be parsed: \(detail)"
    }
  }
}

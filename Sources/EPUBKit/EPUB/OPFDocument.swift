import Foundation

struct ManifestItem: Sendable, Equatable {
  let id: String
  let path: String
  let mediaType: String
  let properties: Set<String>
}

struct GuideReference: Sendable, Equatable {
  let type: String
  let path: String
  let fragment: String?
}

/// The parsed OPF package document: metadata, manifest, spine, guide, and the
/// pointers needed to locate the nav document, NCX, and cover image.
struct OPFDocument {
  let version: String
  let metadata: EPUBMetadata
  let manifestByID: [String: ManifestItem]
  let manifestByPath: [String: ManifestItem]
  let spine: [SpineItem]
  let guideReferences: [GuideReference]
  let navDocumentPath: String?
  let ncxPath: String?
  let coverImagePath: String?

  static func parse(_ data: Data, opfPath: String) throws -> OPFDocument {
    let document: XMLDocument
    do {
      document = try XHTMLDocument.parse(data)
    } catch {
      throw EPUBError.invalidPackageDocument(error.localizedDescription)
    }
    guard let root = document.rootElement(), root.localName == "package" else {
      throw EPUBError.invalidPackageDocument("root element is not <package>")
    }
    let version = root.attribute(forName: "version")?.stringValue ?? "2.0"

    var manifestByID: [String: ManifestItem] = [:]
    var manifestByPath: [String: ManifestItem] = [:]
    for item in try XHTMLDocument.elements(named: "item", in: document) {
      guard
        let id = item.attribute(forName: "id")?.stringValue,
        let href = item.attribute(forName: "href")?.stringValue,
        let resolved = EPUBHref.resolve(href, relativeTo: opfPath)?.path
      else { continue }
      let entry = ManifestItem(
        id: id,
        path: resolved,
        mediaType: item.attribute(forName: "media-type")?.stringValue ?? "",
        properties: Set(
          (item.attribute(forName: "properties")?.stringValue ?? "")
            .split(separator: " ").map { $0.lowercased() }))
      manifestByID[id] = entry
      manifestByPath[entry.path] = entry
    }

    var ncxID: String?
    var spine: [SpineItem] = []
    if let spineElement = try XHTMLDocument.elements(named: "spine", in: document).first {
      ncxID = spineElement.attribute(forName: "toc")?.stringValue
      for case let itemref as XMLElement in spineElement.children ?? [] {
        guard itemref.localName == "itemref",
          let idref = itemref.attribute(forName: "idref")?.stringValue,
          let item = manifestByID[idref]
        else { continue }
        spine.append(
          SpineItem(
            index: spine.count,
            idref: idref,
            path: item.path,
            mediaType: item.mediaType,
            linear: itemref.attribute(forName: "linear")?.stringValue?.lowercased() != "no"))
      }
    }
    guard !spine.isEmpty else { throw EPUBError.emptySpine }

    var guideReferences: [GuideReference] = []
    for reference in try XHTMLDocument.elements(named: "reference", in: document) {
      guard
        let type = reference.attribute(forName: "type")?.stringValue?.lowercased(),
        let href = reference.attribute(forName: "href")?.stringValue,
        let resolved = EPUBHref.resolve(href, relativeTo: opfPath)
      else { continue }
      guideReferences.append(
        GuideReference(type: type, path: resolved.path, fragment: resolved.fragment))
    }

    let navDocumentPath = manifestByID.values
      .first(where: { $0.properties.contains("nav") })?.path
    let ncxPath =
      ncxID.flatMap { manifestByID[$0]?.path }
      ?? manifestByID.values.first(where: { $0.mediaType == "application/x-dtbncx+xml" })?.path

    return OPFDocument(
      version: version,
      metadata: parseMetadata(document),
      manifestByID: manifestByID,
      manifestByPath: manifestByPath,
      spine: spine,
      guideReferences: guideReferences,
      navDocumentPath: navDocumentPath,
      ncxPath: ncxPath,
      coverImagePath: coverImagePath(document, manifestByID: manifestByID))
  }

  private static func parseMetadata(_ document: XMLDocument) -> EPUBMetadata {
    func dc(_ localName: String) -> String? {
      let elements = (try? XHTMLDocument.elements(named: localName, in: document)) ?? []
      // Dublin Core terms live under the metadata element; local-name matching
      // could also hit content markup, so require the dc namespace.
      for element in elements where element.uri == "http://purl.org/dc/elements/1.1/" {
        let text = element.collapsedText
        if !text.isEmpty { return text }
      }
      return nil
    }
    let identifierElements = (try? XHTMLDocument.elements(named: "identifier", in: document)) ?? []
    let metadataElements = (try? XHTMLDocument.elements(named: "meta", in: document)) ?? []
    var refinedIdentifierKinds: [String: String] = [:]
    for meta in metadataElements {
      guard meta.attribute(forName: "property")?.stringValue?.lowercased()
        .hasSuffix("identifier-type") == true,
        let refines = meta.attribute(forName: "refines")?.stringValue,
        refines.hasPrefix("#")
      else { continue }
      let value = meta.collapsedText
      if !value.isEmpty { refinedIdentifierKinds[String(refines.dropFirst())] = value }
    }
    let identifiers = identifierElements.compactMap { element -> EPUBMetadata.Identifier? in
      guard element.uri == "http://purl.org/dc/elements/1.1/" else { return nil }
      let value = element.collapsedText
      guard !value.isEmpty else { return nil }
      let kind =
        element.attribute(forName: "scheme")?.stringValue
        ?? element.attribute(forName: "opf:scheme")?.stringValue
        ?? element.attribute(forName: "id")?.stringValue.flatMap { refinedIdentifierKinds[$0] }
      return .init(kind: kind, value: value)
    }
    return EPUBMetadata(
      title: dc("title") ?? "Untitled",
      author: dc("creator"),
      language: dc("language"),
      publisher: dc("publisher"),
      date: dc("date"),
      description: dc("description"),
      subject: dc("subject"),
      identifiers: identifiers)
  }

  /// EPUB 3: manifest `properties="cover-image"`. EPUB 2: `<meta name="cover"
  /// content="manifest-id">` (some books store an href in `content` instead).
  private static func coverImagePath(
    _ document: XMLDocument, manifestByID: [String: ManifestItem]
  ) -> String? {
    if let item = manifestByID.values.first(where: { $0.properties.contains("cover-image") }) {
      return item.path
    }
    let metas = (try? XHTMLDocument.elements(named: "meta", in: document)) ?? []
    for meta in metas where meta.attribute(forName: "name")?.stringValue == "cover" {
      guard let content = meta.attribute(forName: "content")?.stringValue else { continue }
      if let item = manifestByID[content] { return item.path }
      if let byPath = manifestByID.values.first(where: { $0.path.hasSuffix(content) }) {
        return byPath.path
      }
    }
    return nil
  }
}

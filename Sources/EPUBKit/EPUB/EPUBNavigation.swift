import Foundation

/// Table of contents and semantic landmarks, from the EPUB 3 nav document
/// when present, otherwise the EPUB 2 NCX; the OPF guide contributes
/// landmarks either way.
struct EPUBNavigation {
  let toc: [TOCEntry]
  let tocSource: TOCSource
  let landmarks: [EPUBLandmark]

  /// EPUB 2 guide types normalized to EPUB 3 landmark vocabulary.
  private static let guideTypeMap: [String: String] = [
    "text": "bodymatter",
    "cover": "cover",
    "title-page": "titlepage",
    "toc": "toc",
    "index": "index",
    "notes": "footnotes",
    "copyright-page": "copyright-page",
    "acknowledgements": "acknowledgments",
    "acknowledgments": "acknowledgments",
    "dedication": "dedication",
    "epigraph": "epigraph",
    "foreword": "foreword",
    "preface": "preface",
    "glossary": "glossary",
    "bibliography": "bibliography",
    "colophon": "colophon",
  ]

  static func load(
    opf: OPFDocument,
    documentData: (String) throws -> Data
  ) -> EPUBNavigation {
    var toc: [TOCEntry] = []
    var tocSource: TOCSource = .none
    var landmarks: [EPUBLandmark] = []

    if let navPath = opf.navDocumentPath,
      let data = try? documentData(navPath),
      let document = try? XHTMLDocument.parse(data)
    {
      let navs = (try? XHTMLDocument.elements(named: "nav", in: document)) ?? []
      if let tocNav = navs.first(where: { $0.epubTypeTokens.contains("toc") }) ?? navs.first {
        toc = parseNavList(tocNav, navPath: navPath, depth: 0)
        if !toc.isEmpty { tocSource = .navDocument }
      }
      if let landmarksNav = navs.first(where: { $0.epubTypeTokens.contains("landmarks") }) {
        landmarks.append(contentsOf: parseLandmarks(landmarksNav, navPath: navPath))
      }
    }

    if toc.isEmpty, let ncxPath = opf.ncxPath,
      let data = try? documentData(ncxPath),
      let document = try? XHTMLDocument.parse(data)
    {
      if let navMap = (try? XHTMLDocument.elements(named: "navMap", in: document))?.first {
        toc = parseNCXPoints(in: navMap, ncxPath: ncxPath, depth: 0)
        if !toc.isEmpty { tocSource = .ncx }
      }
    }

    for reference in opf.guideReferences {
      guard let mapped = guideTypeMap[reference.type] else { continue }
      guard !landmarks.contains(where: { $0.epubType == mapped }) else { continue }
      landmarks.append(
        EPUBLandmark(epubType: mapped, path: reference.path, fragment: reference.fragment))
    }

    return EPUBNavigation(toc: toc, tocSource: tocSource, landmarks: landmarks)
  }

  // MARK: - EPUB 3 nav document

  private static func parseNavList(
    _ container: XMLElement, navPath: String, depth: Int
  ) -> [TOCEntry] {
    guard let list = firstChildElement(of: container, named: "ol") else { return [] }
    var entries: [TOCEntry] = []
    for case let item as XMLElement in list.children ?? [] where item.localName == "li" {
      // A li holds an <a href> (or an unlinked <span> heading), then
      // optionally a nested <ol>.
      let anchor = firstChildElement(of: item, named: "a")
      let label = (anchor ?? firstChildElement(of: item, named: "span"))?.collapsedText ?? ""
      let children = parseNavList(item, navPath: navPath, depth: depth + 1)

      if let href = anchor?.attribute(forName: "href")?.stringValue,
        let resolved = EPUBHref.resolve(href, relativeTo: navPath),
        !label.isEmpty
      {
        entries.append(
          TOCEntry(
            title: label, path: resolved.path, fragment: resolved.fragment,
            depth: depth, children: children))
      } else if let first = children.first {
        // Unlinked headings adopt their first child's target so the branch
        // stays addressable; remaining children keep their own entries.
        entries.append(
          TOCEntry(
            title: label.isEmpty ? first.title : label,
            path: first.path, fragment: first.fragment,
            depth: depth, children: children))
      }
    }
    return entries
  }

  private static func parseLandmarks(
    _ nav: XMLElement, navPath: String
  ) -> [EPUBLandmark] {
    var found: [EPUBLandmark] = []
    var stack: [XMLNode] = [nav]
    while let node = stack.popLast() {
      if let element = node as? XMLElement, element.localName == "a",
        let href = element.attribute(forName: "href")?.stringValue,
        let resolved = EPUBHref.resolve(href, relativeTo: navPath)
      {
        for token in element.epubTypeTokens {
          found.append(
            EPUBLandmark(epubType: token, path: resolved.path, fragment: resolved.fragment))
        }
      }
      stack.append(contentsOf: node.children ?? [])
    }
    return found
  }

  // MARK: - EPUB 2 NCX

  private static func parseNCXPoints(
    in container: XMLElement, ncxPath: String, depth: Int
  ) -> [TOCEntry] {
    var entries: [TOCEntry] = []
    for case let point as XMLElement in container.children ?? []
    where point.localName == "navPoint" {
      let label =
        firstChildElement(of: point, named: "navLabel")
        .flatMap { firstChildElement(of: $0, named: "text") }?.collapsedText ?? ""
      let source = firstChildElement(of: point, named: "content")?
        .attribute(forName: "src")?.stringValue
      let children = parseNCXPoints(in: point, ncxPath: ncxPath, depth: depth + 1)

      if let source, let resolved = EPUBHref.resolve(source, relativeTo: ncxPath), !label.isEmpty {
        entries.append(
          TOCEntry(
            title: label, path: resolved.path, fragment: resolved.fragment,
            depth: depth, children: children))
      } else {
        entries.append(contentsOf: children)
      }
    }
    return entries
  }

  private static func firstChildElement(of element: XMLElement, named localName: String)
    -> XMLElement?
  {
    for case let child as XMLElement in element.children ?? [] where child.localName == localName {
      return child
    }
    return nil
  }
}

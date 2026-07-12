import Foundation

/// XML parsing for EPUB documents. EPUB content is XHTML (well-formed XML by
/// spec), so strict parsing is the primary path; `.documentTidyXML` recovers
/// the slightly-broken files that exist in the wild.
enum XHTMLDocument {
  static let epubNamespace = "http://www.idpf.org/2007/ops"

  static func parse(_ data: Data) throws -> XMLDocument {
    do {
      return try XMLDocument(data: data, options: [.nodePreserveWhitespace])
    } catch {
      return try XMLDocument(data: data, options: [.documentTidyXML, .nodePreserveWhitespace])
    }
  }

  /// All descendant elements matching a local name, ignoring namespaces
  /// (container/OPF/NCX/XHTML each use their own default namespace).
  static func elements(named localName: String, in document: XMLDocument) throws -> [XMLElement] {
    let nodes = try document.nodes(forXPath: "//*[local-name()='\(localName)']")
    return nodes.compactMap { $0 as? XMLElement }
  }
}

extension XMLElement {
  /// A namespace-tolerant attribute lookup: matches the exact qualified name
  /// first (the near-universal `epub:type` spelling), then any prefix whose
  /// resolved namespace matches.
  func attributeValue(localName: String, namespaceURI: String?) -> String? {
    if let namespaceURI,
      let direct = attribute(forLocalName: localName, uri: namespaceURI)?.stringValue
    {
      return direct
    }
    if namespaceURI == XHTMLDocument.epubNamespace,
      let qualified = attribute(forName: "epub:type")?.stringValue, localName == "type"
    {
      return qualified
    }
    guard namespaceURI == nil else { return nil }
    return attribute(forName: localName)?.stringValue
  }

  /// `epub:type` as a token set (the attribute is space-separated).
  var epubTypeTokens: Set<String> {
    guard
      let value = attributeValue(localName: "type", namespaceURI: XHTMLDocument.epubNamespace)
    else { return [] }
    return Set(value.split(separator: " ").map { $0.lowercased() })
  }

  /// `role` as a token set.
  var roleTokens: Set<String> {
    guard let value = attribute(forName: "role")?.stringValue else { return [] }
    return Set(value.split(separator: " ").map { $0.lowercased() })
  }

  /// Space-separated `class` tokens.
  var classTokens: Set<String> {
    guard let value = attribute(forName: "class")?.stringValue else { return [] }
    return Set(value.split(separator: " ").map { $0.lowercased() })
  }

  /// Concatenated descendant text, whitespace-collapsed.
  var collapsedText: String {
    (stringValue ?? "").collapsingWhitespace()
  }
}

extension String {
  /// NBSP → space, soft hyphens removed, whitespace runs collapsed, trimmed.
  func collapsingWhitespace() -> String {
    var result = String.UnicodeScalarView()
    var pendingSpace = false
    var started = false
    for scalar in unicodeScalars {
      if scalar == "\u{00AD}" { continue }
      let isSpace =
        scalar.properties.isWhitespace || scalar == "\u{00A0}" || scalar == "\u{2028}"
        || scalar == "\u{2029}"
      if isSpace {
        pendingSpace = started
        continue
      }
      if pendingSpace {
        result.append(" ")
        pendingSpace = false
      }
      result.append(scalar)
      started = true
    }
    return String(result)
  }
}

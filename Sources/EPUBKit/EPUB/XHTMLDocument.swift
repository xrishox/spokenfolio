import Foundation
import DocumentIOKit

/// XML parsing for EPUB documents. EPUB content is XHTML (well-formed XML by
/// spec), so strict parsing is the primary path; `.documentTidyXML` recovers
/// the slightly-broken files that exist in the wild.
enum XHTMLDocument {
  static let epubNamespace = "http://www.idpf.org/2007/ops"

  static func parse(_ data: Data) throws -> XMLDocument {
    try BoundedXMLDocument.parse(data)
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
  /// Typographic presentation ligatures (U+FB00–FB06) expanded to their
  /// letters. Print-oriented EPUBs embed "ﬁ"/"ﬂ" directly in text; they are
  /// display forms, not distinct words, and alignment/ASR comparison needs
  /// the plain letters. Œ/æ and other letter ligatures are real orthography
  /// and are kept.
  private static let presentationLigatures: [Unicode.Scalar: String] = [
    "\u{FB00}": "ff", "\u{FB01}": "fi", "\u{FB02}": "fl",
    "\u{FB03}": "ffi", "\u{FB04}": "ffl", "\u{FB05}": "st", "\u{FB06}": "st",
  ]

  /// NBSP → space, soft hyphens and zero-width formatting removed,
  /// presentation ligatures expanded, whitespace runs collapsed, trimmed.
  /// The zero-width class is exactly ZWSP (U+200B), WORD JOINER (U+2060),
  /// and its deprecated alias ZWNBSP (U+FEFF) — invisible line-break hints
  /// that must not reach synthesis or alignment tokenization. ZWJ/ZWNJ are
  /// deliberately kept: they carry meaning in emoji sequences and joining
  /// scripts.
  func collapsingWhitespace() -> String {
    var result = String.UnicodeScalarView()
    var pendingSpace = false
    var started = false
    for scalar in unicodeScalars {
      if scalar == "\u{00AD}" || scalar == "\u{200B}" || scalar == "\u{2060}"
        || scalar == "\u{FEFF}"
      {
        continue
      }
      if let expansion = Self.presentationLigatures[scalar] {
        if pendingSpace {
          result.append(" ")
          pendingSpace = false
        }
        result.append(contentsOf: expansion.unicodeScalars)
        started = true
        continue
      }
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

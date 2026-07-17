import Foundation

/// A single hardened entry point for XML carried by untrusted publication
/// containers. It deliberately owns resource safety, not EPUB or SMIL rules.
package enum BoundedXMLDocument {
  package struct Limits: Sendable {
    package var maximumInputBytes: Int
    package var maximumTidyInputBytes: Int
    package var maximumDepth: Int
    package var maximumNodes: Int
    package var maximumAttributes: Int
    package var maximumTextBytes: Int

    package init(
      maximumInputBytes: Int = 64 << 20,
      maximumTidyInputBytes: Int = 8 << 20,
      maximumDepth: Int = 256,
      maximumNodes: Int = 250_000,
      maximumAttributes: Int = 1_000_000,
      maximumTextBytes: Int = 64 << 20
    ) {
      self.maximumInputBytes = maximumInputBytes
      self.maximumTidyInputBytes = maximumTidyInputBytes
      self.maximumDepth = maximumDepth
      self.maximumNodes = maximumNodes
      self.maximumAttributes = maximumAttributes
      self.maximumTextBytes = maximumTextBytes
    }

    package static let publication = Limits()
  }

  package static func parse(
    _ data: Data,
    limits: Limits = .publication,
    preserveWhitespace: Bool = true,
    allowTidy: Bool = true
  ) throws -> XMLDocument {
    guard !data.isEmpty, data.count <= limits.maximumInputBytes else {
      throw BoundedXMLError.inputSize(actual: data.count, limit: limits.maximumInputBytes)
    }
    try rejectEntityDeclarations(in: data)

    var base: XMLNode.Options = [.nodeLoadExternalEntitiesNever, .nodePreserveEntities]
    if preserveWhitespace { base.insert(.nodePreserveWhitespace) }

    let document: XMLDocument
    do {
      document = try XMLDocument(data: data, options: base)
    } catch {
      guard allowTidy, data.count <= limits.maximumTidyInputBytes else {
        throw BoundedXMLError.malformed(error.localizedDescription)
      }
      do {
        var tidy = base
        tidy.insert(.documentTidyXML)
        document = try XMLDocument(data: data, options: tidy)
      } catch {
        throw BoundedXMLError.malformed(error.localizedDescription)
      }
    }
    try validate(document, limits: limits)
    return document
  }

  /// External doctypes are permitted because common EPUB2 XHTML declares
  /// one, but Foundation is forbidden from loading it. Custom entities and
  /// internal subsets are rejected before either strict or tidy parsing.
  private static func rejectEntityDeclarations(in data: Data) throws {
    let source = try declarationScanSource(from: data).uppercased()
    if source.contains("<!ENTITY") { throw BoundedXMLError.entityDeclaration }
    if let doctype = source.range(of: "<!DOCTYPE"),
      let close = source[doctype.lowerBound...].firstIndex(of: ">"),
      source[doctype.lowerBound...close].contains("[")
    {
      throw BoundedXMLError.entityDeclaration
    }
  }

  /// XML may declare UTF-16 or UTF-32 without a BOM. Scanning the raw bytes
  /// as UTF-8 would miss an internal subset and allow Foundation to expand it
  /// before the post-parse resource limits run.
  private static func declarationScanSource(from data: Data) throws -> String {
    let bytes = [UInt8](data.prefix(4))
    let encoding: String.Encoding
    if bytes == [0x00, 0x00, 0xFE, 0xFF]
      || bytes == [0x00, 0x00, 0x00, 0x3C]
    {
      encoding = .utf32BigEndian
    } else if bytes == [0xFF, 0xFE, 0x00, 0x00]
      || bytes == [0x3C, 0x00, 0x00, 0x00]
    {
      encoding = .utf32LittleEndian
    } else if bytes.starts(with: [0xFE, 0xFF])
      || bytes.starts(with: [0x00, 0x3C, 0x00])
    {
      encoding = .utf16BigEndian
    } else if bytes.starts(with: [0xFF, 0xFE])
      || (bytes.count == 4 && bytes[0] == 0x3C && bytes[1] == 0x00 && bytes[3] == 0x00)
    {
      encoding = .utf16LittleEndian
    } else {
      encoding = .utf8
    }
    guard let source = String(data: data, encoding: encoding) else {
      throw BoundedXMLError.malformed("the declared XML byte encoding is invalid")
    }
    return source
  }

  private static func validate(_ document: XMLDocument, limits: Limits) throws {
    struct Pending {
      let node: XMLNode
      let depth: Int
    }
    var stack = [Pending(node: document, depth: 0)]
    var nodes = 0
    var attributes = 0
    var textBytes = 0

    while let pending = stack.popLast() {
      nodes += 1
      guard nodes <= limits.maximumNodes else {
        throw BoundedXMLError.nodeCount(limit: limits.maximumNodes)
      }
      guard pending.depth <= limits.maximumDepth else {
        throw BoundedXMLError.depth(limit: limits.maximumDepth)
      }
      if let element = pending.node as? XMLElement {
        attributes += element.attributes?.count ?? 0
        guard attributes <= limits.maximumAttributes else {
          throw BoundedXMLError.attributeCount(limit: limits.maximumAttributes)
        }
      }
      if pending.node.kind == .text {
        textBytes += pending.node.stringValue?.utf8.count ?? 0
        guard textBytes <= limits.maximumTextBytes else {
          throw BoundedXMLError.textSize(limit: limits.maximumTextBytes)
        }
      }
      if let children = pending.node.children {
        for child in children.reversed() {
          stack.append(Pending(node: child, depth: pending.depth + 1))
        }
      }
    }
  }
}

package enum BoundedXMLError: Error, LocalizedError, Equatable {
  case inputSize(actual: Int, limit: Int)
  case entityDeclaration
  case malformed(String)
  case depth(limit: Int)
  case nodeCount(limit: Int)
  case attributeCount(limit: Int)
  case textSize(limit: Int)

  package var errorDescription: String? {
    switch self {
    case .inputSize(let actual, let limit):
      "XML input is \(actual) bytes, above the \(limit)-byte limit."
    case .entityDeclaration:
      "XML entity declarations and internal document subsets are not allowed."
    case .malformed(let reason):
      "XML is malformed: \(reason)"
    case .depth(let limit):
      "XML nesting exceeds the limit of \(limit)."
    case .nodeCount(let limit):
      "XML node count exceeds the limit of \(limit)."
    case .attributeCount(let limit):
      "XML attribute count exceeds the limit of \(limit)."
    case .textSize(let limit):
      "XML text exceeds the \(limit)-byte limit."
    }
  }
}

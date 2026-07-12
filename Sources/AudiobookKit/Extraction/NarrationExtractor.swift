import Foundation

/// One spine document reduced to narratable paragraphs.
struct ExtractedDocument {
  let paragraphs: [String]
  /// True when tier-1/2 note filtering removed at least one subtree. Together
  /// with `paragraphs.isEmpty` this is the tier-3 "notes-only file" signal
  /// (the Three-Body case: footnote files that are linear in the spine).
  let droppedNoteContent: Bool
  /// First h1–h6 text (≤ 80 chars), for synthetic chapter titles.
  let firstHeading: String?

  var characterCount: Int { paragraphs.reduce(0) { $0 + $1.count } }
  var isNotesOnly: Bool { paragraphs.isEmpty && droppedNoteContent }
}

/// Walks an XHTML body and extracts prose paragraphs, dropping markup,
/// media, page anchors, and (via NoteDetection) footnote apparatus.
enum NarrationExtractor {
  /// Elements whose entire subtree is never narrated.
  private static let droppedElements: Set<String> = [
    "style", "script", "head", "img", "image", "svg", "figure", "figcaption",
    "hr", "video", "audio", "object", "iframe", "canvas", "form", "nav",
    "template", "noscript", "input", "button", "select", "textarea", "map",
  ]

  /// Elements that contribute text to the current paragraph without starting
  /// a new one. Anything else (and any unknown element) is a block boundary.
  private static let inlineElements: Set<String> = [
    "a", "abbr", "b", "bdi", "bdo", "cite", "code", "data", "dfn", "em", "i",
    "kbd", "mark", "q", "ruby", "rt", "rp", "s", "samp", "small", "span",
    "strong", "sub", "sup", "time", "u", "var", "wbr", "del", "ins",
  ]

  nonisolated(unsafe) private static let pageAnchorID = /^page[_-]?\d+$/.ignoresCase()

  static func extract(from document: XMLDocument) -> ExtractedDocument {
    guard let root = document.rootElement(),
      let body = firstDescendant(named: "body", in: root)
    else {
      return ExtractedDocument(paragraphs: [], droppedNoteContent: false, firstHeading: nil)
    }

    var state = WalkState()
    walk(body, state: &state)
    state.flush()

    return ExtractedDocument(
      paragraphs: state.paragraphs,
      droppedNoteContent: state.droppedNoteContent,
      firstHeading: state.firstHeading)
  }

  private struct WalkState {
    var paragraphs: [String] = []
    var buffer = ""
    var droppedNoteContent = false
    var firstHeading: String?

    mutating func flush() {
      let text = buffer.collapsingWhitespace()
      buffer = ""
      if !text.isEmpty { paragraphs.append(text) }
    }
  }

  private static func walk(_ node: XMLNode, state: inout WalkState) {
    if node.kind == .text {
      state.buffer += node.stringValue ?? ""
      return
    }
    guard let element = node as? XMLElement else { return }
    let name = element.localName?.lowercased() ?? ""

    if droppedElements.contains(name) {
      return
    }
    if name == "br" {
      state.buffer += " "
      return
    }
    if let id = element.attribute(forName: "id")?.stringValue,
      id.wholeMatch(of: pageAnchorID) != nil,
      element.collapsedText.isEmpty
    {
      return
    }
    if NoteDetection.isNoteElement(element) {
      state.droppedNoteContent = true
      return
    }

    if inlineElements.contains(name) {
      for child in element.children ?? [] { walk(child, state: &state) }
      return
    }

    // Block boundary: flush the running paragraph on both sides so sibling
    // blocks (and text between them) become separate paragraphs.
    state.flush()
    for child in element.children ?? [] { walk(child, state: &state) }
    state.flush()

    if state.firstHeading == nil, name.count == 2, name.hasPrefix("h"),
      ("1"..."6").contains(String(name.dropFirst()))
    {
      let text = element.collapsedText
      if !text.isEmpty, text.count <= 80 { state.firstHeading = text }
    }
  }

  private static func firstDescendant(named localName: String, in root: XMLElement) -> XMLElement?
  {
    var stack: [XMLNode] = [root]
    while let node = stack.popLast() {
      if let element = node as? XMLElement, element.localName?.lowercased() == localName {
        return element
      }
      stack.append(contentsOf: (node.children ?? []).reversed())
    }
    return nil
  }
}

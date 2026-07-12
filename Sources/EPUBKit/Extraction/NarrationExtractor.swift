import Foundation
import PublicationKit

/// One spine document reduced to narratable paragraphs.
struct ExtractedDocument {
  let blocks: [PublicationBlock]
  /// True when tier-1/2 note filtering removed at least one subtree. Together
  /// with `paragraphs.isEmpty` this is the tier-3 "notes-only file" signal
  /// (the Three-Body case: footnote files that are linear in the spine).
  let droppedNoteContent: Bool
  /// First h1–h6 text (≤ 80 chars), for synthetic chapter titles.
  let firstHeading: String?

  var paragraphs: [String] { blocks.map(\.text) }
  var characterCount: Int { blocks.reduce(0) { $0 + $1.text.count } }
  var isNotesOnly: Bool { blocks.isEmpty && droppedNoteContent }
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

  static func extract(from document: XMLDocument, documentID: String = "document") -> ExtractedDocument {
    guard let root = document.rootElement(),
      let body = firstDescendant(named: "body", in: root)
    else {
      return ExtractedDocument(blocks: [], droppedNoteContent: false, firstHeading: nil)
    }

    var state = WalkState(documentID: documentID)
    walk(body, state: &state)
    state.flush()

    return ExtractedDocument(
      blocks: state.blocks,
      droppedNoteContent: state.droppedNoteContent,
      firstHeading: state.firstHeading)
  }

  private struct WalkState {
    let documentID: String
    var blocks: [PublicationBlock] = []
    var buffer = ""
    var bufferFragmentID: String?
    var preferredFragmentID: String?
    var pendingFragmentID: String?
    var droppedNoteContent = false
    var firstHeading: String?

    mutating func flush() {
      let text = buffer.collapsingWhitespace()
      buffer = ""
      let fragmentID = bufferFragmentID
      bufferFragmentID = nil
      if !text.isEmpty {
        blocks.append(
          PublicationBlock(
            text: text,
            locator: SourceLocator(
              documentID: documentID,
              fragmentID: fragmentID,
              blockIndex: blocks.count)))
        if fragmentID == pendingFragmentID { pendingFragmentID = nil }
      }
    }
  }

  private static func walk(_ node: XMLNode, state: inout WalkState) {
    if node.kind == .text {
      if state.buffer.isEmpty {
        state.bufferFragmentID = state.preferredFragmentID ?? state.pendingFragmentID
      }
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
      let blockCount = state.blocks.count
      let bufferWasEmpty = state.buffer.isEmpty
      let previousFragment = state.preferredFragmentID
      let elementID = element.attribute(forName: "id")?.stringValue
      if let id = elementID, !id.isEmpty {
        state.preferredFragmentID = id
      }
      for child in element.children ?? [] { walk(child, state: &state) }
      state.preferredFragmentID = previousFragment
      if bufferWasEmpty, state.buffer.isEmpty, state.blocks.count == blockCount,
        let elementID, !elementID.isEmpty
      {
        state.pendingFragmentID = elementID
      }
      return
    }

    // Block boundary: flush the running paragraph on both sides so sibling
    // blocks (and text between them) become separate paragraphs.
    state.flush()
    let blockCount = state.blocks.count
    let previousFragment = state.preferredFragmentID
    let elementID = element.attribute(forName: "id")?.stringValue
    if let id = elementID, !id.isEmpty {
      state.preferredFragmentID = id
    }
    for child in element.children ?? [] { walk(child, state: &state) }
    state.flush()
    state.preferredFragmentID = previousFragment
    if state.blocks.count == blockCount, let elementID, !elementID.isEmpty {
      state.pendingFragmentID = elementID
    }

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

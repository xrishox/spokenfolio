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
  let warnings: [String]

  var paragraphs: [String] { blocks.map(\.text) }
  var characterCount: Int { blocks.reduce(0) { $0 + $1.text.count } }
  var isNotesOnly: Bool { blocks.isEmpty && droppedNoteContent }
}

/// Walks an XHTML body and extracts prose paragraphs, dropping markup,
/// media, page anchors, and (via NoteDetection) footnote apparatus.
enum NarrationExtractor {
  // XML 1.0 forbids this control scalar, so a successfully parsed XHTML
  // document cannot contain it as authored prose. It never leaves this file.
  private static let omissionMarker = "\u{001D}"

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

  /// Visual list markers and scene-break decoration are structure, not prose:
  /// a human narrator never speaks them, and the Siri voice verbalizes some
  /// (measured: every "• " appendix entry of A Dance with Dragons reached the
  /// synthesized audio as a spoken "comma", which then poisoned transcript
  /// alignment for entire appendix documents). Bullets are stripped from the
  /// front of a token; a token made only of decoration glyphs is dropped.
  /// Deliberately conservative: middle dots stay (Catalan "l·l", Japanese
  /// "・") and decoration attached to prose stays (emphasis asterisks,
  /// noteref daggers) unless the whole token is decoration.
  private static let bulletScalars = CharacterSet(charactersIn: "•◦▪▫‣⁃∙❖")
  private static let decorationScalars = CharacterSet(charactersIn: "•◦▪▫‣⁃∙❖*✱✳⁂❧❦✦✧†‡※~＊")

  private static func strippingDecoration(_ text: String) -> String {
    guard
      text.unicodeScalars.contains(where: { decorationScalars.contains($0) })
    else { return text }
    return text.split(whereSeparator: \.isWhitespace)
      .compactMap { token -> Substring? in
        var token = token
        while let first = token.unicodeScalars.first, bulletScalars.contains(first) {
          token = token.dropFirst()
        }
        guard !token.isEmpty else { return nil }
        if token.unicodeScalars.allSatisfy({ decorationScalars.contains($0) }) { return nil }
        return token
      }
      .joined(separator: " ")
  }

  static func extract(
    from document: XMLDocument, documentID: String = "document",
    apparatusClasses: Set<String> = []
  ) -> ExtractedDocument {
    guard let root = document.rootElement(),
      let body = firstDescendant(named: "body", in: root)
    else {
      return ExtractedDocument(
        blocks: [], droppedNoteContent: false, firstHeading: nil, warnings: [])
    }

    var state = WalkState(documentID: documentID)
    state.apparatusOmissions = ApparatusNumberDetection.elementsToOmit(
      body: body, apparatusClasses: apparatusClasses)
    state.citationTableOmissions = CitationTableDetection.elementsToOmit(body: body)
    walk(body, state: &state)
    state.flush()

    var blocks = state.blocks
    var warnings: [String] = []
    let primaryIsSubstantial = isSubstantial(blocks)
    let fallbackIsSubstantial = isSubstantial(state.hiddenFallbackBlocks)
    if !primaryIsSubstantial, fallbackIsSubstantial, state.sawMedia {
      blocks = state.hiddenFallbackBlocks
      warnings.append(
        "using a hidden text layer in '\(documentID)' because its primary representation is media-only")
    } else if primaryIsSubstantial, fallbackIsSubstantial {
      warnings.append(
        "ignored a substantial hidden alternate text layer in '\(documentID)' to avoid duplicate narration")
    } else if blocks.isEmpty, state.sawMedia {
      warnings.append("media-only document '\(documentID)' has no usable narration text")
    }
    blocks = GluedMarkerDetection.strippingMarkers(blocks)

    return ExtractedDocument(
      blocks: blocks,
      droppedNoteContent: state.droppedNoteContent,
      firstHeading: state.firstHeading,
      warnings: warnings)
  }

  private static func isSubstantial(_ blocks: [PublicationBlock]) -> Bool {
    let text = blocks.map(\.text).joined(separator: " ")
    let letters = text.unicodeScalars.lazy.filter { CharacterSet.letters.contains($0) }.count
    let words = text.split(whereSeparator: { $0.isWhitespace }).count
    return letters >= 40 && words >= 8
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
    var hiddenFallbackBlocks: [PublicationBlock] = []
    var sawMedia = false
    var isHiddenFallback = false
    var apparatusOmissions: Set<ObjectIdentifier> = []
    var citationTableOmissions: Set<ObjectIdentifier> = []

    mutating func flush() {
      let text = NarrationExtractor.normalizeNarrationBuffer(buffer)
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

  private static func walk(
    _ node: XMLNode, state: inout WalkState, ignoreHiddenOnCurrent: Bool = false
  ) {
    if node.kind == .text {
      if state.buffer.isEmpty {
        state.bufferFragmentID = state.preferredFragmentID ?? state.pendingFragmentID
      }
      state.buffer += node.stringValue ?? ""
      return
    }
    guard let element = node as? XMLElement else { return }
    if state.apparatusOmissions.contains(ObjectIdentifier(element)) {
      // The omission marker lets the punctuation repair decide spacing
      // contextually: a marker between a period and a closing paren
      // ("publication.<sup>1</sup>)") leaves no stray space behind. The
      // dropped number may carry adjacent whitespace inside its own element
      // (NRSVue "<span> 2</span>"); surface it beside the marker so that
      // evidence still prevents neighboring words from fusing.
      let interior = element.stringValue ?? ""
      if interior.first?.isWhitespace == true { state.buffer += " " }
      state.buffer += omissionMarker
      if interior.last?.isWhitespace == true { state.buffer += " " }
      return
    }
    if state.citationTableOmissions.contains(ObjectIdentifier(element)) {
      // Citation tables and their labels are note apparatus: block-level,
      // so no gluing repair is needed, and a document reduced to nothing by
      // this drop classifies as notes-only.
      state.droppedNoteContent = true
      return
    }
    let name = element.localName?.lowercased() ?? ""

    if droppedElements.contains(name) {
      if ["img", "image", "svg", "figure", "video", "audio", "object", "canvas"].contains(name) {
        state.sawMedia = true
      }
      return
    }
    if isAuthoritativelyHidden(element) { return }
    if !ignoreHiddenOnCurrent, isVisuallyHidden(element) {
      var fallback = WalkState(documentID: state.documentID)
      fallback.isHiddenFallback = true
      walk(element, state: &fallback, ignoreHiddenOnCurrent: true)
      fallback.flush()
      state.hiddenFallbackBlocks.append(contentsOf: fallback.blocks)
      state.sawMedia = state.sawMedia || fallback.sawMedia
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
    switch NoteDetection.disposition(of: element) {
    case .inlineReference:
      state.droppedNoteContent = true
      state.buffer += omissionMarker
      return
    case .noteContent:
      state.droppedNoteContent = true
      return
    case .silentStructure: return
    case .keep: break
    }

    if inlineElements.contains(name) {
      let blockCount = state.blocks.count
      let bufferCount = state.buffer.count
      let bufferWasEmpty = state.buffer.isEmpty
      let previousFragment = state.preferredFragmentID
      let elementID = element.attribute(forName: "id")?.stringValue
      if let id = elementID, !id.isEmpty {
        state.preferredFragmentID = id
      }
      for child in element.children ?? [] { walk(child, state: &state) }
      if state.isHiddenFallback, state.buffer.count == bufferCount,
        isPositionedSpace(element)
      {
        state.buffer += " "
      }
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

  private static func isAuthoritativelyHidden(_ element: XMLElement) -> Bool {
    element.attribute(forName: "aria-hidden")?.stringValue?.lowercased() == "true"
  }

  private static func isVisuallyHidden(_ element: XMLElement) -> Bool {
    if element.attribute(forName: "hidden") != nil { return true }
    guard let style = element.attribute(forName: "style")?.stringValue?.lowercased() else {
      return false
    }
    return style.firstMatch(of: /display\s*:\s*none/) != nil
      || style.firstMatch(of: /visibility\s*:\s*hidden/) != nil
  }

  /// Fixed-layout OCR layers commonly encode a word gap as an empty
  /// `inline-block` span with a width. XML parsers may discard its
  /// whitespace-only text node, so recover that structural space only while
  /// walking a hidden alternate representation.
  private static func isPositionedSpace(_ element: XMLElement) -> Bool {
    guard element.collapsedText.isEmpty,
      let style = element.attribute(forName: "style")?.stringValue?.lowercased()
    else { return false }
    return style.firstMatch(of: /display\s*:\s*inline-block/) != nil
      && style.firstMatch(of: /width\s*:\s*[1-9][0-9]*(?:\.[0-9]+)?(?:px|pt|em|rem|%)/) != nil
  }

  private static func normalizeNarrationBuffer(_ source: String) -> String {
    // The private engine treats a "[[…]]" group as deletion markup: the
    // words inside are silently dropped mid-utterance, and an utterance
    // that is entirely wrapped is refused (probe-verified). NRSVue uses
    // [[…]] as textual-variant apparatus around real prose, so adjacent
    // bracket runs collapse to a single bracket — which the engine accepts
    // silently while speaking the words. Balanced nested closers are
    // untouched: in "π[C-1[x]]" every "]" closes a distinct earlier "[",
    // so the math survives byte-identical.
    let source = collapsingBracketRuns(source)
    guard source.contains(omissionMarker) else {
      return strippingDecoration(source.collapsingWhitespace())
    }
    var value = source
    let escaped = NSRegularExpression.escapedPattern(for: omissionMarker)
    // Separators a marker chain may span: "7,8" verse pairs, "1-3" ranges.
    // The em-dash is deliberately absent — between two markers it is prose
    // punctuation ("…the dry)—<verse>the LORD…"), never chain syntax, and
    // absorbing it would delete it from the narration.
    let separators = #"\s*[,;:/\-–]\s*"#
    let cluster = "\(escaped)(?:\(separators)\(escaped))*"
    let pairs: [(String, String)] = [
      (#"\("#, #"\)"#), (#"\["#, #"\]"#), (#"\{"#, #"\}"#),
      ("⟨", "⟩"), ("〈", "〉"), ("【", "】"), ("〔", "〕"),
      ("（", "）"), ("［", "］"),
    ]
    var changed = true
    while changed {
      changed = false
      for (open, close) in pairs {
        let pattern = "\(open)\\s*\(cluster)\\s*\(close)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
        let range = NSRange(value.startIndex..., in: value)
        let next = regex.stringByReplacingMatches(
          in: value, range: range, withTemplate: omissionMarker)
        if next != value {
          value = next
          changed = true
        }
      }
      if let regex = try? NSRegularExpression(pattern: cluster) {
        let range = NSRange(value.startIndex..., in: value)
        let next = regex.stringByReplacingMatches(
          in: value, range: range, withTemplate: omissionMarker)
        if next != value {
          value = next
          changed = true
        }
      }
    }

    let parts = value.components(separatedBy: omissionMarker)
    var result = parts.first ?? ""
    // Space evidence must come from the raw part boundaries: `result` is
    // trimmed at every join, so a space that sat before the next marker
    // would otherwise be forgotten and words across a removed noteref fuse
    // ("found.)Verse" / "himself.Solomon").
    var rawTailHadSpace = (parts.first ?? "").last?.isWhitespace == true
    for part in parts.dropFirst() {
      let leftHadSpace = rawTailHadSpace
      let rightHadSpace = part.first?.isWhitespace == true
      rawTailHadSpace =
        part.last?.isWhitespace == true
        || (part.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && leftHadSpace)
      result = result.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
      let right = part.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
      let leftCharacter = result.last
      let rightCharacter = right.first
      let closing = CharacterSet(charactersIn: ".,;:!?%)]}”’⟩〉】〕）］")
      let opening = CharacterSet(charactersIn: "([{“‘⟨〈【〔（［")
      let rightIsClosing = rightCharacter?.unicodeScalars.allSatisfy(closing.contains) == true
      let leftIsOpening = leftCharacter?.unicodeScalars.allSatisfy(opening.contains) == true
      let alphanumeric = CharacterSet.alphanumerics
      let bothWords =
        leftCharacter?.unicodeScalars.allSatisfy(alphanumeric.contains) == true
        && rightCharacter?.unicodeScalars.allSatisfy(alphanumeric.contains) == true
      // A marker between a sentence end and the next sentence's first letter
      // ("Morgan.<sup>4</sup>Therefore") must restore the inter-sentence
      // space even without whitespace evidence. Letters only: a marker can
      // never legitimately split a decimal, so digits stay untouched.
      let sentenceBoundary =
        ".!?…".contains(leftCharacter ?? " ")
        && rightCharacter?.isLetter == true
      if !result.isEmpty, !right.isEmpty, !rightIsClosing, !leftIsOpening,
        bothWords || leftHadSpace || rightHadSpace || sentenceBoundary
      { result += " " }
      result += right
    }
    return strippingDecoration(result.collapsingWhitespace())
  }

  private static func collapsingBracketRuns(_ text: String) -> String {
    guard text.contains("[[") || text.contains("]]") else { return text }
    var result = ""
    var depth = 0
    var previous: Character?
    for character in text {
      if character == "[" {
        if previous == "[" {
          previous = character
          continue  // collapse the run: "[[7When…" opens once
        }
        depth += 1
      } else if character == "]" {
        if previous == "]", depth == 0 {
          previous = character
          continue  // closer with nothing left to close came from a run
        }
        if depth > 0 { depth -= 1 }
      }
      result.append(character)
      previous = character
    }
    return result
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

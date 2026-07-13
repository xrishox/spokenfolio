import Foundation

/// Tiered detection of footnotes, endnotes, and their inline markers.
///
/// Tier 1 is the EPUB 3 semantic vocabulary and is always authoritative.
/// Tier 2 heuristics cover EPUB 2 books without semantics; every tier-2 rule
/// requires a conjunction of signals so ordinary prose links survive.
enum NoteDetection {
  enum Disposition: Equatable {
    case keep
    /// A short marker embedded in prose. Its omission participates in local
    /// punctuation repair, unlike a whole note body.
    case inlineReference
    /// Footnote/endnote content whose complete subtree is secondary apparatus.
    case noteContent
    /// Non-prose structure such as a pagebreak or sidebar.
    case silentStructure
  }

  /// `epub:type` tokens whose subtree is never narrated. Includes the
  /// section-level plurals and `pagebreak`/`sidebar`, which are not notes but
  /// are equally non-narratable.
  private static let inlineEpubTypes: Set<String> = ["noteref", "backlink"]
  private static let noteContentEpubTypes: Set<String> = [
    "footnote", "footnotes", "endnote", "endnotes", "rearnote", "rearnotes",
  ]
  private static let silentEpubTypes: Set<String> = ["annotation", "sidebar", "pagebreak"]

  private static let inlineRoles: Set<String> = ["doc-noteref", "doc-backlink"]
  private static let noteContentRoles: Set<String> = ["doc-footnote", "doc-endnote"]
  private static let silentRoles: Set<String> = ["doc-pagebreak"]

  private static let noteClassTokens: Set<String> = ["footnote", "endnote", "fn", "note"]

  private static let backlinkGlyphs: Set<Character> = ["↩", "↑", "⬆", "←", "⏎"]

  nonisolated(unsafe) private static let markerText = /^\[?\d{1,4}\]?$|^[*†‡§¶]+$/
  nonisolated(unsafe) private static let noteTarget = /fn|foot|note|endnote|annot|\bref/.ignoresCase()
  nonisolated(unsafe) private static let noteID = /^(fn|footnote|endnote|note)[-_]?\w*\d+$/.ignoresCase()

  /// True when the element and its subtree must be dropped from narration.
  static func isNoteElement(_ element: XMLElement) -> Bool {
    disposition(of: element) != .keep
  }

  static func disposition(of element: XMLElement) -> Disposition {
    // Tier 1: semantic markup.
    if !element.epubTypeTokens.isDisjoint(with: inlineEpubTypes)
      || !element.roleTokens.isDisjoint(with: inlineRoles)
    { return .inlineReference }
    if !element.epubTypeTokens.isDisjoint(with: noteContentEpubTypes)
      || !element.roleTokens.isDisjoint(with: noteContentRoles)
    { return .noteContent }
    if !element.epubTypeTokens.isDisjoint(with: silentEpubTypes)
      || !element.roleTokens.isDisjoint(with: silentRoles)
    { return .silentStructure }

    let name = element.localName ?? ""

    // Tier 2a: <sup> wrapping a lone fragment-target anchor.
    if name == "sup" {
      let childElements = (element.children ?? []).compactMap { $0 as? XMLElement }
      if childElements.count == 1, childElements[0].localName == "a",
        let href = childElements[0].attribute(forName: "href")?.stringValue,
        href.contains("#"), element.collapsedText.wholeMatch(of: markerText) != nil
      {
        return .inlineReference
      }
    }

    if name == "a" {
      let text = element.collapsedText
      // Tier 2b: marker-shaped anchor text pointing at a note-shaped target.
      if text.wholeMatch(of: markerText) != nil,
        let href = element.attribute(forName: "href")?.stringValue
      {
        let fragment = href.split(separator: "#", maxSplits: 1).dropFirst().first ?? ""
        let file = href.split(separator: "#", maxSplits: 1).first ?? ""
        let target = file.split(separator: "/").last ?? ""
        if fragment.firstMatch(of: noteTarget) != nil || target.firstMatch(of: noteTarget) != nil {
          return .inlineReference
        }
      }
      // Tier 2d: a lone backlink glyph.
      if text.count == 1, let character = text.first, backlinkGlyphs.contains(character) {
        return .inlineReference
      }
    }

    // Tier 2c: note-shaped id plus a corroborating signal.
    if let id = element.attribute(forName: "id")?.stringValue,
      id.wholeMatch(of: noteID) != nil
    {
      if !element.classTokens.isDisjoint(with: noteClassTokens) { return .noteContent }
      if subtreeContainsBacklink(element) { return .noteContent }
    }

    return .keep
  }

  private static func subtreeContainsBacklink(_ root: XMLElement) -> Bool {
    var stack: [XMLNode] = [root]
    while let node = stack.popLast() {
      if let element = node as? XMLElement, element.localName == "a",
        element.attribute(forName: "href") != nil,
        element.collapsedText.contains(where: { backlinkGlyphs.contains($0) })
      {
        return true
      }
      stack.append(contentsOf: node.children ?? [])
    }
    return false
  }
}

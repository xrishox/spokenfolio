import Foundation

/// Detects numbering apparatus: sequences of bare numbers isolated in their
/// own styled inline elements — scripture verse numbers, superscripted
/// endnote markers, poetry line numbers. Narrators never speak these, and the
/// synthesized audio must not contain them.
///
/// The rule is a strict conjunction, so ordinary books are structurally out
/// of reach: a number must be (1) alone inside its own inline element —
/// prose numbers are plain text nodes and can never match; (2) styled as
/// apparatus (a `sup` element, or superscript/reduced-size styling from an
/// inline style or a single-class stylesheet rule); (3) part of a dense,
/// mostly ascending run of at least five within one document — a lone inline
/// chapter number can never match; and (4) not glued to a preceding word
/// character — exponents and subscripted math can never match.
///
/// Calibrated against a 175-book corpus: fires only on scripture verse
/// numbers and superscripted endnote markers; the one near-miss (subscripted
/// math variables in Antifragile) is kept by the sequence requirement.
enum ApparatusNumberDetection {
  private static let inlineNames: Set<String> = [
    "span", "sup", "b", "strong", "i", "em", "small", "a",
  ]
  private static let skippedNames: Set<String> = ["head", "script", "style", "aside"]
  private static let minimumRun = 5
  private static let minimumAscendingFraction = 0.8
  private static let minimumStyledFraction = 0.8
  nonisolated(unsafe) private static let bareNumber = /\d{1,3}/

  /// Stylesheet classes whose single-class rules render apparatus text
  /// (superscript or clearly reduced size). Deliberately simple parsing:
  /// only `.name { ... }` rules are considered, which is how publisher and
  /// conversion tooling emit these styles.
  static func apparatusClasses(css: String) -> Set<String> {
    var result: Set<String> = []
    for match in css.matches(of: /\.([A-Za-z0-9_-]+)\s*\{([^}]*)\}/) {
      if isApparatusStyle(String(match.2).lowercased()) {
        result.insert(String(match.1))
      }
    }
    return result
  }

  private static func isApparatusStyle(_ body: String) -> Bool {
    if body.firstMatch(of: /vertical-align\s*:\s*(super|text-top)/) != nil { return true }
    if let match = body.firstMatch(of: /font-size\s*:\s*(0?\.\d+)\s*em/),
      let size = Double(match.1), size <= 0.85
    {
      return true
    }
    return false
  }

  static func elementsToOmit(
    body: XMLElement, apparatusClasses: Set<String>
  ) -> Set<ObjectIdentifier> {
    var groups: [GroupKey: [Candidate]] = [:]
    var lastCharacter: Character?
    var position = 0
    collect(
      body, groups: &groups, lastCharacter: &lastCharacter, position: &position,
      apparatusClasses: apparatusClasses)
    var omissions: Set<ObjectIdentifier> = []
    var fired: [Candidate] = []
    var held: [[Candidate]] = []
    for members in groups.values {
      guard members.count >= minimumRun, mostlyAscending(members.map(\.value)) else { continue }
      let styled = members.count(where: \.styled)
      if Double(styled) >= minimumStyledFraction * Double(members.count) {
        fired.append(contentsOf: members)
      } else {
        held.append(members)
      }
    }
    guard !fired.isEmpty else { return [] }
    omissions.formUnion(fired.map(\.id))
    // A numbering system can mix styles (NRSVue: superscript mid-paragraph
    // verse numbers, bold paragraph-initial ones). An unstyled group joins
    // the apparatus only when a styled group in the same document already
    // fired on its own AND merging the two preserves one ascending sequence
    // in document order — so a document without independent apparatus
    // evidence is unreachable by this extension.
    for group in held {
      let merged = (fired + group).sorted { $0.position < $1.position }
      if mostlyAscending(merged.map(\.value)) {
        omissions.formUnion(group.map(\.id))
      }
    }
    return omissions
  }

  private static func mostlyAscending(_ numbers: [Int]) -> Bool {
    guard numbers.count > 1 else { return true }
    let ascendingSteps = zip(numbers, numbers.dropFirst()).count { $1 > $0 }
    return Double(ascendingSteps) >= minimumAscendingFraction * Double(numbers.count - 1)
  }

  private struct GroupKey: Hashable {
    var name: String
    var classAttribute: String
  }

  private struct Candidate {
    var id: ObjectIdentifier
    var value: Int
    var styled: Bool
    var position: Int
  }

  private static func collect(
    _ node: XMLNode, groups: inout [GroupKey: [Candidate]],
    lastCharacter: inout Character?, position: inout Int,
    apparatusClasses: Set<String>
  ) {
    if node.kind == .text {
      if let last = (node.stringValue ?? "").last(where: { !$0.isWhitespace }) {
        lastCharacter = last
      }
      return
    }
    guard let element = node as? XMLElement else { return }
    let name = element.localName?.lowercased() ?? ""
    if skippedNames.contains(name) { return }

    if inlineNames.contains(name),
      !(name == "a" && element.attribute(forName: "href") != nil),
      element.children?.allSatisfy({ $0.kind == .text }) ?? false
    {
      let text = element.collapsedText
      if let match = text.wholeMatch(of: bareNumber), let value = Int(match.0),
        lastCharacter?.isLetter != true, lastCharacter?.isNumber != true
      {
        let classAttribute = element.attribute(forName: "class")?.stringValue ?? ""
        let styled =
          name == "sup"
          || classAttribute.split(separator: " ").contains {
            apparatusClasses.contains(String($0))
          }
          || isApparatusStyle(
            element.attribute(forName: "style")?.stringValue?.lowercased() ?? "")
        groups[GroupKey(name: name, classAttribute: classAttribute), default: []]
          .append(
            Candidate(
              id: ObjectIdentifier(element), value: value, styled: styled,
              position: position))
        position += 1
        lastCharacter = text.last
        return
      }
    }
    // Glued-ness is a property of one continuous text run: entering or
    // leaving a block element breaks adjacency (a heading ending in a digit
    // must not exponent-guard the first verse number of the next paragraph).
    let isInline = inlineNames.contains(name)
    if !isInline { lastCharacter = nil }
    for child in element.children ?? [] {
      collect(
        child, groups: &groups, lastCharacter: &lastCharacter, position: &position,
        apparatusClasses: apparatusClasses)
    }
    if !isInline { lastCharacter = nil }
  }
}

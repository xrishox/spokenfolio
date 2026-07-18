import Foundation

/// Detects endnote citation tables: publisher tooling renders chapter
/// endnotes as tables whose rows pair a backlink anchor number with the
/// citation text (`<td><a href="…#x">1</a></td><td>Author, Title…</td>`).
/// Table cells otherwise become independent narration blocks, so these
/// tables narrate as thousands of bare numbers, URLs, and "Ibid." lines.
///
/// The rule is a strict conjunction: a table is a citation table only when
/// (1) every data row's first cell is exactly a 1–4-digit number wrapped in
/// a fragment-target anchor — data tables and numbered how-to lists never
/// anchor their numbers; (2) the document's citation rows form a dense,
/// mostly ascending run of at least five. A block element immediately
/// before a fired table whose entire text is an apparatus label ("Endnotes",
/// "Notes", …) is part of the same apparatus.
enum CitationTableDetection {
  private static let minimumRun = 5
  private static let minimumAscendingFraction = 0.8
  /// A long endnotes table may have a final row whose number lost its
  /// backlink anchor; numeric anchor-less rows join only while anchored
  /// rows dominate, mirroring the styled-fraction rule in
  /// `ApparatusNumberDetection`.
  private static let minimumAnchoredFraction = 0.8
  private static let labels: Set<String> = [
    "notes", "endnotes", "footnotes", "references", "citations", "sources",
  ]
  nonisolated(unsafe) private static let bareNumber = /\d{1,4}\.?/

  static func elementsToOmit(body: XMLElement) -> Set<ObjectIdentifier> {
    var tables: [(element: XMLElement, values: [Int])] = []
    collectTables(body, into: &tables)
    let fired = tables.filter { !$0.values.isEmpty }
    let values = fired.flatMap(\.values)
    guard values.count >= minimumRun, mostlyAscending(values) else { return [] }

    var omissions = Set(fired.map { ObjectIdentifier($0.element) })
    for (table, _) in fired {
      if let label = previousElementSibling(of: table),
        labels.contains(
          label.collapsedText.lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: ": ")))
      {
        omissions.insert(ObjectIdentifier(label))
      }
    }
    return omissions
  }

  /// A table qualifies only when every data row is citation-shaped; its
  /// ascending evidence is the first-cell numbers in document order.
  private static func collectTables(
    _ node: XMLNode, into tables: inout [(element: XMLElement, values: [Int])]
  ) {
    guard let element = node as? XMLElement else { return }
    if element.localName?.lowercased() == "table" {
      var values: [Int] = []
      var anchored = 0
      var rows = 0
      for row in descendants(named: "tr", in: element) {
        rows += 1
        guard let cell = citationRowValue(row) else {
          return  // a non-numeric first cell disqualifies the whole table
        }
        values.append(cell.value)
        if cell.anchored { anchored += 1 }
      }
      if rows > 0, Double(anchored) >= minimumAnchoredFraction * Double(rows) {
        tables.append((element, values))
      } else if rows > 0 {
        tables.append((element, []))
      }
      return
    }
    for child in element.children ?? [] { collectTables(child, into: &tables) }
  }

  /// First cell must be exactly a bare number; `anchored` reports whether
  /// it is wrapped in a fragment-target anchor.
  private static func citationRowValue(_ row: XMLElement) -> (value: Int, anchored: Bool)? {
    guard let first = descendants(named: "td", in: row).first
        ?? descendants(named: "th", in: row).first
    else { return nil }
    let text = first.collapsedText
    guard text.wholeMatch(of: bareNumber) != nil,
      let value = Int(text.hasSuffix(".") ? String(text.dropLast()) : text)
    else { return nil }
    let anchored = !descendants(named: "a", in: first)
      .filter { $0.attribute(forName: "href") != nil }.isEmpty
    return (value, anchored)
  }

  private static func descendants(named name: String, in root: XMLElement) -> [XMLElement] {
    var result: [XMLElement] = []
    var stack: [XMLNode] = (root.children ?? []).reversed()
    while let node = stack.popLast() {
      guard let element = node as? XMLElement else { continue }
      if element.localName?.lowercased() == name { result.append(element) }
      stack.append(contentsOf: (element.children ?? []).reversed())
    }
    return result
  }

  private static func previousElementSibling(of element: XMLElement) -> XMLElement? {
    var node: XMLNode? = element.previousSibling
    while let current = node {
      if let sibling = current as? XMLElement { return sibling }
      if current.kind == .text,
        !(current.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      { return nil }
      node = current.previousSibling
    }
    return nil
  }

  private static func mostlyAscending(_ numbers: [Int]) -> Bool {
    guard numbers.count > 1 else { return true }
    let ascendingSteps = zip(numbers, numbers.dropFirst()).count { $1 > $0 }
    return Double(ascendingSteps) >= minimumAscendingFraction * Double(numbers.count - 1)
  }
}

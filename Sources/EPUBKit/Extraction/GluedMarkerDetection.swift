import Foundation
import PublicationKit

/// Removes plain-text endnote markers glued to sentence ends: `word.[12]`.
/// The plain-text twin of `ApparatusNumberDetection` — some conversions emit
/// note markers as literal bracketed numbers inside the prose text node,
/// where no element or styling exists to detect. Narrators never speak
/// these, and the synthesized audio must not contain them.
///
/// The rule is a strict conjunction, so ordinary books are structurally out
/// of reach: a marker chain must be (1) a bracketed 1–3-digit number —
/// year glosses like `[1945]` can never match; (2) glued directly after
/// sentence-final punctuation, optionally through closing quotes/brackets —
/// IEEE-style citations (`in [12] we…`), standalone `[12]` lines, and math
/// subscripts (`x[2]`) can never match; and (3) part of a dense, mostly
/// ascending run of at least five within one document — a lone quoted
/// `[3]` can never match.
enum GluedMarkerDetection {
  private static let minimumRun = 5
  private static let minimumAscendingFraction = 0.8
  /// Sentence-final punctuation, optional closers, then one or more
  /// bracketed 1–3-digit markers. Capture 1 is kept; capture 2 is removed.
  nonisolated(unsafe) private static let gluedChain =
    /([.?!…][”’"')\]]*)((?:\[\d{1,3}\])+)/

  static func strippingMarkers(_ blocks: [PublicationBlock]) -> [PublicationBlock] {
    var values: [Int] = []
    var matched = false
    for block in blocks {
      for match in block.text.matches(of: gluedChain) {
        matched = true
        for number in match.2.matches(of: /\d{1,3}/) {
          values.append(Int(number.0) ?? 0)
        }
      }
    }
    guard matched, values.count >= minimumRun, mostlyAscending(values) else {
      return blocks
    }
    return blocks.map { block in
      let stripped = block.text.replacing(gluedChain) { String($0.1) }
      guard stripped != block.text else { return block }
      return PublicationBlock(text: stripped, locator: block.locator)
    }
  }

  private static func mostlyAscending(_ numbers: [Int]) -> Bool {
    guard numbers.count > 1 else { return true }
    let ascendingSteps = zip(numbers, numbers.dropFirst()).count { $1 > $0 }
    return Double(ascendingSteps) >= minimumAscendingFraction * Double(numbers.count - 1)
  }
}

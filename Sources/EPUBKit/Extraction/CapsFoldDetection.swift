import Foundation
import PublicationKit

/// Folds presentational ALL-CAPS name occurrences to the book's own attested
/// mixed-case form. Measured private-engine behavior (probe records,
/// 2026-07-17): some out-of-vocabulary all-caps names are letter-spelled
/// ("SER" → S-E-R, "ALAYAYA" → letters) while their mixed-case twins are
/// always spoken correctly; common caps words are unaffected. The engine's
/// per-token choice is unpredictable, so the fix is evidence-gated folding,
/// never a lowercase rule.
///
/// An occurrence folds only when ALL hold:
/// 1. the token is all-caps with at least three letters;
/// 2. the book attests a twin — a dominant form of the same letters that is
///    neither all-caps nor all-lowercase — mid-sentence at least three
///    times ("Ser Godry" in prose), so "FBI" (no "Fbi" anywhere) can never
///    fold;
/// 3. the all-lowercase form never appears mid-sentence in the book, so
///    "WHO"/"MAY"/"LORD" (whose lowercase words are everywhere) can never
///    fold;
/// 4. the occurrence sits in one of the two evidenced presentational
///    shapes: a block that is exactly one caps token (the chapter-title
///    shape "ARYA", whose real-book audio came back "Uriah"), or a
///    block-initial caps run that is followed by non-caps content — the
///    roster shape ("SER GODRY FARRING, called…", "ALAYAYA, called Yaya…";
///    single-token runs additionally require a comma or dash terminator).
///    Everything else is preserved: whole-block caps prose ("UNTIL RAYSE
///    ARRIVED.", "CHAPTER TWENTY-ONE", "ROBERT JORDAN"), and any lone caps
///    token in running prose ("he joined the CIA", "a SAM battery").
enum CapsFoldDetection {
  private static let minimumTwinEvidence = 3
  private static let sentenceEnders = CharacterSet(charactersIn: ".!?…:;")

  struct BookEvidence {
    /// lowercased key -> attested twin form and its mid-sentence count.
    var twins: [String: (form: String, count: Int)] = [:]
    /// lowercased keys whose all-lowercase form appears mid-sentence.
    var lowercaseSeen: Set<String> = []
  }

  static func evidence(in extractions: [ExtractedDocument]) -> BookEvidence {
    var counts: [String: [String: Int]] = [:]  // key -> form -> midSentence count
    for extraction in extractions {
      for block in extraction.blocks {
        forEachToken(in: block.text) { token, midSentence in
          guard midSentence else { return }
          let letters = token.filter(\.isLetter)
          guard letters.count >= 3 else { return }
          counts[token.lowercased(), default: [:]][String(token), default: 0] += 1
        }
      }
    }
    var result = BookEvidence()
    for (key, forms) in counts {
      if forms.keys.contains(key) { result.lowercaseSeen.insert(key) }
      let candidates = forms.filter { form, _ in
        form != form.uppercased() && form != form.lowercased()
      }
      if let best = candidates.max(by: { $0.value < $1.value }),
        best.value >= minimumTwinEvidence
      {
        result.twins[key] = (best.key, best.value)
      }
    }
    return result
  }

  static func fold(_ extraction: ExtractedDocument, evidence: BookEvidence) -> ExtractedDocument {
    guard !evidence.twins.isEmpty else { return extraction }
    var changed = false
    let blocks = extraction.blocks.map { block -> PublicationBlock in
      let folded = foldBlock(block.text, evidence: evidence)
      guard folded != block.text else { return block }
      changed = true
      return PublicationBlock(text: folded, locator: block.locator)
    }
    guard changed else { return extraction }
    return ExtractedDocument(
      blocks: blocks,
      droppedNoteContent: extraction.droppedNoteContent,
      firstHeading: extraction.firstHeading,
      warnings: extraction.warnings)
  }

  private static func foldBlock(_ text: String, evidence: BookEvidence) -> String {
    let tokens = tokenize(text)
    guard !tokens.isEmpty else { return text }
    let capsFlags = tokens.map { isCapsToken($0.token) }
    var leadingRun = 0
    while leadingRun < tokens.count, capsFlags[leadingRun] { leadingRun += 1 }

    func followedByListPunctuation(_ index: Int) -> Bool {
      let after = text[tokens[index].range.upperBound...]
        .prefix { !$0.isLetter && !$0.isNumber }
      return after.contains { ",—–".contains($0) }
    }

    // The presentational unit is all-or-nothing at the word-class level: a
    // caps token whose lowercase form lives in the book's prose (AWOKE,
    // UNTIL, ONE) marks the unit as prose-set-in-caps — a first-line
    // convention, "CHAPTER ONE", or a carved epigraph — and vetoes every
    // fold in it. Evidence-less tokens (GODRY, YAYA) neither fold nor veto.
    func unitIndices(_ index: Int) -> Range<Int>? {
      if tokens.count == 1, capsFlags[0] { return 0..<1 }
      if index < leadingRun, leadingRun >= 2, leadingRun < tokens.count {
        return 0..<leadingRun
      }
      if index == 0, leadingRun == 1, tokens.count > 1, followedByListPunctuation(0) {
        return 0..<1
      }
      return nil
    }

    func unitVetoed(_ unit: Range<Int>) -> Bool {
      unit.contains { i in
        capsFlags[i] && evidence.lowercaseSeen.contains(tokens[i].token.lowercased())
      }
    }

    func foldable(_ index: Int) -> String? {
      guard capsFlags[index] else { return nil }
      let key = tokens[index].token.lowercased()
      guard let twin = evidence.twins[key], !evidence.lowercaseSeen.contains(key)
      else { return nil }
      guard let unit = unitIndices(index), !unitVetoed(unit) else { return nil }
      return twin.form
    }

    guard (0..<tokens.count).contains(where: { foldable($0) != nil }) else { return text }
    var result = text
    for index in (0..<tokens.count).reversed() {
      guard let twin = foldable(index) else { continue }
      result.replaceSubrange(tokens[index].range, with: twin)
    }
    return result
  }

  private static func isCapsToken(_ token: String) -> Bool {
    let letters = token.filter(\.isLetter)
    return letters.count >= 3 && letters == letters.uppercased()
      && letters != letters.lowercased()
  }

  private static func tokenize(_ text: String) -> [(token: String, range: Range<String.Index>)] {
    var result: [(String, Range<String.Index>)] = []
    var index = text.startIndex
    while index < text.endIndex {
      if text[index].isLetter {
        var end = index
        while end < text.endIndex, text[end].isLetter || "’'-".contains(text[end]) {
          end = text.index(after: end)
        }
        while end > index, "’'-".contains(text[text.index(before: end)]) {
          end = text.index(before: end)
        }
        result.append((String(text[index..<end]), index..<end))
        index = end
      } else {
        index = text.index(after: index)
      }
    }
    return result
  }

  /// Mid-sentence = not the first token of the text and not immediately
  /// after sentence-ending punctuation.
  private static func forEachToken(in text: String, _ body: (String, Bool) -> Void) {
    var previousEnder = true
    for (token, range) in tokenize(text) {
      var midSentence = !previousEnder
      if range.lowerBound == text.startIndex { midSentence = false }
      body(token, midSentence)
      let tail = text[range.upperBound...].prefix { !$0.isLetter }
      previousEnder = tail.contains { $0.unicodeScalars.allSatisfy(sentenceEnders.contains) }
    }
  }
}

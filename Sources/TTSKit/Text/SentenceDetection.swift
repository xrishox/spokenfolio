import NaturalLanguage

/// Split text into complete sentences and a trailing incomplete fragment.
///
/// Complete sentences are those whose last meaningful character is terminal punctuation,
/// optionally followed by closing quotes or brackets. The remainder is trimmed but otherwise
/// unmodified. Both callers and callee treat the remainder as work-in-progress
/// text that may be extended by future input.
///
/// Examples:
/// - `"Hello world. This is"` → complete: `["Hello world."]`, remainder: `"This is"`
/// - `"Hello. World!"` → complete: `["Hello.", "World!"]`, remainder: `""`
/// - `""` → complete: `[]`, remainder: `""`
package func splitCompleteSentences(_ text: String) -> (complete: [String], remainder: String) {
  guard !text.isEmpty else { return ([], "") }

  let tokenizer = NLTokenizer(unit: .sentence)
  tokenizer.string = text

  var sentences: [String] = []
  tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
    let s = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !s.isEmpty else { return true }
    sentences.append(s)
    return true
  }

  guard !sentences.isEmpty else { return ([], "") }

  guard let last = sentences.last else { return ([], "") }
  if hasTerminalPunctuation(last) {
    // Every sentence has terminal punctuation — all are complete
    return (sentences, "")
  } else {
    // Last sentence is an incomplete fragment
    return (Array(sentences.dropLast()), last)
  }
}

/// Split text into sentences without modifying punctuation.
///
/// Unlike `detectSentences()`, the trailing fragment is returned as-is — no period is appended.
/// Use this for engines (e.g. AVSpeechSynthesizer) that handle unterminated text natively and
/// would vocalize an appended period as "full stop".
///
/// Examples:
/// - `"Hello world"` → `["Hello world"]`
/// - `"Hello world."` → `["Hello world."]`
/// - `"Hello. World"` → `["Hello.", "World"]`
/// - `""` → `[]`
package func splitSentences(_ text: String) -> [String] {
  let (complete, remainder) = splitCompleteSentences(text)
  var result = complete
  if !remainder.isEmpty {
    result.append(remainder)
  }
  return result
}

/// Split text into sentences, ensuring every one ends with terminal punctuation.
///
/// This is a convenience wrapper over `splitCompleteSentences`: the incomplete remainder
/// (if any) has a period appended so that the caller receives only self-contained units.
///
/// Examples:
/// - `"Hello world."` → `["Hello world."]`
/// - `"Hello. World!"` → `["Hello.", "World!"]`
/// - `"Hello world"` → `["Hello world."]`
package func detectSentences(_ text: String) -> [String] {
  let (complete, remainder) = splitCompleteSentences(text)
  var result = complete
  if !remainder.isEmpty {
    result.append(appendingTerminalPeriod(to: remainder))
  }
  // Fallback: non-empty input that produced no tokens (shouldn't happen in practice)
  if result.isEmpty && !text.isEmpty {
    return [appendingTerminalPeriod(to: text)]
  }
  return result
}

private let sentenceClosingCharacters = CharacterSet(charactersIn: "\"'”’)]}»›")

private func hasTerminalPunctuation(_ sentence: String) -> Bool {
  for scalar in sentence.unicodeScalars.reversed() {
    if scalar.properties.isWhitespace || sentenceClosingCharacters.contains(scalar) { continue }
    return scalar == "." || scalar == "!" || scalar == "?" || scalar == "…"
  }
  return false
}

private func appendingTerminalPeriod(to text: String) -> String {
  var scalars = Array(text.unicodeScalars)
  var insertion = scalars.count
  while insertion > 0,
    scalars[insertion - 1].properties.isWhitespace
      || sentenceClosingCharacters.contains(scalars[insertion - 1])
  {
    insertion -= 1
  }
  scalars.insert(".", at: insertion)
  return String(String.UnicodeScalarView(scalars))
}

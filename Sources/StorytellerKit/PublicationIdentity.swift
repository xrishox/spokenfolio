import Foundation
import PublicationKit

package struct CanonicalPublicationIdentifier: Hashable, Sendable {
  package enum Kind: String, Sendable { case isbn13, asin, doi }
  package var kind: Kind
  package var value: String

  package init?(kind rawKind: String?, value rawValue: String) {
    let detected = Self.detectKind(rawKind, value: rawValue)
    let stripped = Self.stripPrefix(rawValue, kind: detected)
    switch detected {
    case .isbn13:
      guard let isbn = Self.canonicalISBN(stripped) else { return nil }
      kind = .isbn13
      value = isbn
    case .asin:
      let normalized = stripped.uppercased().filter { $0.isLetter || $0.isNumber }
      guard normalized.count == 10 else { return nil }
      kind = .asin
      value = normalized
    case .doi:
      var normalized = stripped.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      for prefix in ["https://doi.org/", "http://doi.org/", "doi:"]
      where normalized.hasPrefix(prefix) {
        normalized.removeFirst(prefix.count)
      }
      guard normalized.hasPrefix("10."), normalized.contains("/"), !normalized.contains(" ")
      else { return nil }
      kind = .doi
      value = normalized
    case nil:
      return nil
    }
  }

  package static func local(_ identifiers: [PublicationIdentifier]) -> Set<Self> {
    Set(identifiers.compactMap { Self(kind: $0.kind, value: $0.value) })
  }

  package static func remote(_ identifiers: [StorytellerIdentifier]) -> Set<Self> {
    Set(identifiers.compactMap { identifier in
      guard let value = identifier.effectiveValue else { return nil }
      return Self(kind: identifier.kind ?? identifier.name, value: value)
    })
  }

  private static func detectKind(_ raw: String?, value: String) -> Kind? {
    let kind = raw.map { String($0.lowercased().filter { $0.isLetter || $0.isNumber }) } ?? ""
    if ["isbn", "isbn10", "isbn13", "02", "15", "onixcodelist502", "onixcodelist515"]
      .contains(kind)
    { return .isbn13 }
    if kind.contains("asin") { return .asin }
    if kind == "doi" || kind == "06" || kind.contains("digitalobjectidentifier") { return .doi }
    let lower = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if lower.hasPrefix("urn:isbn:") || lower.hasPrefix("isbn:") { return .isbn13 }
    if lower.hasPrefix("urn:asin:") || lower.hasPrefix("mobi-asin:")
      || lower.hasPrefix("asin:")
    { return .asin }
    if lower.hasPrefix("doi:") || lower.hasPrefix("https://doi.org/")
      || lower.hasPrefix("http://doi.org/")
    { return .doi }
    return nil
  }

  private static func stripPrefix(_ value: String, kind: Kind?) -> String {
    var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let prefixes: [String]
    switch kind {
    case .isbn13: prefixes = ["urn:isbn:", "isbn:"]
    case .asin: prefixes = ["urn:asin:", "mobi-asin:", "asin:"]
    case .doi, nil: prefixes = []
    }
    for prefix in prefixes where result.lowercased().hasPrefix(prefix) {
      result.removeFirst(prefix.count)
      break
    }
    return result
  }

  private static func canonicalISBN(_ raw: String) -> String? {
    let value = raw.uppercased().filter { $0.isNumber || $0 == "X" }
    if value.count == 13, value.allSatisfy(\.isNumber), validISBN13(value) { return value }
    if value.count == 10, validISBN10(value) {
      let core = "978" + value.dropLast()
      let check = isbn13CheckDigit(String(core))
      return String(core) + String(check)
    }
    return nil
  }

  private static func validISBN10(_ value: String) -> Bool {
    guard value.count == 10 else { return false }
    var total = 0
    for (index, character) in value.enumerated() {
      let digit = character == "X" && index == 9 ? 10 : character.wholeNumberValue
      guard let digit else { return false }
      total += (10 - index) * digit
    }
    return total % 11 == 0
  }

  private static func validISBN13(_ value: String) -> Bool {
    guard value.count == 13, let check = value.last?.wholeNumberValue else { return false }
    return isbn13CheckDigit(String(value.dropLast())) == check
  }

  private static func isbn13CheckDigit(_ twelve: String) -> Int {
    let sum = twelve.enumerated().reduce(0) { partial, pair in
      partial + (pair.element.wholeNumberValue ?? 0) * (pair.offset.isMultiple(of: 2) ? 1 : 3)
    }
    return (10 - sum % 10) % 10
  }
}

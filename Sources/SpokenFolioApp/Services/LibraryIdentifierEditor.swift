import Foundation
import LibraryKit
import StorytellerKit

/// The shared write path for user-entered ASIN identifiers: one validator and
/// one persistence call behind both the web identifier endpoint
/// (`PUT /api/library/editions/:recordID/identifier`) and the desktop
/// inspector, so validation and the stored assertion can never diverge.
enum LibraryIdentifierEditor {
  struct InvalidASIN: LocalizedError {
    var errorDescription: String? {
      "Enter a valid 10-character ASIN (letters and digits)."
    }
  }

  /// The canonical uppercase form, or nil when the value is not an ASIN.
  static func canonicalASIN(_ raw: String) -> String? {
    guard let canonical = CanonicalPublicationIdentifier(kind: "asin", value: raw),
      canonical.kind == .asin
    else { return nil }
    return canonical.value
  }

  /// Validates the ASIN and records it as an edition identity assertion.
  @discardableResult
  static func saveASIN(_ raw: String, editionID: UUID, library: LibraryStore) throws -> String {
    guard let value = canonicalASIN(raw) else { throw InvalidASIN() }
    try library.setEditionIdentifier(
      editionID: editionID, kind: "asin", value: value, note: "Set in Library")
    return value
  }
}

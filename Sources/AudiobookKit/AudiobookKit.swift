/// AudiobookKit turns an EPUB into a complete audiobook file using
/// SiriTTSCore synthesis: EPUB parsing, narration extraction, chapter
/// planning, the synthesis pipeline with per-chapter resume, and M4B output.
package enum AudiobookKitInfo {
  /// Included in every job key so completed chapter artifacts are never
  /// reused across changes to text-extraction behavior. Bump on any change
  /// to extraction, classification, planning, or announcement logic.
  package static let extractorVersion = 3
}

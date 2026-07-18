/// Engine- and source-format-neutral audiobook planning, ordered synthesis,
/// resumable chapter artifacts, and M4B output.
package enum AudiobookPolicyVersions {
  /// Included in every job key so completed chapter artifacts are never
  /// reused across changes to text-extraction behavior. Bump on any change
  /// to extraction, classification, planning, or announcement logic.
  package static let extractorVersion = 11
}

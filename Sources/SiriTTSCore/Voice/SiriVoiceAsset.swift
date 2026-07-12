import Foundation

/// One installed Siri neural/natural voice that is safe to expose through the
/// server's fixed 48 kHz mono PCM contract.
package struct SiriVoiceAsset: Hashable, Sendable {
  package let id: String
  package let name: String
  package let displayName: String
  package let language: String
  package let technology: String
  package let footprint: String
  package let version: Int
  package let voicePath: String
  package let resourcePath: String
  package let styles: Set<String>
  package let sourcePriority: Int

  package var supportsNarration: Bool { styles.contains("narration") }

  package var quality: String { footprint.hasPrefix("premium") ? "premium" : "enhanced" }
}

import Foundation

package protocol TTSService: Sendable {
  /// Synthesise text and return a complete WAV file (globally peak-normalised).
  func synthesize(text: String, voice: String) async throws -> Data

  /// Synthesise text sentence-by-sentence, yielding raw 16-bit little-endian PCM
  /// chunks (at `sampleRate` Hz, mono, no WAV header) as each sentence completes.
  func synthesizeStream(text: String, voice: String) -> AsyncThrowingStream<Data, Error>

  /// Native Siri output sample rate in Hz.
  var sampleRate: Int { get }

  /// Default voice name used when the caller does not specify a voice.
  var defaultVoice: String { get }

  /// All voice names supported by this engine.
  var availableVoices: [String] { get }

  /// Detailed voice catalog (one entry per selectable voice, unique by `id`).
  /// Engines without richer metadata fall back to the default implementation.
  var voiceCatalog: [VoiceInfo] { get }

  /// Resolve a caller-supplied voice (display name or engine identifier) to a
  /// canonical voice string accepted by `synthesize`, or nil if unknown.
  func resolveVoice(_ voice: String) -> String?
}

/// One selectable voice, as reported by `GET /v1/audio/voices/all`.
package struct VoiceInfo: Codable, Sendable {
  /// Canonical Siri asset identifier accepted by the speech endpoint.
  package let id: String
  /// Human-readable display name (not necessarily unique, e.g. "Zoe").
  package let name: String
  /// BCP-47 language code (e.g. "en-US"); empty when the engine doesn't report one.
  package let lang: String
  /// Voice quality tier: "default", "enhanced", or "premium".
  package let quality: String

  package init(id: String, name: String, lang: String, quality: String) {
    self.id = id
    self.name = name
    self.lang = lang
    self.quality = quality
  }
}

extension TTSService {
  package var voiceCatalog: [VoiceInfo] {
    availableVoices.map { VoiceInfo(id: $0, name: $0, lang: "", quality: "default") }
  }

  package func resolveVoice(_ voice: String) -> String? {
    availableVoices.contains(voice) ? voice : nil
  }
}

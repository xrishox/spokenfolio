import Foundation
import TTSKit

struct VoiceInfo: Codable, Sendable {
  let id: String
  let name: String
  let lang: String
  let quality: String
}

protocol TTSService: Sendable {
  var defaultVoice: String { get }
  var voiceCatalog: [VoiceInfo] { get }
  func resolveVoice(_ voice: String) -> String?
  func synthesize(text: String, voice: String) async throws -> PCM16Audio
}

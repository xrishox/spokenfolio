import Foundation
import TTSKit

struct VoiceInfo: Codable, Sendable {
  let id: String
  let name: String
  let lang: String
  let quality: String
  let backend: String?
  let model: String?
  let supportsPace: Bool?
  let supportsExpressivity: Bool?

  init(
    id: String, name: String, lang: String, quality: String,
    backend: String? = nil, model: String? = nil,
    supportsPace: Bool? = nil, supportsExpressivity: Bool? = nil
  ) {
    self.id = id
    self.name = name
    self.lang = lang
    self.quality = quality
    self.backend = backend
    self.model = model
    self.supportsPace = supportsPace
    self.supportsExpressivity = supportsExpressivity
  }
}

struct TTSModelInfo: Codable, Sendable {
  let id: String
  let backendID: String
  let modelID: String
  let name: String
  let defaultVoiceID: String
  let supportsPace: Bool
  let supportsExpressivity: Bool
  let recommendedAudiobookWorkers: Int?
  let maximumAudiobookWorkers: Int?

  init(
    id: String, backendID: String, modelID: String, name: String,
    defaultVoiceID: String, supportsPace: Bool, supportsExpressivity: Bool,
    recommendedAudiobookWorkers: Int? = nil,
    maximumAudiobookWorkers: Int? = nil
  ) {
    self.id = id
    self.backendID = backendID
    self.modelID = modelID
    self.name = name
    self.defaultVoiceID = defaultVoiceID
    self.supportsPace = supportsPace
    self.supportsExpressivity = supportsExpressivity
    self.recommendedAudiobookWorkers = recommendedAudiobookWorkers
    self.maximumAudiobookWorkers = maximumAudiobookWorkers
  }
}

protocol TTSService: Sendable {
  var defaultVoice: String { get }
  var defaultModelID: String { get }
  var defaultSelection: TTSVoiceSelection { get }
  /// The legacy Siri-compatible voice list used by `/v1/audio/voices`.
  var voiceCatalog: [VoiceInfo] { get }
  var allVoiceCatalog: [VoiceInfo] { get }
  var modelCatalog: [TTSModelInfo] { get }
  func resolveVoice(_ voice: String) -> String?
  func resolveSelection(
    model: String, voice: String?, pace: Int?, expressivity: Int?
  ) throws -> TTSVoiceSelection
  func synthesize(text: String, voice: String) async throws -> PCM16Audio
  func synthesize(request: TTSSynthesisRequest) async throws -> PCM16Audio
}

extension TTSService {
  func synthesize(request: TTSSynthesisRequest) async throws -> PCM16Audio {
    try await synthesize(text: request.text, voice: request.selection.voice.voiceID)
  }
}

import SiriTTSCore
import TTSKit
import Vapor

extension VoiceInfo: Content {}

// MARK: - Vapor DI

struct TTSServiceKey: StorageKey {
  typealias Value = any TTSService
}

extension Application {
  var ttsService: any TTSService {
    get { storage[TTSServiceKey.self]! }
    set { storage[TTSServiceKey.self] = newValue }
  }
}

extension Request {
  var ttsService: any TTSService {
    application.ttsService
  }
}

final class UnavailableTTSService: TTSService, @unchecked Sendable {
  let defaultVoice = ""
  let voiceCatalog: [VoiceInfo] = []
  private let failure: ServiceError

  init(failure: ServiceError) { self.failure = failure }

  func synthesize(text: String, voice: String) async throws -> PCM16Audio { throw failure }

  func resolveVoice(_ voice: String) -> String? { nil }
}

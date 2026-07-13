import Foundation
import SiriTTSCore
import TTSKit

final class WorkerBackedTTSService: TTSService, @unchecked Sendable {
  let defaultVoice: String
  let voiceCatalog: [VoiceInfo]

  private let backend: SiriTTSBackend
  private let session: any TTSSession

  init(config: ServerConfig) throws {
    do {
      backend = try SiriTTSBackend(defaultVoice: config.defaultVoice)
    } catch TTSBackendError.unavailable {
      throw ServiceError.engineUnavailable
    }
    let registry = try TTSBackendRegistry([backend])
    session = try registry.makeSession(
      backendID: SiriTTSBackend.backendID,
      configuration: TTSWorkloadConfiguration(
        purpose: .http,
        maxConcurrency: config.maxWorkers,
        maxQueuedRequests: config.maxQueuedRequests,
        deadlineSeconds: config.requestDeadlineSeconds))
    defaultVoice = backend.defaultVoice.voiceID
    voiceCatalog = backend.voices.map {
      VoiceInfo(id: $0.key.voiceID, name: $0.name, lang: $0.language, quality: $0.quality)
    }
  }

  func initialize() async throws {
    do {
      try await session.prepare(voice: backend.defaultVoice)
    } catch {
      throw Self.serviceError(from: error)
    }
  }

  func resolveVoice(_ voice: String) -> String? { backend.resolveVoice(voice)?.voiceID }

  func synthesize(text: String, voice: String) async throws -> PCM16Audio {
    var pcm = Data()
    guard let key = backend.resolveVoice(voice) else { throw ServiceError.voiceNotFound(voice) }
    let sentences = splitSentences(text)
    do {
      for sentence in sentences {
        try Task.checkCancellation()
        let audio = try PCMNormalizer.normalize(
          try await session.synthesize(text: sentence, voice: key))
        pcm.append(audio.data)
      }
      return try PCM16Audio(data: pcm, sampleRate: 48_000, channels: 1)
    } catch {
      throw Self.serviceError(from: error)
    }
  }

  func shutdown() async { await session.shutdown() }

  private static func serviceError(from error: Error) -> ServiceError {
    guard let error = error as? TTSBackendError else { return .synthesisFailed }
    return switch error {
    case .permissionRequired: .permissionRequired
    case .unavailable: .engineUnavailable
    case .queueFull(let capacity): .queueFull(capacity)
    case .crashed: .workerCrashed
    case .timeout: .timeout
    case .voiceNotFound(let key): .voiceNotFound(key.voiceID)
    case .invalidAudioFormat, .synthesisFailed: .synthesisFailed
    }
  }
}

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
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw Self.serviceError(from: error)
    }
  }

  func resolveVoice(_ voice: String) -> String? { backend.resolveVoice(voice)?.voiceID }

  func synthesize(text: String, voice: String) async throws -> PCM16Audio {
    guard let key = backend.resolveVoice(voice) else { throw ServiceError.voiceNotFound(voice) }
    do {
      let audio = try PCMNormalizer.normalize(try await session.synthesize(text: text, voice: key))
      guard audio.data.count <= 128 << 20 else { throw TTSBackendError.invalidAudioFormat }
      return audio
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw Self.serviceError(from: error)
    }
  }

  func shutdown() async { await session.shutdown() }

  private static func serviceError(from error: Error) -> ServiceError {
    if let error = error as? ServiceError { return error }
    guard let error = error as? TTSBackendError else { return .engineUnavailable }
    return switch error {
    case .permissionRequired: .permissionRequired
    case .unavailable: .engineUnavailable
    case .queueFull(let capacity): .queueFull(capacity)
    case .crashed: .workerCrashed
    case .timeout: .timeout
    case .voiceNotFound(let key): .voiceNotFound(key.voiceID)
    case .invalidAudioFormat, .synthesisFailed: .synthesisFailed
    case .invalidInput(let message): .invalidInput(message, code: "invalid_input")
    }
  }
}

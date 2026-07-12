import Foundation
import TTSKit

package struct SiriTTSBackend: TTSBackendFactory {
  package static let backendID = TTSBackendID(rawValue: "siri")
  package static let modelID = "siri-private"

  package let id = Self.backendID
  package let voices: [VoiceDescriptor]
  package let defaultVoice: VoiceKey

  private let assetsByID: [String: SiriVoiceAsset]
  private let voiceLookup: [String: String]

  package init(defaultVoice requestedDefault: String? = nil) throws {
    let assets = SiriVoiceCatalog.discover()
    guard !assets.isEmpty else { throw TTSBackendError.unavailable }
    assetsByID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
    voiceLookup = SiriVoiceCatalog.makeVoiceLookup(assets)
    voices = assets.map { asset in
      VoiceDescriptor(
        key: Self.key(for: asset.id),
        name: asset.displayName,
        language: asset.language,
        quality: asset.quality,
        modelRevision: String(asset.version),
        voiceRevision: String(asset.version))
    }
    let defaultID: String
    if let requestedDefault {
      guard let resolved = voiceLookup[requestedDefault.lowercased()] else {
        throw ServiceError.voiceNotFound(requestedDefault)
      }
      defaultID = resolved
    } else {
      defaultID = SiriVoiceCatalog.preferred(assets)!.id
    }
    defaultVoice = Self.key(for: defaultID)
  }

  package func resolveVoice(_ requested: String) -> VoiceKey? {
    voiceLookup[requested.lowercased()].map(Self.key(for:))
  }

  package func makeSession(configuration: TTSWorkloadConfiguration) throws -> any TTSSession {
    SiriTTSSession(
      assetsByID: assetsByID,
      maxWorkers: configuration.maxConcurrency,
      maxQueued: configuration.maxQueuedRequests,
      deadlineSeconds: configuration.deadlineSeconds)
  }

  private static func key(for voiceID: String) -> VoiceKey {
    VoiceKey(backendID: backendID, modelID: modelID, voiceID: voiceID)
  }
}

package final class SiriTTSSession: TTSSession, @unchecked Sendable {
  private let assetsByID: [String: SiriVoiceAsset]
  private let pool: SiriWorkerPool

  init(
    assetsByID: [String: SiriVoiceAsset], maxWorkers: Int, maxQueued: Int,
    deadlineSeconds: Double
  ) {
    self.assetsByID = assetsByID
    pool = SiriWorkerPool(
      maxWorkers: maxWorkers, maxQueued: maxQueued, deadlineSeconds: deadlineSeconds)
  }

  package func prepare(voice: VoiceKey) async throws {
    try validate(voice)
    do {
      try SiriPermissionPreflight.verifyModelAccess()
      let pcm = try await pool.synthesize(
        text: "Siri voice ready.", voiceID: voice.voiceID, splitSentencesInWorker: false)
      guard !pcm.isEmpty else { throw TTSBackendError.unavailable }
    } catch ServiceError.permissionRequired {
      throw TTSBackendError.permissionRequired
    }
  }

  package func synthesize(text: String, voice: VoiceKey) async throws -> PCM16Audio {
    try validate(voice)
    do {
      let pcm = try await pool.synthesize(
        text: text, voiceID: voice.voiceID, splitSentencesInWorker: false)
      return try PCM16Audio(data: pcm, sampleRate: SiriVoiceCatalog.requiredSampleRate, channels: 1)
    } catch let error as ServiceError {
      throw Self.map(error)
    }
  }

  package func shutdown() async { await pool.shutdown() }

  private func validate(_ voice: VoiceKey) throws {
    guard voice.backendID == SiriTTSBackend.backendID,
      voice.modelID == SiriTTSBackend.modelID,
      assetsByID[voice.voiceID] != nil
    else { throw TTSBackendError.voiceNotFound(voice) }
  }

  private static func map(_ error: ServiceError) -> TTSBackendError {
    switch error {
    case .permissionRequired: .permissionRequired
    case .engineUnavailable: .unavailable
    case .queueFull(let capacity): .queueFull(capacity)
    case .workerCrashed: .crashed
    case .timeout: .timeout
    case .voiceNotFound: .unavailable
    case .synthesisFailed, .invalidInput, .rateLimited: .synthesisFailed
    }
  }
}

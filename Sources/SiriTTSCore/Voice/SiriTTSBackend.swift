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
    var indexed: [String: SiriVoiceAsset] = [:]
    for asset in assets {
      guard indexed.updateValue(asset, forKey: asset.id) == nil else {
        throw TTSBackendError.unavailable
      }
    }
    assetsByID = indexed
    voiceLookup = SiriVoiceCatalog.makeVoiceLookup(assets)
    let modelRevision = SiriTTSRuntimeIdentity.current().modelRevision
    voices = assets.map { asset in
      VoiceDescriptor(
        key: Self.key(for: asset.id),
        name: asset.displayName,
        language: asset.language,
        quality: asset.quality,
        modelRevision: modelRevision,
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
      purpose: configuration.purpose,
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
  private let splitSentencesInWorker: Bool

  init(
    assetsByID: [String: SiriVoiceAsset], purpose: TTSWorkloadConfiguration.Purpose,
    maxWorkers: Int, maxQueued: Int,
    deadlineSeconds: Double
  ) {
    self.assetsByID = assetsByID
    splitSentencesInWorker = Self.workerSplitsSentences(for: purpose)
    pool = SiriWorkerPool(
      maxWorkers: maxWorkers, maxQueued: maxQueued, deadlineSeconds: deadlineSeconds)
  }

  package func prepare(voice: VoiceKey) async throws {
    try validate(voice)
    do {
      try SiriPermissionPreflight.verifyModelAccess()
      let pcm = try await pool.synthesize(
        text: "Siri voice ready.", voiceID: voice.voiceID, splitSentencesInWorker: false)
      _ = try PCM16Audio(
        data: pcm, sampleRate: SiriVoiceCatalog.requiredSampleRate, channels: 1)
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as ServiceError {
      throw Self.map(error)
    } catch let error as TTSBackendError {
      throw error
    } catch {
      throw TTSBackendError.unavailable
    }
  }

  package func synthesize(text: String, voice: VoiceKey) async throws -> PCM16Audio {
    try validate(voice)
    do {
      let pcm = try await pool.synthesize(
        text: text, voiceID: voice.voiceID,
        splitSentencesInWorker: splitSentencesInWorker)
      return try PCM16Audio(data: pcm, sampleRate: SiriVoiceCatalog.requiredSampleRate, channels: 1)
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as ServiceError {
      throw Self.map(error)
    }
  }

  package func shutdown() async { await pool.shutdown() }

  static func workerSplitsSentences(for purpose: TTSWorkloadConfiguration.Purpose) -> Bool {
    switch purpose {
    case .http: true
    case .audiobook: false
    }
  }

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
    case .invalidInput(let message, _): .invalidInput(message)
    case .synthesisFailed, .rateLimited: .synthesisFailed
    }
  }
}

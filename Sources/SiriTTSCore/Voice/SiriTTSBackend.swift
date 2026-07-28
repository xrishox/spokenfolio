import Foundation
import LocalTTSWorkerKit
import TTSKit

package struct SiriTTSBackend: LocalTTSWorkerBackendFactory {
  package static let backendID = TTSBackendID(rawValue: "siri")
  package static let modelID = "siri-private"

  package let id = Self.backendID
  package let voices: [VoiceDescriptor]
  package let defaultVoice: VoiceKey
  package var models: [TTSModelDescriptor] {
    [
      TTSModelDescriptor(
        key: TTSModelKey(backendID: Self.backendID, modelID: Self.modelID),
        name: "Siri", revision: voices.first?.modelRevision,
        defaultVoice: defaultVoice,
        maximumAudiobookWorkers: 8)
    ]
  }

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
        throw TTSBackendError.voiceNotFound(Self.key(for: requestedDefault))
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

  package func makeWorkerClient(for voice: VoiceKey) throws -> any LocalTTSWorkerTransport {
    guard voice.backendID == Self.backendID, voice.modelID == Self.modelID,
      assetsByID[voice.voiceID] != nil
    else { throw TTSBackendError.voiceNotFound(voice) }
    return try SiriWorkerClient(voiceID: voice.voiceID)
  }

  package func makeSession(configuration: TTSWorkloadConfiguration) throws -> any TTSSession {
    let pool = LocalTTSWorkerPool(
      maxWorkers: configuration.maxConcurrency,
      maxQueued: configuration.maxQueuedRequests,
      deadlineSeconds: configuration.deadlineSeconds,
      makeClient: makeWorkerClient)
    return SiriTTSSession(assetsByID: assetsByID, pool: pool, ownsPool: true)
  }

  package func makeSession(
    configuration: TTSWorkloadConfiguration,
    sharedWorkerPool: LocalTTSWorkerPool
  ) throws -> any TTSSession {
    SiriTTSSession(assetsByID: assetsByID, pool: sharedWorkerPool, ownsPool: false)
  }

  private static func key(for voiceID: String) -> VoiceKey {
    VoiceKey(backendID: backendID, modelID: modelID, voiceID: voiceID)
  }
}

package final class SiriTTSSession: TTSSession, @unchecked Sendable {
  private let assetsByID: [String: SiriVoiceAsset]
  private let pool: LocalTTSWorkerPool
  private let ownsPool: Bool
  private let provenanceLock = NSLock()
  private var preparedProvenance: TTSRuntimeProvenance?

  init(
    assetsByID: [String: SiriVoiceAsset], pool: LocalTTSWorkerPool, ownsPool: Bool
  ) {
    self.assetsByID = assetsByID
    self.pool = pool
    self.ownsPool = ownsPool
  }

  package func prepare(
    selection: TTSVoiceSelection
  ) async throws -> TTSRuntimeProvenance {
    try validate(selection)
    provenanceLock.withLock { preparedProvenance = nil }
    do {
      try SiriPermissionPreflight.verifyModelAccess()
      let result = try await synthesize(
        request: TTSSynthesisRequest(
          text: "Siri voice ready.", selection: selection,
          utteranceMode: .singleUtterance, timingMode: .none))
      guard let provenance = result.provenance,
        provenance.backendID == selection.voice.backendID,
        provenance.modelID == selection.voice.modelID,
        provenance.voiceID == selection.voice.voiceID
      else { throw TTSBackendError.inconsistentRuntimeProvenance }
      provenanceLock.withLock { preparedProvenance = provenance }
      return provenance
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as TTSBackendError {
      throw error
    } catch {
      throw TTSBackendError.unavailable
    }
  }

  package func synthesize(request: TTSSynthesisRequest) async throws -> TTSSynthesisResult {
    try validate(request.selection)
    let splitSentences = Self.workerSplitsSentences(for: request.utteranceMode)
    let resolved = TTSSynthesisRequest(
      text: request.text, selection: request.selection,
      utteranceMode: splitSentences ? .sentenceSequence : .singleUtterance,
      timingMode: splitSentences ? .none : request.timingMode)
    let result = try await pool.synthesize(resolved)
    // One prepared session serves every voice its backend offers, so the
    // engine identity must match while the voice fields must match THIS
    // request's selection. Comparing whole provenance to the prepared voice
    // would fail every request for a different voice.
    if let expected = provenanceLock.withLock({ preparedProvenance }) {
      guard let actual = result.provenance,
        actual.engineIdentity == expected.engineIdentity,
        actual.backendID == request.selection.voice.backendID,
        actual.modelID == request.selection.voice.modelID,
        actual.voiceID == request.selection.voice.voiceID
      else { throw TTSBackendError.inconsistentRuntimeProvenance }
    }
    return TTSSynthesisResult(
      audio: result.audio, timings: result.timings, provenance: result.provenance)
  }

  package func shutdown() async {
    if ownsPool { await pool.shutdown() }
  }

  static func workerSplitsSentences(for mode: TTSUtteranceMode) -> Bool {
    mode == .sentenceSequence
  }

  private func validate(_ selection: TTSVoiceSelection) throws {
    let voice = selection.voice
    guard voice.backendID == SiriTTSBackend.backendID,
      voice.modelID == SiriTTSBackend.modelID,
      assetsByID[voice.voiceID] != nil
    else { throw TTSBackendError.voiceNotFound(voice) }
    guard selection.controls == .none else {
      throw TTSBackendError.invalidInput("Legacy Siri does not support expressive controls.")
    }
  }
}

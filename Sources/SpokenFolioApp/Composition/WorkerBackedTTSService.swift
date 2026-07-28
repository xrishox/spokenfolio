import Foundation
import GoldenGateTTSCore
import LocalTTSWorkerKit
import SiriTTSCore
import TTSKit

final class WorkerBackedTTSService: TTSService, @unchecked Sendable {
  private struct PublicModel {
    let publicID: String
    let descriptor: TTSModelDescriptor
  }

  private let registry: TTSBackendRegistry
  private let resolver: TTSSelectionResolver
  private let sessions: [TTSBackendID: any TTSSession]
  private let workerPool: LocalTTSWorkerPool
  private let publicModels: [String: PublicModel]
  private let stateLock = NSLock()
  private var readyBackends: Set<TTSBackendID> = []

  let defaultVoice: String
  let defaultModelID: String
  let defaultSelection: TTSVoiceSelection
  let voiceCatalog: [VoiceInfo]
  let allVoiceCatalog: [VoiceInfo]

  var modelCatalog: [TTSModelInfo] {
    let ready = stateLock.withLock { readyBackends }
    return publicModels.values
      .filter { ready.contains($0.descriptor.key.backendID) }
      .sorted { $0.publicID < $1.publicID }
      .map {
        TTSModelInfo(
          id: $0.publicID,
          backendID: $0.descriptor.key.backendID.rawValue,
          modelID: $0.descriptor.key.modelID,
          name: $0.descriptor.name,
          defaultVoiceID: $0.descriptor.defaultVoice.voiceID,
          supportsPace: $0.descriptor.controls.pace != .unsupported,
          supportsExpressivity: $0.descriptor.controls.expressivity != .unsupported,
          recommendedAudiobookWorkers: $0.descriptor.recommendedAudiobookWorkers,
          maximumAudiobookWorkers: $0.descriptor.maximumAudiobookWorkers)
      }
  }

  convenience init(config: ServerConfig) throws {
    try self.init(config: config, composition: LocalTTSComposition.live())
  }

  convenience init(
    config: ServerConfig, factories: [any LocalTTSWorkerBackendFactory],
    publicModelKeys: [String: TTSModelKey]
  ) throws {
    try self.init(
      config: config,
      composition: LocalTTSComposition(
        factories: factories, publicModelKeys: publicModelKeys))
  }

  init(config: ServerConfig, composition: LocalTTSComposition) throws {
    let factories = composition.factories
    let publicModelKeys = composition.publicModelKeys
    let builtRegistry = composition.registry
    var models: [String: PublicModel] = [:]
    for (publicID, key) in publicModelKeys {
      guard let descriptor = builtRegistry.model(key) else {
        throw ConfigurationError(
          "public TTS model '\(publicID)' selects unavailable backend/model "
            + "'\(key.backendID.rawValue)/\(key.modelID)'")
      }
      models[publicID] = PublicModel(publicID: publicID, descriptor: descriptor)
    }
    guard !models.isEmpty else { throw ServiceError.engineUnavailable }
    registry = builtRegistry
    resolver = TTSSelectionResolver(composition: composition)
    publicModels = models

    let factoriesByID = Dictionary(uniqueKeysWithValues: factories.map { ($0.id, $0) })
    let sharedPool = LocalTTSWorkerPool(
      maxWorkers: config.maxWorkers,
      maxQueued: config.maxQueuedRequests,
      deadlineSeconds: config.requestDeadlineSeconds,
      makeClient: { voice in
        guard let factory = factoriesByID[voice.backendID] else {
          throw TTSBackendError.voiceNotFound(voice)
        }
        return try factory.makeWorkerClient(for: voice)
      })
    workerPool = sharedPool
    let configuration = TTSWorkloadConfiguration(
      purpose: .http, maxConcurrency: config.maxWorkers,
      maxQueuedRequests: config.maxQueuedRequests,
      deadlineSeconds: config.requestDeadlineSeconds)
    var builtSessions: [TTSBackendID: any TTSSession] = [:]
    for factory in factories {
      builtSessions[factory.id] = try factory.makeSession(
        configuration: configuration, sharedWorkerPool: sharedPool)
    }
    sessions = builtSessions

    let resolvedDefault: TTSSelectionResolver.Resolved
    do {
      resolvedDefault = try TTSSelectionResolver(composition: composition).configuredDefault(
        configuredVoice: config.defaultVoice, configuredDefault: config.defaultTTS)
    } catch {
      throw ConfigurationError(error.localizedDescription)
    }
    defaultSelection = resolvedDefault.selection
    defaultModelID = resolvedDefault.publicModelID
    defaultVoice = resolvedDefault.selection.voice.voiceID

    func info(_ voice: VoiceDescriptor) -> VoiceInfo {
      let descriptor = builtRegistry.model(
        TTSModelKey(backendID: voice.key.backendID, modelID: voice.key.modelID))
      return VoiceInfo(
        id: voice.key.voiceID, name: voice.name, lang: voice.language,
        quality: voice.quality,
        backend: voice.key.backendID.rawValue,
        model: voice.key.modelID,
        supportsPace: descriptor?.controls.pace != .unsupported,
        supportsExpressivity: descriptor?.controls.expressivity != .unsupported)
    }
    allVoiceCatalog = builtRegistry.voices.map(info)
    voiceCatalog = builtRegistry.voices
      .filter { $0.key.backendID == SiriTTSBackend.backendID }
      .map(info)
  }

  func initialize() async throws {
    var ready = Set<TTSBackendID>()
    var lastError: Error?
    let uniqueModels = Dictionary(
      publicModels.values.map { ($0.descriptor.key, $0) }, uniquingKeysWith: { first, _ in first })
    let defaultKey = Self.modelKey(for: defaultSelection.voice)
    let warmupOrder = uniqueModels.values.sorted { lhs, rhs in
      if lhs.descriptor.key == defaultKey { return false }
      if rhs.descriptor.key == defaultKey { return true }
      return lhs.publicID < rhs.publicID
    }
    for model in warmupOrder {
      guard let session = sessions[model.descriptor.key.backendID] else { continue }
      do {
        let selection = model.descriptor.key == Self.modelKey(for: defaultSelection.voice)
          ? defaultSelection
          : TTSVoiceSelection(
            voice: model.descriptor.defaultVoice,
            controls: Self.defaultControls(for: model.descriptor))
        _ = try await session.prepare(selection: selection)
        ready.insert(model.descriptor.key.backendID)
      } catch {
        lastError = error
      }
    }
    stateLock.withLock { readyBackends = ready }
    guard ready.contains(defaultSelection.voice.backendID) else {
      throw Self.serviceError(from: lastError ?? TTSBackendError.unavailable)
    }
  }

  func resolveVoice(_ voice: String) -> String? {
    guard let siri = registry.backend(SiriTTSBackend.backendID) else { return nil }
    return siri.resolveVoice(voice)?.voiceID
  }

  func resolveSelection(
    model: String, voice requestedVoice: String?, pace: Int?, expressivity: Int?
  ) throws -> TTSVoiceSelection {
    guard let publicModel = publicModels[model] else {
      throw ServiceError.invalidInput("Unknown model '\(model)'.", code: "model_not_found")
    }
    let ready = stateLock.withLock {
      readyBackends.contains(publicModel.descriptor.key.backendID)
    }
    guard ready else { throw ServiceError.engineUnavailable }

    do {
      return try resolver.publicSelection(
        model: model, voice: requestedVoice, pace: pace, expressivity: expressivity,
        configuredDefault: defaultSelection).selection
    } catch TTSSelectionResolverError.voiceNotFound(let voice) {
      throw ServiceError.voiceNotFound(voice)
    } catch TTSSelectionResolverError.modelNotFound {
      throw ServiceError.invalidInput("Unknown model '\(model)'.", code: "model_not_found")
    } catch TTSSelectionResolverError.unsupportedControls {
      throw ServiceError.invalidInput(
        "Model '\(model)' does not support expressive controls.",
        code: "unsupported_controls")
    } catch TTSSelectionResolverError.invalidControls {
      throw ServiceError.invalidInput(
        "'pace' and 'expressivity' must be integer presets from 1 through 5.",
        code: "invalid_controls")
    }
  }

  func synthesize(text: String, voice: String) async throws -> PCM16Audio {
    let selection = try resolveSelection(model: "tts-1", voice: voice, pace: nil, expressivity: nil)
    return try await synthesize(
      request: TTSSynthesisRequest(
        text: text, selection: selection, utteranceMode: .sentenceSequence))
  }

  func synthesize(request: TTSSynthesisRequest) async throws -> PCM16Audio {
    guard let session = sessions[request.selection.voice.backendID] else {
      throw ServiceError.engineUnavailable
    }
    do {
      let result = try await session.synthesize(request: request)
      let audio = try PCMNormalizer.normalize(result.audio)
      guard audio.data.count <= 128 << 20 else { throw TTSBackendError.invalidAudioFormat }
      return audio
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw Self.serviceError(from: error)
    }
  }

  var debugQueuedWorkerRequests: Int {
    get async { await workerPool.queuedRequestCount }
  }

  func shutdown() async {
    for session in sessions.values { await session.shutdown() }
    await workerPool.shutdown()
  }

  private static func defaultControls(
    for descriptor: TTSModelDescriptor
  ) -> TTSSynthesisControls {
    guard descriptor.controls != .none else { return .none }
    return TTSSynthesisControls(pace: .neutral, expressivity: .neutral)
  }

  private static func modelKey(for voice: VoiceKey) -> TTSModelKey {
    TTSModelKey(backendID: voice.backendID, modelID: voice.modelID)
  }

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
    case .invalidAudioFormat, .synthesisFailed, .inconsistentRuntimeProvenance:
      .synthesisFailed
    case .invalidInput(let message): .invalidInput(message, code: "invalid_input")
    }
  }
}

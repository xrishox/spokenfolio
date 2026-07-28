import Foundation
import GoldenGateTTSCore
import LocalTTSWorkerKit
import SiriTTSCore
import TTSKit

/// One process-local catalog of every compiled local TTS backend. Discovery is
/// intentionally independent of user defaults: installed assets answer what is
/// available, while `TTSSelectionResolver` applies configuration and request
/// policy afterward.
struct LocalTTSComposition: Sendable {
  struct DiscoveryPolicy: Sendable {
    let mayLaunchPrivateChildren: Bool

    static var current: DiscoveryPolicy {
      let environment = ProcessInfo.processInfo.environment
      let executablePath = CommandLine.arguments.first ?? ""
      let isTestProcess = environment["SWIFT_TESTING_ENABLED"] != nil
        || executablePath.contains(".xctest")
        || ProcessInfo.processInfo.processName.hasSuffix("Tests")
        || Bundle.main.bundlePath.contains(".xctest")
        || NSClassFromString("XCTest.XCTestCase") != nil
        || NSClassFromString("XCTestCase") != nil
        || URL(fileURLWithPath: executablePath).lastPathComponent == "xctest"
      return DiscoveryPolicy(
        mayLaunchPrivateChildren: environment["SPOKENFOLIO_WORKER_EXECUTABLE"] != nil
          || (!isTestProcess && environment["XCTestConfigurationFilePath"] == nil))
    }
  }

  private final class LiveCache: @unchecked Sendable {
    let lock = NSLock()
    var value: LocalTTSComposition?
  }

  private static let liveCache = LiveCache()

  let factories: [any LocalTTSWorkerBackendFactory]
  let registry: TTSBackendRegistry
  let publicModelKeys: [String: TTSModelKey]

  init(
    factories: [any LocalTTSWorkerBackendFactory], publicModelKeys: [String: TTSModelKey]
  ) throws {
    let registry = try TTSBackendRegistry(factories)
    for (publicID, key) in publicModelKeys {
      guard !publicID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        registry.model(key) != nil
      else {
        throw ConfigurationError(
          "public TTS model '\(publicID)' selects an unavailable backend/model")
      }
    }
    self.factories = factories
    self.registry = registry
    self.publicModelKeys = publicModelKeys
  }

  static func discover(policy: DiscoveryPolicy = .current) throws -> LocalTTSComposition {
    var factories: [any LocalTTSWorkerBackendFactory] = []
    var aliases: [String: TTSModelKey] = [:]

    if let siri = try? SiriTTSBackend() {
      factories.append(siri)
      let key = siri.models[0].key
      aliases["tts-1"] = key
      aliases["tts-1-hd"] = key
    }
    if policy.mayLaunchPrivateChildren, let expressive = try? GoldenGateTTSBackend() {
      factories.append(expressive)
      aliases[GoldenGateTTSBackend.modelID] = expressive.models[0].key
    }
    guard !factories.isEmpty else { throw ServiceError.engineUnavailable }
    return try LocalTTSComposition(factories: factories, publicModelKeys: aliases)
  }

  /// Shared by the HTTP service, desktop models, and Web API in one process so
  /// Golden Gate catalog discovery and voice revision snapshots happen once.
  static func live() throws -> LocalTTSComposition {
    try liveCache.lock.withLock {
      if let value = liveCache.value { return value }
      let value = try discover()
      liveCache.value = value
      return value
    }
  }

  static func invalidateLiveCache() {
    liveCache.lock.withLock { liveCache.value = nil }
  }

  func factory(_ id: TTSBackendID) -> (any TTSBackendFactory)? {
    factories.first { $0.id == id }
  }

  func publicModel(_ id: String) -> TTSModelDescriptor? {
    publicModelKeys[id].flatMap(registry.model)
  }

  func primaryPublicModelID(for key: TTSModelKey) -> String? {
    publicModelKeys
      .filter { $0.value == key }
      .map(\.key)
      .sorted { lhs, rhs in
        if lhs == "tts-1" { return true }
        if rhs == "tts-1" { return false }
        return lhs < rhs
      }
      .first
  }

  var productionModels: [(publicID: String, descriptor: TTSModelDescriptor)] {
    registry.models.compactMap { descriptor in
      primaryPublicModelID(for: descriptor.key).map { ($0, descriptor) }
    }
  }
}

enum TTSSelectionResolverError: Error, LocalizedError, Sendable {
  case modelNotFound(String)
  case voiceNotFound(String)
  case unsupportedControls(String)
  case invalidControls

  var errorDescription: String? {
    switch self {
    case .modelNotFound(let model): "TTS model '\(model)' is unavailable."
    case .voiceNotFound(let voice): "TTS voice '\(voice)' is unavailable."
    case .unsupportedControls(let model): "TTS model '\(model)' does not support expressive controls."
    case .invalidControls: "TTS pace and expressivity must be integer presets from 1 through 5."
    }
  }
}

struct TTSSelectionResolver: Sendable {
  struct Resolved: Sendable {
    let publicModelID: String
    let model: TTSModelDescriptor
    let voice: VoiceDescriptor
    let selection: TTSVoiceSelection
  }

  let composition: LocalTTSComposition

  func configuredDefault(
    configuredVoice: String?, configuredDefault: DefaultTTSConfig?
  ) throws -> Resolved {
    if let configuredDefault {
      return try canonical(
        backendID: configuredDefault.backendID, modelID: configuredDefault.modelID,
        voiceID: configuredDefault.voiceID, pace: configuredDefault.pacePreset,
        expressivity: configuredDefault.expressivityPreset)
    }

    let model: TTSModelDescriptor
    let publicID: String
    if let siri = composition.factory(SiriTTSBackend.backendID),
      let descriptor = siri.models.first
    {
      model = descriptor
      publicID = composition.primaryPublicModelID(for: descriptor.key) ?? descriptor.key.modelID
    } else if let first = composition.productionModels.first {
      model = first.descriptor
      publicID = first.publicID
    } else {
      throw TTSSelectionResolverError.modelNotFound("default")
    }
    let voiceKey: VoiceKey
    if let configuredVoice {
      do {
        voiceKey = try composition.registry.resolveVoice(configuredVoice, model: model.key)
      } catch {
        throw TTSSelectionResolverError.voiceNotFound(configuredVoice)
      }
    } else {
      voiceKey = model.defaultVoice
    }
    return try resolved(publicID: publicID, model: model, voiceKey: voiceKey, pace: nil, expressivity: nil)
  }

  func publicSelection(
    model publicID: String, voice requestedVoice: String?, pace: Int?, expressivity: Int?,
    configuredDefault: TTSVoiceSelection
  ) throws -> Resolved {
    guard let model = composition.publicModel(publicID) else {
      throw TTSSelectionResolverError.modelNotFound(publicID)
    }
    let usesConfiguredDefault = model.key == Self.modelKey(for: configuredDefault.voice)
    let voiceKey: VoiceKey
    if let requestedVoice {
      do {
        voiceKey = try composition.registry.resolveVoice(requestedVoice, model: model.key)
      } catch {
        throw TTSSelectionResolverError.voiceNotFound(requestedVoice)
      }
    } else {
      voiceKey = usesConfiguredDefault ? configuredDefault.voice : model.defaultVoice
    }
    return try resolved(
      publicID: publicID, model: model, voiceKey: voiceKey,
      pace: pace ?? (usesConfiguredDefault ? configuredDefault.controls.pace?.rawValue : nil),
      expressivity: expressivity
        ?? (usesConfiguredDefault ? configuredDefault.controls.expressivity?.rawValue : nil))
  }

  func canonical(
    backendID: String, modelID: String, voiceID: String,
    pace: Int?, expressivity: Int?
  ) throws -> Resolved {
    let key = TTSModelKey(backendID: TTSBackendID(rawValue: backendID), modelID: modelID)
    guard let model = composition.registry.model(key) else {
      throw TTSSelectionResolverError.modelNotFound("\(backendID)/\(modelID)")
    }
    let voiceKey: VoiceKey
    do {
      voiceKey = try composition.registry.resolveVoice(voiceID, model: key)
    } catch {
      throw TTSSelectionResolverError.voiceNotFound(voiceID)
    }
    let publicID = composition.primaryPublicModelID(for: key) ?? modelID
    return try resolved(
      publicID: publicID, model: model, voiceKey: voiceKey,
      pace: pace, expressivity: expressivity)
  }

  private func resolved(
    publicID: String, model: TTSModelDescriptor, voiceKey: VoiceKey,
    pace: Int?, expressivity: Int?
  ) throws -> Resolved {
    let controls: TTSSynthesisControls
    if model.controls == .none {
      guard pace == nil, expressivity == nil else {
        throw TTSSelectionResolverError.unsupportedControls(publicID)
      }
      controls = .none
    } else {
      do {
        controls = TTSSynthesisControls(
          pace: try TTSPreset(pace ?? TTSPreset.neutral.rawValue),
          expressivity: try TTSPreset(expressivity ?? TTSPreset.neutral.rawValue))
      } catch {
        throw TTSSelectionResolverError.invalidControls
      }
    }
    let selection = TTSVoiceSelection(voice: voiceKey, controls: controls)
    do { try composition.registry.validate(selection) } catch {
      throw TTSSelectionResolverError.voiceNotFound(voiceKey.voiceID)
    }
    guard let voice = composition.registry.voices.first(where: { $0.key == voiceKey }) else {
      throw TTSSelectionResolverError.voiceNotFound(voiceKey.voiceID)
    }
    return Resolved(publicModelID: publicID, model: model, voice: voice, selection: selection)
  }

  private static func modelKey(for voice: VoiceKey) -> TTSModelKey {
    TTSModelKey(backendID: voice.backendID, modelID: voice.modelID)
  }
}

actor TTSInventoryProvider {
  struct Inventory: Sendable {
    let models: [TTSModelInfo]
    let voices: [VoiceDescriptor]
    let defaultModelID: String
    let defaultSelection: TTSVoiceSelection
    let permissionWarning: String?
  }

  static let shared = TTSInventoryProvider()

  private let loader: @Sendable () throws -> LocalTTSComposition
  private var cached: LocalTTSComposition?
  private var loading: Task<LocalTTSComposition, Error>?

  init(loader: @escaping @Sendable () throws -> LocalTTSComposition = LocalTTSComposition.live) {
    self.loader = loader
  }

  func composition() async throws -> LocalTTSComposition {
    if let cached { return cached }
    if let loading { return try await loading.value }
    let loader = self.loader
    let task = Task.detached(priority: .userInitiated) { try loader() }
    loading = task
    do {
      let value = try await task.value
      cached = value
      loading = nil
      return value
    } catch {
      loading = nil
      throw error
    }
  }

  func inventory(
    configuredVoice: String?, configuredDefault: DefaultTTSConfig? = nil
  ) async throws -> Inventory {
    let composition = try await composition()
    let resolved = try TTSSelectionResolver(composition: composition).configuredDefault(
      configuredVoice: configuredVoice, configuredDefault: configuredDefault)
    let models = composition.productionModels.map { publicID, descriptor in
      TTSModelInfo(
        id: publicID, backendID: descriptor.key.backendID.rawValue,
        modelID: descriptor.key.modelID, name: descriptor.name,
        defaultVoiceID: descriptor.defaultVoice.voiceID,
        supportsPace: descriptor.controls.pace != .unsupported,
        supportsExpressivity: descriptor.controls.expressivity != .unsupported,
        recommendedAudiobookWorkers: descriptor.recommendedAudiobookWorkers,
        maximumAudiobookWorkers: descriptor.maximumAudiobookWorkers)
    }.sorted { $0.id < $1.id }

    let warning: String?
    if composition.factory(SiriTTSBackend.backendID) != nil {
      do {
        try SiriPermissionPreflight.verifyModelAccess()
        warning = nil
      } catch {
        warning = "Full Disk Access is required to read Apple's Siri voice models."
      }
    } else {
      warning = nil
    }
    return Inventory(
      models: models, voices: composition.registry.voices,
      defaultModelID: resolved.publicModelID, defaultSelection: resolved.selection,
      permissionWarning: warning)
  }

  func resolveCanonical(
    backendID: String, modelID: String, voiceID: String,
    pace: Int?, expressivity: Int?
  ) async throws -> TTSSelectionResolver.Resolved {
    let composition = try await composition()
    return try TTSSelectionResolver(composition: composition).canonical(
      backendID: backendID, modelID: modelID, voiceID: voiceID,
      pace: pace, expressivity: expressivity)
  }

  func invalidate() {
    loading?.cancel()
    loading = nil
    cached = nil
  }
}

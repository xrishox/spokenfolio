import AudiobookKit
import BookJobKit
import Foundation
import ReadAloudKit

enum ProductionWorkerPolicy {
  static func maximum(
    backendID: String, modelID: String, models: [TTSModelInfo] = []
  ) -> Int {
    let advertised = models.first {
      $0.backendID == backendID && $0.modelID == modelID
    }?.maximumAudiobookWorkers
    // Existing durable requests predate the descriptor capability. Preserve
    // the safety ceiling from their stable backend/model identity.
    let compatibilityMaximum =
      backendID == "siri-fm" && modelID == "siri-expressive" ? 1 : nil
    return min(
      AudiobookConfig.maximumWorkers,
      advertised ?? compatibilityMaximum ?? AudiobookConfig.maximumWorkers)
  }

  static func resolved(
    _ requested: Int, backendID: String, modelID: String,
    models: [TTSModelInfo] = []
  ) -> Int {
    max(1, min(requested, maximum(backendID: backendID, modelID: modelID, models: models)))
  }

  static func warning(requested: Int, effective: Int, modelID: String) -> String? {
    guard requested != effective else { return nil }
    return
      "\(modelID) supports one production audiobook worker; "
      + "the requested \(requested)-worker setting was reduced to \(effective)"
  }
}

/// The one starting point for every production form — desktop Create,
/// desktop Library Process, the Web API, and anything else that has to open
/// a form before the user has chosen anything. Reading configuration and
/// resolving the configured default selection happens here once; every
/// interface projects from this value instead of repeating the derivation
/// and drifting apart.
struct ProductionDefaults: Sendable {
  /// Why `workers` has this value, so an interface can say so instead of
  /// guessing. `explicit`: `audiobook.maxWorkers` is configured;
  /// `recommended`: the default model's measured recommendation;
  /// `hardware`: the core-count default.
  enum WorkerSource: String, Codable, Sendable {
    case explicit, recommended, hardware, remembered
  }

  let inventory: TTSInventoryProvider.Inventory
  var publicModelID: String
  var backendID: String
  var modelID: String
  var voiceID: String
  var pacePreset: Int?
  var expressivityPreset: Int?
  var bitrateKbps: Int
  var workers: Int
  var unitGranularityID: String
  var workerSource: WorkerSource
  var workerWarning: String?
  var announceTitles: Bool
  var paragraphPauseSeconds: Double
  var chapterPauseSeconds: Double
  var readAloudBitrateKbps: Int
  var readAloudASREngineID: String
  var readAloudASRModelID: String?
  let workDirectory: String?
  /// Remembered delivery/ReadAloud intent. These have no configuration
  /// counterpart, so they start off and are only ever set by remembering.
  var createReadAloud = false
  var storytellerConnectionID: UUID?
  var sendSourceEPUB = false
  var sendM4B = false
  var sendReadAloud = false
  var permissionWarning: String? { inventory.permissionWarning }

  init(config: AudiobookConfig, inventory: TTSInventoryProvider.Inventory) {
    let selection = inventory.defaultSelection
    let recommended = inventory.models.first {
      $0.backendID == selection.voice.backendID.rawValue
        && $0.modelID == selection.voice.modelID
    }?.recommendedAudiobookWorkers
    self.inventory = inventory
    publicModelID = inventory.defaultModelID
    backendID = selection.voice.backendID.rawValue
    modelID = selection.voice.modelID
    voiceID = selection.voice.voiceID
    pacePreset = selection.controls.pace?.rawValue
    expressivityPreset = selection.controls.expressivity?.rawValue
    bitrateKbps = config.defaultBitrateKbps
    let requestedWorkers = config.resolvedMaxWorkers(explicit: nil, recommended: recommended)
    workers = ProductionWorkerPolicy.resolved(
      requestedWorkers, backendID: backendID, modelID: modelID, models: inventory.models)
    unitGranularityID = "paragraph"
    workerWarning = ProductionWorkerPolicy.warning(
      requested: requestedWorkers, effective: workers, modelID: modelID)
    workerSource =
      config.maxWorkers > 0 ? .explicit : (recommended != nil ? .recommended : .hardware)
    announceTitles = config.announceTitles
    paragraphPauseSeconds = config.paragraphPauseSeconds
    chapterPauseSeconds = config.chapterPauseSeconds
    readAloudBitrateKbps = ReadAloudDefaults.opusBitrateKbps
    readAloudASREngineID = ReadAloudDefaults.asr.engine.rawValue
    readAloudASRModelID = ReadAloudDefaults.asr.whisperModel?.rawValue
    workDirectory = config.workDirectory
  }

  /// Loads configuration and the cached TTS inventory, resolving the
  /// configured default selection exactly once, then applies whatever the
  /// user last queued with so a form opens where they left off.
  static func load(
    settingsStore: StudioSettingsStore = StudioSettingsStore(url: AppPaths.studioSettingsURL)
  ) async throws -> ProductionDefaults {
    let appConfig = try AppConfig.load()
    let inventory = try await TTSInventoryProvider.shared.inventory(
      configuredVoice: appConfig.audiobook.defaultVoice ?? appConfig.server.defaultVoice,
      configuredDefault: appConfig.server.defaultTTS)
    let base = ProductionDefaults(config: appConfig.audiobook, inventory: inventory)
    // Remembering is a convenience, never a requirement: unreadable or
    // corrupt settings fall back to the configured defaults rather than
    // failing every production form.
    let remembered = try? await settingsStore.load().lastProduction
    guard let remembered else { return base }
    return await base.applying(remembered)
  }

  /// Records the settings a book was just queued with, so every production
  /// form on both surfaces opens with them next time. Remembering must never
  /// fail the queueing that already succeeded, so errors are swallowed.
  static func remember(
    backendID: String, modelID: String, voiceID: String,
    pacePreset: Int?, expressivityPreset: Int?, bitrateKbps: Int, workers: Int,
    unitGranularityID: String = "paragraph",
    announceTitles: Bool, paragraphPauseSeconds: Double, chapterPauseSeconds: Double,
    createReadAloud: Bool, readAloudBitrateKbps: Int, readAloudASREngineID: String,
    readAloudASRModelID: String?, storytellerConnectionID: UUID?,
    sendSourceEPUB: Bool, sendM4B: Bool, sendReadAloud: Bool,
    settingsStore: StudioSettingsStore = StudioSettingsStore(url: AppPaths.studioSettingsURL)
  ) async {
    try? await settingsStore.rememberProduction(
      RememberedProductionSettings(
        backendID: backendID, modelID: modelID, voiceID: voiceID,
        pacePreset: pacePreset, expressivityPreset: expressivityPreset,
        bitrateKbps: bitrateKbps, workers: workers,
        unitGranularityID: unitGranularityID, announceTitles: announceTitles,
        paragraphPauseSeconds: paragraphPauseSeconds,
        chapterPauseSeconds: chapterPauseSeconds, createReadAloud: createReadAloud,
        readAloudBitrateKbps: readAloudBitrateKbps,
        readAloudASREngineID: readAloudASREngineID,
        readAloudASRModelID: readAloudASRModelID,
        storytellerConnectionID: storytellerConnectionID,
        sendSourceEPUB: sendSourceEPUB, sendM4B: sendM4B, sendReadAloud: sendReadAloud))
  }

  /// Overlays remembered settings, keeping the configured default wherever the
  /// remembered value is no longer valid — an uninstalled voice, a bitrate or
  /// worker count outside current limits, or obsolete recognition settings.
  func applying(_ remembered: RememberedProductionSettings) async -> ProductionDefaults {
    var value = self
    if let resolved = try? await TTSInventoryProvider.shared.resolveCanonical(
      backendID: remembered.backendID, modelID: remembered.modelID,
      voiceID: remembered.voiceID, pace: remembered.pacePreset,
      expressivity: remembered.expressivityPreset)
    {
      value.publicModelID = resolved.publicModelID
      value.backendID = resolved.selection.voice.backendID.rawValue
      value.modelID = resolved.selection.voice.modelID
      value.voiceID = resolved.selection.voice.voiceID
      value.pacePreset = resolved.selection.controls.pace?.rawValue
      value.expressivityPreset = resolved.selection.controls.expressivity?.rawValue
    }
    if AudiobookConfig.allowedBitratesKbps.contains(remembered.bitrateKbps) {
      value.bitrateKbps = remembered.bitrateKbps
    }
    if (1...AudiobookConfig.maximumWorkers).contains(remembered.workers) {
      let effective = ProductionWorkerPolicy.resolved(
        remembered.workers, backendID: value.backendID, modelID: value.modelID,
        models: value.inventory.models)
      value.workers = effective
      value.workerSource = .remembered
      value.workerWarning = ProductionWorkerPolicy.warning(
        requested: remembered.workers, effective: effective, modelID: value.modelID)
    }
    if let granularity = remembered.unitGranularityID,
      ["paragraph", "sentence"].contains(granularity)
    {
      value.unitGranularityID = granularity
    }
    value.announceTitles = remembered.announceTitles
    if (0...10).contains(remembered.paragraphPauseSeconds) {
      value.paragraphPauseSeconds = remembered.paragraphPauseSeconds
    }
    if (0...10).contains(remembered.chapterPauseSeconds) {
      value.chapterPauseSeconds = remembered.chapterPauseSeconds
    }
    if ReadAloudDefaults.allowedOpusBitratesKbps.contains(remembered.readAloudBitrateKbps) {
      value.readAloudBitrateKbps = remembered.readAloudBitrateKbps
    }
    // New production always consumes the digest-bound synthesis timeline.
    // Recognition engines remain available to explicit diagnostic/audit
    // commands, but remembered production choices migrate to the exact path.
    value.readAloudASREngineID = "synthesis"
    value.readAloudASRModelID = nil
    value.createReadAloud = remembered.createReadAloud
    value.storytellerConnectionID = remembered.storytellerConnectionID
    value.sendSourceEPUB = remembered.sendSourceEPUB
    value.sendM4B = remembered.sendM4B
    value.sendReadAloud = remembered.sendReadAloud
    return value
  }
}

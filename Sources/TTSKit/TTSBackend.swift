import Foundation

package struct TTSBackendID: RawRepresentable, Codable, Hashable, Sendable {
  package let rawValue: String
  package init(rawValue: String) { self.rawValue = rawValue }
}

package struct VoiceKey: Codable, Hashable, Sendable {
  package let backendID: TTSBackendID
  package let modelID: String
  package let voiceID: String

  package init(backendID: TTSBackendID, modelID: String, voiceID: String) {
    self.backendID = backendID
    self.modelID = modelID
    self.voiceID = voiceID
  }
}

package struct VoiceDescriptor: Codable, Hashable, Sendable {
  package let key: VoiceKey
  package let name: String
  package let language: String
  package let quality: String
  package let modelRevision: String?
  package let voiceRevision: String?

  package init(
    key: VoiceKey, name: String, language: String, quality: String,
    modelRevision: String? = nil, voiceRevision: String? = nil
  ) {
    self.key = key
    self.name = name
    self.language = language
    self.quality = quality
    self.modelRevision = modelRevision
    self.voiceRevision = voiceRevision
  }
}

package struct TTSModelKey: Codable, Hashable, Sendable {
  package let backendID: TTSBackendID
  package let modelID: String

  package init(backendID: TTSBackendID, modelID: String) {
    self.backendID = backendID
    self.modelID = modelID
  }
}

package struct TTSPreset: Codable, Hashable, Sendable {
  package static let neutral = try! TTSPreset(3)
  package let rawValue: Int

  package init(_ rawValue: Int) throws {
    guard (1...5).contains(rawValue) else {
      throw TTSBackendError.invalidInput("TTS presets must be between 1 and 5.")
    }
    self.rawValue = rawValue
  }

  package init(from decoder: any Decoder) throws {
    try self.init(decoder.singleValueContainer().decode(Int.self))
  }

  package func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

package enum TTSControlCapability: String, Codable, Hashable, Sendable {
  case unsupported
  case preset1Through5
}

package struct TTSControlCapabilities: Codable, Hashable, Sendable {
  package static let none = TTSControlCapabilities()
  package let pace: TTSControlCapability
  package let expressivity: TTSControlCapability

  package init(
    pace: TTSControlCapability = .unsupported,
    expressivity: TTSControlCapability = .unsupported
  ) {
    self.pace = pace
    self.expressivity = expressivity
  }

  package init(pace: Bool, expressivity: Bool) {
    self.init(
      pace: pace ? .preset1Through5 : .unsupported,
      expressivity: expressivity ? .preset1Through5 : .unsupported)
  }

  package func validate(_ controls: TTSSynthesisControls) throws {
    if controls.pacePreset != nil, pace == .unsupported {
      throw TTSBackendError.invalidInput("This TTS model does not support pace controls.")
    }
    if controls.expressivityPreset != nil, expressivity == .unsupported {
      throw TTSBackendError.invalidInput("This TTS model does not support expressivity controls.")
    }
  }
}

package typealias TTSModelCapabilities = TTSControlCapabilities

package struct TTSSynthesisControls: Codable, Hashable, Sendable {
  package static let none = TTSSynthesisControls(pacePreset: nil, expressivityPreset: nil)
  package let pacePreset: TTSPreset?
  package let expressivityPreset: TTSPreset?

  package var pace: TTSPreset? { pacePreset }
  package var expressivity: TTSPreset? { expressivityPreset }

  package init(pacePreset: TTSPreset? = nil, expressivityPreset: TTSPreset? = nil) {
    self.pacePreset = pacePreset
    self.expressivityPreset = expressivityPreset
  }

  package init(pace: TTSPreset?, expressivity: TTSPreset?) {
    self.init(pacePreset: pace, expressivityPreset: expressivity)
  }
}

package struct TTSVoiceSelection: Codable, Hashable, Sendable {
  package let voice: VoiceKey
  package let controls: TTSSynthesisControls

  package init(voice: VoiceKey, controls: TTSSynthesisControls = .none) {
    self.voice = voice
    self.controls = controls
  }

  package init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    voice = try container.decode(VoiceKey.self, forKey: .voice)
    controls =
      try container.decodeIfPresent(TTSSynthesisControls.self, forKey: .controls)
      ?? TTSSynthesisControls.none
  }
}

package enum TTSModelAvailability: Codable, Hashable, Sendable {
  case available
  case unavailable(reason: String)
}

package struct TTSModelDescriptor: Codable, Hashable, Sendable {
  package let key: TTSModelKey
  package let name: String
  package let revision: String?
  package let defaultVoice: VoiceKey
  package let availability: TTSModelAvailability
  package let controls: TTSControlCapabilities
  package let recommendedAudiobookWorkers: Int?
  /// Hard production ceiling for audiobook synthesis. Nil means the
  /// application-wide ceiling applies. Developer benchmarks deliberately do
  /// not consult this capability.
  package let maximumAudiobookWorkers: Int?

  package var displayName: String { name }
  package var capabilities: TTSControlCapabilities { controls }

  package init(
    key: TTSModelKey, name: String, revision: String?, defaultVoice: VoiceKey,
    availability: TTSModelAvailability = .available,
    controls: TTSControlCapabilities = .none,
    recommendedAudiobookWorkers: Int? = nil,
    maximumAudiobookWorkers: Int? = nil
  ) {
    self.key = key
    self.name = name
    self.revision = revision
    self.defaultVoice = defaultVoice
    self.availability = availability
    self.controls = controls
    self.recommendedAudiobookWorkers = recommendedAudiobookWorkers
    self.maximumAudiobookWorkers = maximumAudiobookWorkers
  }

  package func validate(_ controls: TTSSynthesisControls) throws {
    try self.controls.validate(controls)
  }
}

package enum TTSUtteranceMode: String, Codable, Hashable, Sendable {
  case sentenceSequence
  case singleUtterance
}

package enum TTSTimingMode: String, Codable, Hashable, Sendable {
  case none
  case word
}

package struct TTSSynthesisRequest: Codable, Hashable, Sendable {
  package let text: String
  package let selection: TTSVoiceSelection
  package let utteranceMode: TTSUtteranceMode
  package let timingMode: TTSTimingMode

  package var includeTimings: Bool { timingMode == .word }

  package init(
    text: String, selection: TTSVoiceSelection,
    utteranceMode: TTSUtteranceMode = .singleUtterance,
    timingMode: TTSTimingMode = .none
  ) {
    self.text = text
    self.selection = selection
    self.utteranceMode = utteranceMode
    self.timingMode = timingMode
  }

  package init(
    text: String, selection: TTSVoiceSelection,
    utteranceMode: TTSUtteranceMode = .singleUtterance,
    includeTimings: Bool
  ) {
    self.init(
      text: text, selection: selection, utteranceMode: utteranceMode,
      timingMode: includeTimings ? .word : .none)
  }

  package init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    text = try container.decode(String.self, forKey: .text)
    selection = try container.decode(TTSVoiceSelection.self, forKey: .selection)
    utteranceMode =
      try container.decodeIfPresent(TTSUtteranceMode.self, forKey: .utteranceMode)
      ?? .singleUtterance
    if let timingMode = try container.decodeIfPresent(TTSTimingMode.self, forKey: .timingMode) {
      self.timingMode = timingMode
    } else {
      let includeTimings = try container.decodeIfPresent(Bool.self, forKey: .includeTimings) ?? false
      timingMode = includeTimings ? .word : .none
    }
  }

  package func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(text, forKey: .text)
    try container.encode(selection, forKey: .selection)
    try container.encode(utteranceMode, forKey: .utteranceMode)
    try container.encode(timingMode, forKey: .timingMode)
  }

  package enum CodingKeys: String, CodingKey {
    case text, selection, utteranceMode, timingMode, includeTimings
  }
}

package struct TTSRuntimeProvenance: Codable, Hashable, Sendable {
  package static let maximumFieldBytes = 1_024

  package let backendID: TTSBackendID
  package let modelID: String
  package let voiceID: String
  package let operatingSystemVersion: String
  package let operatingSystemBuild: String
  package let frameworkIdentifier: String
  package let frameworkVersion: String
  package let frameworkSDKVersion: String?
  package let frameworkSDKBuild: String?
  package let adapterIdentifier: String?
  package let backendAdapterRevision: String?
  package let modelRevision: String?
  package let voiceRevision: String?
  package let resourceIdentity: String?
  package let resourceRevision: String?

  /// The engine and machine this provenance describes, without the chosen
  /// voice. A prepared session serves every voice its backend offers — the
  /// HTTP gateway routes each request to whichever voice was asked for — so
  /// only these fields must stay identical across a session's lifetime;
  /// the voice-specific fields are checked against each request's own
  /// selection instead.
  package struct EngineIdentity: Hashable, Sendable {
    package let backendID: TTSBackendID
    package let modelID: String
    package let operatingSystemVersion: String
    package let operatingSystemBuild: String
    package let frameworkIdentifier: String
    package let frameworkVersion: String
    package let frameworkSDKVersion: String?
    package let frameworkSDKBuild: String?
    package let adapterIdentifier: String?
    package let backendAdapterRevision: String?
    package let modelRevision: String?
  }

  package var engineIdentity: EngineIdentity {
    EngineIdentity(
      backendID: backendID, modelID: modelID,
      operatingSystemVersion: operatingSystemVersion,
      operatingSystemBuild: operatingSystemBuild,
      frameworkIdentifier: frameworkIdentifier, frameworkVersion: frameworkVersion,
      frameworkSDKVersion: frameworkSDKVersion, frameworkSDKBuild: frameworkSDKBuild,
      adapterIdentifier: adapterIdentifier,
      backendAdapterRevision: backendAdapterRevision, modelRevision: modelRevision)
  }

  package init(
    backendID: TTSBackendID, modelID: String, voiceID: String,
    operatingSystemVersion: String, operatingSystemBuild: String,
    frameworkIdentifier: String, frameworkVersion: String,
    frameworkSDKVersion: String? = nil, frameworkSDKBuild: String? = nil,
    adapterIdentifier: String? = nil, backendAdapterRevision: String? = nil,
    modelRevision: String? = nil, voiceRevision: String? = nil,
    resourceIdentity: String? = nil, resourceRevision: String? = nil
  ) throws {
    let fields = [
      backendID.rawValue, modelID, voiceID, operatingSystemVersion,
      operatingSystemBuild, frameworkIdentifier, frameworkVersion,
      frameworkSDKVersion, frameworkSDKBuild, adapterIdentifier,
      backendAdapterRevision, modelRevision, voiceRevision,
      resourceIdentity, resourceRevision,
    ].compactMap { $0 }
    guard fields.allSatisfy({ !$0.isEmpty && $0.utf8.count <= Self.maximumFieldBytes }) else {
      throw TTSBackendError.invalidInput("TTS runtime provenance is invalid or too large.")
    }
    self.backendID = backendID
    self.modelID = modelID
    self.voiceID = voiceID
    self.operatingSystemVersion = operatingSystemVersion
    self.operatingSystemBuild = operatingSystemBuild
    self.frameworkIdentifier = frameworkIdentifier
    self.frameworkVersion = frameworkVersion
    self.frameworkSDKVersion = frameworkSDKVersion
    self.frameworkSDKBuild = frameworkSDKBuild
    self.adapterIdentifier = adapterIdentifier
    self.backendAdapterRevision = backendAdapterRevision
    self.modelRevision = modelRevision
    self.voiceRevision = voiceRevision
    self.resourceIdentity = resourceIdentity
    self.resourceRevision = resourceRevision
  }

  package init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      backendID: container.decode(TTSBackendID.self, forKey: .backendID),
      modelID: container.decode(String.self, forKey: .modelID),
      voiceID: container.decode(String.self, forKey: .voiceID),
      operatingSystemVersion: container.decode(String.self, forKey: .operatingSystemVersion),
      operatingSystemBuild: container.decode(String.self, forKey: .operatingSystemBuild),
      frameworkIdentifier: container.decode(String.self, forKey: .frameworkIdentifier),
      frameworkVersion: container.decode(String.self, forKey: .frameworkVersion),
      frameworkSDKVersion: container.decodeIfPresent(
        String.self, forKey: .frameworkSDKVersion),
      frameworkSDKBuild: container.decodeIfPresent(String.self, forKey: .frameworkSDKBuild),
      adapterIdentifier: container.decodeIfPresent(String.self, forKey: .adapterIdentifier),
      backendAdapterRevision: container.decodeIfPresent(
        String.self, forKey: .backendAdapterRevision),
      modelRevision: container.decodeIfPresent(String.self, forKey: .modelRevision),
      voiceRevision: container.decodeIfPresent(String.self, forKey: .voiceRevision),
      resourceIdentity: container.decodeIfPresent(String.self, forKey: .resourceIdentity),
      resourceRevision: container.decodeIfPresent(String.self, forKey: .resourceRevision))
  }
}

package struct PCM16Audio: Codable, Hashable, Sendable {
  package let data: Data
  package let sampleRate: Int
  package let channels: Int

  package init(data: Data, sampleRate: Int, channels: Int) throws {
    let (bytesPerFrame, overflow) = MemoryLayout<Int16>.size.multipliedReportingOverflow(
      by: channels)
    guard sampleRate > 0, channels > 0, !overflow, bytesPerFrame > 0,
      !data.isEmpty, data.count.isMultiple(of: bytesPerFrame)
    else {
      throw TTSBackendError.invalidAudioFormat
    }
    self.data = data
    self.sampleRate = sampleRate
    self.channels = channels
  }

  package init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      data: container.decode(Data.self, forKey: .data),
      sampleRate: container.decode(Int.self, forKey: .sampleRate),
      channels: container.decode(Int.self, forKey: .channels))
  }
}

package struct TTSSynthesisResult: Sendable, Equatable {
  package let audio: PCM16Audio
  package let timings: [SpokenWordTiming]?
  package let provenance: TTSRuntimeProvenance?

  package init(
    audio: PCM16Audio, timings: [SpokenWordTiming]? = nil,
    provenance: TTSRuntimeProvenance? = nil
  ) {
    self.audio = audio
    self.timings = timings
    self.provenance = provenance
  }
}

package struct TTSWorkloadConfiguration: Sendable {
  package enum Purpose: Sendable { case http, audiobook }

  package let purpose: Purpose
  package let maxConcurrency: Int
  package let maxQueuedRequests: Int
  package let deadlineSeconds: Double

  package init(
    purpose: Purpose, maxConcurrency: Int, maxQueuedRequests: Int, deadlineSeconds: Double
  ) {
    self.purpose = purpose
    self.maxConcurrency = maxConcurrency
    self.maxQueuedRequests = maxQueuedRequests
    self.deadlineSeconds = deadlineSeconds
  }
}

package enum TTSBackendError: Error, LocalizedError, Sendable {
  case invalidAudioFormat
  case invalidInput(String)
  case voiceNotFound(VoiceKey)
  case permissionRequired
  case unavailable
  case queueFull(Int)
  case crashed
  case timeout
  case synthesisFailed
  case inconsistentRuntimeProvenance

  package var errorDescription: String? {
    switch self {
    case .invalidAudioFormat: "The speech backend returned an unsupported PCM format."
    case .invalidInput(let message): message
    case .voiceNotFound(let key): "Voice '\(key.voiceID)' is unavailable."
    case .permissionRequired: "The speech backend requires additional filesystem permission."
    case .unavailable: "The speech backend is unavailable."
    case .queueFull(let capacity): "The speech queue is full (\(capacity) waiting requests)."
    case .crashed: "A speech worker exited unexpectedly."
    case .timeout: "Speech synthesis exceeded its deadline."
    case .synthesisFailed: "The speech backend could not synthesize this input."
    case .inconsistentRuntimeProvenance:
      "Speech workers reported inconsistent runtime provenance."
    }
  }
}

/// One spoken word (or engine-grouped phrase): a UTF-16 range into the
/// synthesized input text plus its utterance-relative start in seconds.
/// Compact coding keys keep worker IPC frames small.
package struct SpokenWordTiming: Sendable, Codable, Equatable {
  package var utf16Offset: Int
  package var utf16Length: Int
  package var startSeconds: Double

  package init(utf16Offset: Int, utf16Length: Int, startSeconds: Double) {
    self.utf16Offset = utf16Offset
    self.utf16Length = utf16Length
    self.startSeconds = startSeconds
  }

  package enum CodingKeys: String, CodingKey {
    case utf16Offset = "o"
    case utf16Length = "l"
    case startSeconds = "t"
  }
}

package protocol TTSSession: Sendable {
  func prepare(selection: TTSVoiceSelection) async throws -> TTSRuntimeProvenance
  func synthesize(request: TTSSynthesisRequest) async throws -> TTSSynthesisResult
  func shutdown() async
}

package protocol TTSBackendFactory: Sendable {
  var id: TTSBackendID { get }
  var models: [TTSModelDescriptor] { get }
  var voices: [VoiceDescriptor] { get }
  var defaultVoice: VoiceKey { get }
  func resolveVoice(_ requested: String) -> VoiceKey?
  func makeSession(configuration: TTSWorkloadConfiguration) throws -> any TTSSession
}

package enum TTSRegistryError: Error, Sendable {
  case duplicateBackend(TTSBackendID)
  case backendNotFound(TTSBackendID)
  case modelNotFound(TTSModelKey)
  case ambiguousVoice(String)
  case voiceNotFound(String)
  case invalidBackend(TTSBackendID)
  case duplicateModel(TTSModelKey)
  case duplicateVoice(VoiceKey)
  case invalidDefaultVoice(TTSBackendID)
}

package struct TTSBackendRegistry: Sendable {
  private let backends: [TTSBackendID: any TTSBackendFactory]
  package let models: [TTSModelDescriptor]

  package init(_ factories: [any TTSBackendFactory]) throws {
    var indexed: [TTSBackendID: any TTSBackendFactory] = [:]
    var modelKeys = Set<TTSModelKey>()
    var voiceKeys = Set<VoiceKey>()
    var descriptors: [TTSModelDescriptor] = []
    for factory in factories {
      guard indexed[factory.id] == nil else {
        throw TTSRegistryError.duplicateBackend(factory.id)
      }
      guard !factory.id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        !factory.models.isEmpty, !factory.voices.isEmpty,
        factory.voices.allSatisfy({
          $0.key.backendID == factory.id
            && !$0.key.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !$0.key.voiceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        })
      else { throw TTSRegistryError.invalidBackend(factory.id) }
      for model in factory.models {
        guard model.key.backendID == factory.id,
          !model.key.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          model.defaultVoice.backendID == factory.id,
          model.defaultVoice.modelID == model.key.modelID,
          factory.voices.contains(where: { $0.key == model.defaultVoice })
        else { throw TTSRegistryError.invalidBackend(factory.id) }
        guard modelKeys.insert(model.key).inserted else {
          throw TTSRegistryError.duplicateModel(model.key)
        }
        descriptors.append(model)
      }
      for voice in factory.voices {
        guard modelKeys.contains(
          TTSModelKey(backendID: voice.key.backendID, modelID: voice.key.modelID))
        else { throw TTSRegistryError.invalidBackend(factory.id) }
        guard voiceKeys.insert(voice.key).inserted else {
          throw TTSRegistryError.duplicateVoice(voice.key)
        }
      }
      guard factory.defaultVoice.backendID == factory.id,
        factory.voices.contains(where: { $0.key == factory.defaultVoice })
      else { throw TTSRegistryError.invalidDefaultVoice(factory.id) }
      indexed[factory.id] = factory
    }
    backends = indexed
    models = descriptors.sorted {
      ($0.key.backendID.rawValue, $0.key.modelID) < ($1.key.backendID.rawValue, $1.key.modelID)
    }
  }

  package var backendIDs: [TTSBackendID] {
    backends.keys.sorted { $0.rawValue < $1.rawValue }
  }

  package var voices: [VoiceDescriptor] {
    backendIDs.flatMap { backends[$0]?.voices ?? [] }
  }

  package func backend(_ id: TTSBackendID) -> (any TTSBackendFactory)? { backends[id] }

  package func model(_ key: TTSModelKey) -> TTSModelDescriptor? {
    models.first(where: { $0.key == key })
  }

  package func resolveVoice(
    _ requested: String, model requestedModel: TTSModelKey? = nil
  ) throws -> VoiceKey {
    let candidates: [VoiceKey]
    if let requestedModel {
      guard let backend = backends[requestedModel.backendID], model(requestedModel) != nil else {
        throw TTSRegistryError.modelNotFound(requestedModel)
      }
      candidates = backend.resolveVoice(requested).map { [$0] } ?? []
      guard candidates.allSatisfy({
        $0.backendID == requestedModel.backendID && $0.modelID == requestedModel.modelID
      }) else { throw TTSRegistryError.voiceNotFound(requested) }
    } else {
      candidates = backendIDs.compactMap { backends[$0]?.resolveVoice(requested) }
    }
    let unique = Array(Set(candidates))
    guard !unique.isEmpty else { throw TTSRegistryError.voiceNotFound(requested) }
    guard unique.count == 1 else { throw TTSRegistryError.ambiguousVoice(requested) }
    return unique[0]
  }

  package func validate(_ selection: TTSVoiceSelection) throws {
    let modelKey = TTSModelKey(
      backendID: selection.voice.backendID, modelID: selection.voice.modelID)
    guard let descriptor = model(modelKey) else { throw TTSRegistryError.modelNotFound(modelKey) }
    guard voices.contains(where: { $0.key == selection.voice }) else {
      throw TTSRegistryError.voiceNotFound(selection.voice.voiceID)
    }
    try descriptor.validate(selection.controls)
  }

  package func makeSession(
    backendID: TTSBackendID, configuration: TTSWorkloadConfiguration
  ) throws -> any TTSSession {
    guard let backend = backends[backendID] else { throw TTSRegistryError.backendNotFound(backendID) }
    return try backend.makeSession(configuration: configuration)
  }
}


extension TTSBackendFactory {
  package var models: [TTSModelDescriptor] {
    Dictionary(grouping: voices, by: { $0.key.modelID })
      .keys.sorted()
      .compactMap { modelID in
        guard let voice = voices.first(where: { $0.key.modelID == modelID }) else { return nil }
        let modelDefault = defaultVoice.modelID == modelID ? defaultVoice : voice.key
        return TTSModelDescriptor(
          key: TTSModelKey(backendID: id, modelID: modelID),
          name: modelID, revision: voice.modelRevision, defaultVoice: modelDefault)
      }
  }
}

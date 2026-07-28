import Foundation
import LocalTTSWorkerKit
import TTSKit

package struct GoldenGateTTSBackend: LocalTTSWorkerBackendFactory {
  package static let backendID = TTSBackendID(rawValue: "siri-fm")
  package static let modelID = "siri-expressive"

  package let id = Self.backendID
  package let models: [TTSModelDescriptor]
  package let voices: [VoiceDescriptor]
  package let defaultVoice: VoiceKey

  private let makeClient: @Sendable (VoiceKey) throws -> any LocalTTSWorkerTransport
  private let lookup: [String: VoiceKey]

  package init() throws {
    try self.init(
      voices: GoldenGateVoiceCatalog.discover(),
      makeClient: { try GoldenGateWorkerClient(voice: $0) })
  }

  init(
    voices discovered: [GoldenGateVoice],
    makeClient: @escaping @Sendable (VoiceKey) throws -> any LocalTTSWorkerTransport
  ) throws {
    guard !discovered.isEmpty else { throw TTSBackendError.unavailable }
    let sorted = discovered.sorted {
      ($0.language, $0.name, $0.id) < ($1.language, $1.name, $1.id)
    }
    let preferred = sorted.first(where: { $0.id == "en-US-F" }) ?? sorted[0]
    defaultVoice = VoiceKey(
      backendID: Self.backendID, modelID: Self.modelID, voiceID: preferred.id)
    voices = sorted.map { voice in
      VoiceDescriptor(
        key: VoiceKey(
          backendID: Self.backendID, modelID: Self.modelID, voiceID: voice.id),
        name: voice.name,
        language: voice.language,
        quality: voice.quality,
        modelRevision: GoldenGateRuntimeIdentity.current.revision,
        voiceRevision: voice.revision)
    }
    models = [
      TTSModelDescriptor(
        key: TTSModelKey(backendID: Self.backendID, modelID: Self.modelID),
        name: "Siri Expressive (Golden Gate)",
        revision: GoldenGateRuntimeIdentity.current.revision,
        defaultVoice: defaultVoice,
        controls: TTSControlCapabilities(
          pace: .preset1Through5, expressivity: .preset1Through5),
        recommendedAudiobookWorkers: 1,
        maximumAudiobookWorkers: 1)
    ]
    self.makeClient = makeClient

    var aliases: [String: [VoiceKey]] = [:]
    for voice in voices {
      aliases[voice.key.voiceID.lowercased(), default: []].append(voice.key)
      aliases[voice.name.lowercased(), default: []].append(voice.key)
      aliases["\(voice.language):\(voice.name)".lowercased(), default: []].append(voice.key)
    }
    lookup = aliases.compactMapValues { keys in
      let unique = Array(Set(keys))
      return unique.count == 1 ? unique[0] : nil
    }
  }

  package func resolveVoice(_ requested: String) -> VoiceKey? {
    lookup[requested.lowercased()]
  }

  package func makeSession(
    configuration: TTSWorkloadConfiguration
  ) throws -> any TTSSession {
    let pool = LocalTTSWorkerPool(
      maxWorkers: configuration.maxConcurrency,
      maxQueued: configuration.maxQueuedRequests,
      deadlineSeconds: configuration.deadlineSeconds,
      makeClient: makeClient)
    return GoldenGateTTSSession(
      voices: Set(voices.map(\.key)), model: models[0], pool: pool, ownsPool: true)
  }

  package func makeWorkerClient(for voice: VoiceKey) throws -> any LocalTTSWorkerTransport {
    try makeClient(voice)
  }

  package func makeSession(
    configuration: TTSWorkloadConfiguration,
    sharedWorkerPool: LocalTTSWorkerPool
  ) throws -> any TTSSession {
    GoldenGateTTSSession(
      voices: Set(voices.map(\.key)), model: models[0],
      pool: sharedWorkerPool, ownsPool: false)
  }
}

private actor GoldenGateTTSSession: TTSSession {
  let voices: Set<VoiceKey>
  let model: TTSModelDescriptor
  let pool: LocalTTSWorkerPool
  let ownsPool: Bool
  var preparedProvenance: TTSRuntimeProvenance?

  init(
    voices: Set<VoiceKey>, model: TTSModelDescriptor,
    pool: LocalTTSWorkerPool, ownsPool: Bool
  ) {
    self.voices = voices
    self.model = model
    self.pool = pool
    self.ownsPool = ownsPool
  }

  func prepare(
    selection: TTSVoiceSelection
  ) async throws -> TTSRuntimeProvenance {
    let selection = try validated(selection)
    preparedProvenance = nil
    let request = TTSSynthesisRequest(
      text: "Expressive voice warm-up \(UUID().uuidString).", selection: selection,
      utteranceMode: .singleUtterance)
    let result = try await pool.synthesize(request)
    guard let provenance = result.provenance,
      provenance.backendID == selection.voice.backendID,
      provenance.modelID == selection.voice.modelID,
      provenance.voiceID == selection.voice.voiceID
    else { throw TTSBackendError.inconsistentRuntimeProvenance }
    preparedProvenance = provenance
    return provenance
  }

  func synthesize(request: TTSSynthesisRequest) async throws -> TTSSynthesisResult {
    let selection = try validated(request.selection)
    let resolved = TTSSynthesisRequest(
      text: request.text,
      selection: selection,
      utteranceMode: .singleUtterance,
      timingMode: .none)
    let result = try await pool.synthesize(resolved)
    // The engine identity must be the one this session prepared; the voice
    // fields must be the ones THIS request asked for. A session serves every
    // voice its backend offers, so whole-provenance equality with the
    // prepared voice would reject every other voice.
    if let expected = preparedProvenance {
      guard let actual = result.provenance,
        actual.engineIdentity == expected.engineIdentity,
        actual.backendID == selection.voice.backendID,
        actual.modelID == selection.voice.modelID,
        actual.voiceID == selection.voice.voiceID
      else { throw TTSBackendError.inconsistentRuntimeProvenance }
    }
    return TTSSynthesisResult(
      audio: result.audio, timings: nil, provenance: result.provenance)
  }

  func shutdown() async {
    if ownsPool { await pool.shutdown() }
  }

  private func validated(_ selection: TTSVoiceSelection) throws -> TTSVoiceSelection {
    guard voices.contains(selection.voice) else {
      throw TTSBackendError.voiceNotFound(selection.voice)
    }
    var controls = selection.controls
    if controls.pace == nil || controls.expressivity == nil {
      controls = TTSSynthesisControls(
        pace: controls.pace ?? .neutral,
        expressivity: controls.expressivity ?? .neutral)
    }
    try model.validate(controls)
    return TTSVoiceSelection(voice: selection.voice, controls: controls)
  }
}

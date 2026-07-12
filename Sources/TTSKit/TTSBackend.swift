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

package struct PCM16Audio: Sendable, Equatable {
  package let data: Data
  package let sampleRate: Int
  package let channels: Int

  package init(data: Data, sampleRate: Int, channels: Int) throws {
    guard sampleRate > 0, channels > 0, data.count.isMultiple(of: 2 * channels) else {
      throw TTSBackendError.invalidAudioFormat
    }
    self.data = data
    self.sampleRate = sampleRate
    self.channels = channels
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
  case voiceNotFound(VoiceKey)
  case permissionRequired
  case unavailable
  case queueFull(Int)
  case crashed
  case timeout
  case synthesisFailed

  package var errorDescription: String? {
    switch self {
    case .invalidAudioFormat: "The speech backend returned an unsupported PCM format."
    case .voiceNotFound(let key): "Voice '\(key.voiceID)' is unavailable."
    case .permissionRequired: "The speech backend requires additional filesystem permission."
    case .unavailable: "The speech backend is unavailable."
    case .queueFull(let capacity): "The speech queue is full (\(capacity) waiting requests)."
    case .crashed: "A speech worker exited unexpectedly."
    case .timeout: "Speech synthesis exceeded its deadline."
    case .synthesisFailed: "The speech backend could not synthesize this input."
    }
  }
}

package protocol TTSSession: Sendable {
  func prepare(voice: VoiceKey) async throws
  func synthesize(text: String, voice: VoiceKey) async throws -> PCM16Audio
  func shutdown() async
}

package protocol TTSBackendFactory: Sendable {
  var id: TTSBackendID { get }
  var voices: [VoiceDescriptor] { get }
  var defaultVoice: VoiceKey { get }
  func resolveVoice(_ requested: String) -> VoiceKey?
  func makeSession(configuration: TTSWorkloadConfiguration) throws -> any TTSSession
}

package enum TTSRegistryError: Error, Sendable {
  case duplicateBackend(TTSBackendID)
  case backendNotFound(TTSBackendID)
}

package struct TTSBackendRegistry: Sendable {
  private let backends: [TTSBackendID: any TTSBackendFactory]

  package init(_ factories: [any TTSBackendFactory]) throws {
    var indexed: [TTSBackendID: any TTSBackendFactory] = [:]
    for factory in factories {
      guard indexed.updateValue(factory, forKey: factory.id) == nil else {
        throw TTSRegistryError.duplicateBackend(factory.id)
      }
    }
    backends = indexed
  }

  package var backendIDs: [TTSBackendID] {
    backends.keys.sorted { $0.rawValue < $1.rawValue }
  }

  package var voices: [VoiceDescriptor] {
    backendIDs.flatMap { backends[$0]?.voices ?? [] }
  }

  package func backend(_ id: TTSBackendID) -> (any TTSBackendFactory)? { backends[id] }

  package func makeSession(
    backendID: TTSBackendID, configuration: TTSWorkloadConfiguration
  ) throws -> any TTSSession {
    guard let backend = backends[backendID] else { throw TTSRegistryError.backendNotFound(backendID) }
    return try backend.makeSession(configuration: configuration)
  }
}

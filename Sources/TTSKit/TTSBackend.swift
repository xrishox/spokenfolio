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
  func prepare(voice: VoiceKey) async throws
  func synthesize(text: String, voice: VoiceKey) async throws -> PCM16Audio
  /// Ground-truth word timings alongside the audio, for backends that can
  /// report them; the default returns no timings.
  func synthesizeDetailed(
    text: String, voice: VoiceKey
  ) async throws -> (audio: PCM16Audio, timings: [SpokenWordTiming]?)
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
  case invalidBackend(TTSBackendID)
  case duplicateVoice(VoiceKey)
  case invalidDefaultVoice(TTSBackendID)
}

package struct TTSBackendRegistry: Sendable {
  private let backends: [TTSBackendID: any TTSBackendFactory]

  package init(_ factories: [any TTSBackendFactory]) throws {
    var indexed: [TTSBackendID: any TTSBackendFactory] = [:]
    var voiceKeys = Set<VoiceKey>()
    for factory in factories {
      guard indexed[factory.id] == nil else {
        throw TTSRegistryError.duplicateBackend(factory.id)
      }
      guard !factory.id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        !factory.voices.isEmpty,
        factory.voices.allSatisfy({
          $0.key.backendID == factory.id && !$0.key.modelID.isEmpty && !$0.key.voiceID.isEmpty
        })
      else { throw TTSRegistryError.invalidBackend(factory.id) }
      for voice in factory.voices {
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


extension TTSSession {
  package func synthesizeDetailed(
    text: String, voice: VoiceKey
  ) async throws -> (audio: PCM16Audio, timings: [SpokenWordTiming]?) {
    (try await synthesize(text: text, voice: voice), nil)
  }
}

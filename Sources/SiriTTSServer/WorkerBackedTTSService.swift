import Foundation
import SiriTTSCore

final class WorkerBackedTTSService: TTSService, @unchecked Sendable {
  let sampleRate = SiriVoiceCatalog.requiredSampleRate
  let defaultVoice: String
  let availableVoices: [String]
  let voiceCatalog: [VoiceInfo]

  private let assetsByID: [String: SiriVoiceAsset]
  private let voiceLookup: [String: String]
  private let pool: SiriWorkerPool

  init(config: ServerConfig) throws {
    let assets = SiriVoiceCatalog.discover()
    guard !assets.isEmpty else { throw ServiceError.engineUnavailable }

    var byID: [String: SiriVoiceAsset] = [:]
    for asset in assets { byID[asset.id] = asset }
    assetsByID = byID
    voiceCatalog = assets.map(\.voiceInfo)
    availableVoices = assets.map(\.displayName).sorted()
    voiceLookup = SiriVoiceCatalog.makeVoiceLookup(assets)

    if let configured = config.defaultVoice {
      guard let resolved = voiceLookup[configured.lowercased()] else {
        throw ServiceError.voiceNotFound(configured)
      }
      defaultVoice = resolved
    } else {
      defaultVoice = SiriVoiceCatalog.preferred(assets)!.id
    }

    pool = SiriWorkerPool(
      maxWorkers: config.maxWorkers,
      maxQueued: config.maxQueuedRequests,
      deadlineSeconds: config.requestDeadlineSeconds)
  }

  func initialize() async throws {
    try SiriPermissionPreflight.verifyModelAccess()
    let pcm = try await pool.synthesize(text: "Siri voice ready.", voiceID: defaultVoice)
    guard !pcm.isEmpty else { throw ServiceError.engineUnavailable }
  }

  func resolveVoice(_ voice: String) -> String? { voiceLookup[voice.lowercased()] }

  func synthesize(text: String, voice: String) async throws -> Data {
    var pcm = Data()
    for try await chunk in synthesizeStream(text: text, voice: voice) { pcm.append(chunk) }
    return makeWAV(pcmData: pcm, sampleRate: sampleRate)
  }

  func synthesizeStream(text: String, voice: String) -> AsyncThrowingStream<Data, Error> {
    guard let canonical = resolveVoice(voice), assetsByID[canonical] != nil else {
      return AsyncThrowingStream { $0.finish(throwing: ServiceError.voiceNotFound(voice)) }
    }
    let sentences = splitSentences(text)
    return AsyncThrowingStream { continuation in
      let task = Task {
        do {
          for sentence in sentences {
            try Task.checkCancellation()
            continuation.yield(try await self.pool.synthesize(text: sentence, voiceID: canonical))
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { @Sendable _ in task.cancel() }
    }
  }

  func shutdown() async { await pool.shutdown() }
}

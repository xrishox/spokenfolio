import Darwin
import Foundation
import TTSKit

final class SiriWorkerEngine {
  private let runtime: SiriPrivateTTSRuntime
  private let engine: SiriPrivateTTSEngine

  init(voiceID: String) throws {
    guard let asset = SiriVoiceCatalog.discover().first(where: { $0.id == voiceID }) else {
      throw SiriTTSError.voiceNotFound(voiceID)
    }
    runtime = try SiriPrivateTTSRuntime()
    engine = try runtime.makeEngine(for: asset)
  }

  /// With `splitIntoSentences` false the engine receives the whole text as
  /// ONE utterance and paces the sentence transitions itself (the audiobook
  /// pipeline's paragraph mode); true is the sentence-by-sentence behavior
  /// the HTTP path keeps.
  func synthesize(_ text: String, splitIntoSentences: Bool) throws -> Data {
    try synthesizeDetailed(
      text, splitIntoSentences: splitIntoSentences, includeTimings: false
    ).pcm
  }

  /// Timings are captured only for the unsplit paragraph mode: the sentence
  /// loop would need per-sentence offset rebasing the HTTP path never uses.
  func synthesizeDetailed(
    _ text: String, splitIntoSentences: Bool, includeTimings: Bool
  ) throws -> (pcm: Data, timings: [SiriPrivateTTSEngine.EngineWordTiming]?) {
    if !splitIntoSentences, includeTimings {
      let result = try engine.synthesizePCMDetailed(text: text)
      guard result.pcm.count.isMultiple(of: MemoryLayout<Int16>.size),
        result.pcm.count <= WorkerFraming.maximumPCMBytes
      else { throw SiriTTSError.unsupportedAudioFormat("worker", "PCM response is too large") }
      return (result.pcm, result.timings)
    }
    var pcm = Data()
    for sentence in splitIntoSentences ? splitSentences(text) : [text] {
      let utterance = try engine.synthesizePCM(text: sentence)
      guard utterance.count.isMultiple(of: MemoryLayout<Int16>.size),
        utterance.count <= WorkerFraming.maximumPCMBytes - pcm.count
      else { throw SiriTTSError.unsupportedAudioFormat("worker", "PCM response is too large") }
      pcm.append(utterance)
    }
    guard !pcm.isEmpty else { throw SiriTTSError.noAudioProduced("worker") }
    return (pcm, nil)
  }
}

package enum SiriWorkerMain {
  package static func run(voiceID: String) -> Never {
    let input = FileHandle.standardInput
    let output = FileHandle.standardOutput
    var engine: SiriWorkerEngine?

    while true {
      let request: WorkerRequest
      do {
        guard let next = try WorkerFraming.readRequest(from: input) else { _exit(EXIT_SUCCESS) }
        request = next
      } catch {
        _exit(EX_PROTOCOL)
      }

      if engine == nil {
        do {
          engine = try SiriWorkerEngine(voiceID: voiceID)
        } catch {
          try? WorkerFraming.writeResponse(
            requestID: request.id,
            errorCode: "engine_unavailable",
            to: output)
          _exit(EX_UNAVAILABLE)
        }
      }

      do {
        guard let engine else { throw SiriTTSError.noAudioProduced("worker engine") }
        let result = try engine.synthesizeDetailed(
          request.text, splitIntoSentences: request.splitSentences,
          includeTimings: request.includeTimings)
        var timingsJSON: Data?
        if request.includeTimings, let timings = result.timings, !timings.isEmpty {
          let encoded = try JSONEncoder().encode(timings)
          if encoded.count <= WorkerFraming.maximumTimingsBytes { timingsJSON = encoded }
        }
        try WorkerFraming.writeResponse(
          requestID: request.id, pcm: result.pcm, timingsJSON: timingsJSON, to: output)
      } catch {
        try? WorkerFraming.writeResponse(
          requestID: request.id,
          errorCode: "synthesis_failed",
          to: output)
      }
    }
  }
}

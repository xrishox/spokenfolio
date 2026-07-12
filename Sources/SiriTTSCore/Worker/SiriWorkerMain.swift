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
    var pcm = Data()
    for sentence in splitIntoSentences ? splitSentences(text) : [text] {
      pcm.append(try engine.synthesizePCM(text: sentence))
    }
    guard !pcm.isEmpty else { throw SiriTTSError.noAudioProduced("worker") }
    return pcm
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
        let pcm = try engine!.synthesize(
          request.text, splitIntoSentences: request.splitSentences)
        try WorkerFraming.writeResponse(requestID: request.id, pcm: pcm, to: output)
      } catch {
        try? WorkerFraming.writeResponse(
          requestID: request.id,
          errorCode: "synthesis_failed",
          to: output)
      }
    }
  }
}

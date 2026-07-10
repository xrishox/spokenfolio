import Darwin
import Foundation

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

  func synthesize(_ text: String) throws -> Data {
    var pcm = Data()
    for sentence in splitSentences(text) {
      pcm.append(try engine.synthesizePCM(text: sentence))
    }
    guard !pcm.isEmpty else { throw SiriTTSError.noAudioProduced("worker") }
    return pcm
  }
}

enum SiriWorkerMain {
  static func run(voiceID: String) -> Never {
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
        let pcm = try engine!.synthesize(request.text)
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

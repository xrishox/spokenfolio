import Darwin
import Foundation
import LocalTTSWorkerKit
import TTSKit

package final class GoldenGateWorkerEngine {
  private let runtime: any GoldenGateSynthesisRuntime
  private let voice: GoldenGateVoiceHandle
  private let runtimeIdentity = GoldenGateRuntimeIdentity.current

  package init(
    voiceID: String, runtime: any GoldenGateSynthesisRuntime
  ) throws {
    self.runtime = runtime
    guard let voice = try runtime.voices().first(where: { $0.descriptor.id == voiceID })
    else { throw GoldenGateTTSError.voiceNotFound(voiceID) }
    self.voice = voice
  }

  func synthesize(_ request: TTSSynthesisRequest) throws -> LocalTTSWorkerResult {
    guard request.selection.voice.backendID == GoldenGateTTSBackend.backendID,
      request.selection.voice.modelID == GoldenGateTTSBackend.modelID,
      request.selection.voice.voiceID == voice.descriptor.id
    else { throw TTSBackendError.voiceNotFound(request.selection.voice) }
    let pace = request.selection.controls.pace?.rawValue ?? TTSPreset.neutral.rawValue
    let expressivity =
      request.selection.controls.expressivity?.rawValue ?? TTSPreset.neutral.rawValue
    let result = try runtime.synthesize(
      text: request.text, voice: voice, pace: pace, expressivity: expressivity)
    let provenance = try result.instrumentation.provenance(
      runtime: runtimeIdentity, voiceRevision: voice.descriptor.revision)
    return LocalTTSWorkerResult(audio: result.audio, provenance: provenance)
  }
}

package enum GoldenGateWorkerMain {
  package static func run(voiceID: String) -> Never {
    let input = FileHandle.standardInput
    let output = FileHandle.standardOutput
    var engine: GoldenGateWorkerEngine?

    while true {
      let request: LocalTTSWorkerRequest
      do {
        guard let next = try LocalTTSWorkerFraming.readRequest(from: input) else {
          _exit(EXIT_SUCCESS)
        }
        request = next
      } catch {
        _exit(EX_PROTOCOL)
      }

      if engine == nil {
        do {
          engine = try GoldenGateWorkerEngine(
            voiceID: voiceID, runtime: GoldenGatePrivateTTSRuntime())
        } catch {
          try? LocalTTSWorkerFraming.writeResponse(
            requestID: request.id, errorCode: "engine_unavailable", to: output)
          _exit(EX_UNAVAILABLE)
        }
      }

      do {
        guard let engine else { throw GoldenGateTTSError.noAudioProduced }
        let result = try engine.synthesize(request.request)
        try LocalTTSWorkerFraming.writeResponse(
          requestID: request.id,
          audio: result.audio,
          timings: result.timings,
          provenance: result.provenance,
          to: output)
      } catch {
        FileHandle.standardError.write(
          Data("golden-gate-worker: synthesis failed: \(error)\n".utf8))
        try? LocalTTSWorkerFraming.writeResponse(
          requestID: request.id, errorCode: "synthesis_failed", to: output)
      }
    }
  }
}

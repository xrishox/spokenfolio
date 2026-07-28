import AudiobookKit
import TTSKit

/// Backend-neutral bridge from the shared audiobook pipeline to one resolved
/// local TTS selection. Every unit remains one utterance so paragraph prosody
/// and the existing bounded parallel/source-order pipeline are unchanged.
struct SessionNarrationSynthesizer: NarrationSynthesizing {
  let session: any TTSSession
  let selection: TTSVoiceSelection
  let expectedProvenance: TTSRuntimeProvenance

  func synthesize(text: String) async throws -> PCM16Audio {
    let result = try await session.synthesize(
      request: TTSSynthesisRequest(
        text: text, selection: selection, utteranceMode: .singleUtterance))
    try validate(result)
    return try PCMNormalizer.normalize(result.audio)
  }

  func synthesizeDetailed(
    text: String
  ) async throws -> (audio: PCM16Audio, timings: [SpokenWordTiming]?) {
    let result = try await session.synthesize(
      request: TTSSynthesisRequest(
        text: text, selection: selection, utteranceMode: .singleUtterance,
        timingMode: .word))
    try validate(result)
    return (try PCMNormalizer.normalize(result.audio), result.timings)
  }

  private func validate(_ result: TTSSynthesisResult) throws {
    guard result.provenance == expectedProvenance else {
      throw TTSBackendError.inconsistentRuntimeProvenance
    }
  }
}

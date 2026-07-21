import AudiobookKit
import TTSKit

struct SiriNarrationSynthesizer: NarrationSynthesizing {
  let session: any TTSSession
  let voice: VoiceKey

  func synthesize(text: String) async throws -> PCM16Audio {
    try PCMNormalizer.normalize(try await session.synthesize(text: text, voice: voice))
  }

  func synthesizeDetailed(
    text: String
  ) async throws -> (audio: PCM16Audio, timings: [SpokenWordTiming]?) {
    let result = try await session.synthesizeDetailed(text: text, voice: voice)
    // Normalization is an exact passthrough for the Siri format (48 kHz
    // mono), so seconds-based timings remain valid.
    return (try PCMNormalizer.normalize(result.audio), result.timings)
  }
}

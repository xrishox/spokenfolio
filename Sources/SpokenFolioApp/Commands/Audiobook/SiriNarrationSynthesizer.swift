import AudiobookKit
import TTSKit

struct SiriNarrationSynthesizer: NarrationSynthesizing {
  let session: any TTSSession
  let voice: VoiceKey

  func synthesize(text: String) async throws -> PCM16Audio {
    try PCMNormalizer.normalize(try await session.synthesize(text: text, voice: voice))
  }
}

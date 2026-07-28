import Foundation

package enum GoldenGateTTSError: Error, LocalizedError, Sendable {
  case frameworkUnavailable(String)
  case privateABIChanged(String)
  case voiceNotFound(String)
  case catalogUnavailable(String)
  case unsupportedAudioFormat(String)
  case invalidInstrumentation(String)
  case synthesisFailed(String)
  case noAudioProduced

  package var errorDescription: String? {
    switch self {
    case .frameworkUnavailable(let detail):
      "SiriTTSService is unavailable: \(detail)"
    case .privateABIChanged(let detail):
      "The Golden Gate Siri TTS interface changed: \(detail)"
    case .voiceNotFound(let id):
      "Expressive Siri voice '\(id)' is unavailable."
    case .catalogUnavailable(let detail):
      "Expressive Siri voices could not be enumerated: \(detail)"
    case .unsupportedAudioFormat(let detail):
      "The expressive Siri engine returned unsupported audio: \(detail)"
    case .invalidInstrumentation(let detail):
      "Expressive Siri synthesis could not prove the requested model: \(detail)"
    case .synthesisFailed(let detail):
      "Expressive Siri synthesis failed: \(detail)"
    case .noAudioProduced:
      "Expressive Siri synthesis produced no audio."
    }
  }
}

import Foundation

enum SiriTTSError: Error, Sendable {
  case frameworkUnavailable(String)
  case privateABIChanged(String)
  case noCompatibleVoices
  case invalidConfiguration(String)
  case voiceNotFound(String)
  case engineInitializationFailed(String, String)
  case enginePreheatFailed(String, String)
  case unsupportedAudioFormat(String, String)
  case synthesisFailed(String, String)
  case noAudioProduced(String)
  case synthesisQueueFull(Int)
}

package enum ServiceError: Error, Sendable {
  case invalidInput(String, code: String)
  case voiceNotFound(String)
  case queueFull(Int)
  case rateLimited
  case permissionRequired
  case engineUnavailable
  case workerCrashed
  case timeout
  case synthesisFailed

  package var code: String {
    switch self {
    case .invalidInput(_, let code): code
    case .voiceNotFound: "voice_not_found"
    case .queueFull: "queue_full"
    case .rateLimited: "rate_limited"
    case .permissionRequired: "siri_permission_required"
    case .engineUnavailable: "engine_unavailable"
    case .workerCrashed: "worker_crashed"
    case .timeout: "synthesis_timeout"
    case .synthesisFailed: "synthesis_failed"
    }
  }

  package var message: String {
    switch self {
    case .invalidInput(let message, _): message
    case .voiceNotFound(let voice): "Voice '\(voice)' is not installed or usable."
    case .queueFull(let capacity): "Siri synthesis queue is full (\(capacity) waiting requests)."
    case .rateLimited: "Too many speech requests from this client."
    case .permissionRequired: "Full Disk Access is required to read Apple's installed Siri models."
    case .engineUnavailable: "The installed Siri private TTS engine is unavailable."
    case .workerCrashed: "A Siri synthesis worker exited unexpectedly."
    case .timeout: "Siri synthesis exceeded the configured deadline."
    case .synthesisFailed: "The Siri engine could not synthesize this input."
    }
  }
}

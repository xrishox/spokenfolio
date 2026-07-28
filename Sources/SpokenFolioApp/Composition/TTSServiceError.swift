import Foundation

/// Backend-neutral failures presented by the application and HTTP API. Private
/// backend targets emit their own errors or `TTSBackendError`; this is the one
/// translation boundary into user-facing status, codes, and messages.
enum ServiceError: Error, Sendable {
  case invalidInput(String, code: String)
  case voiceNotFound(String)
  case queueFull(Int)
  case rateLimited
  case permissionRequired
  case engineUnavailable
  case workerCrashed
  case timeout
  case synthesisFailed

  var code: String {
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

  var message: String {
    switch self {
    case .invalidInput(let message, _): message
    case .voiceNotFound(let voice): "Voice '\(voice)' is not installed or usable."
    case .queueFull(let capacity):
      "The speech synthesis queue is full (\(capacity) waiting requests)."
    case .rateLimited: "Too many speech requests from this client."
    case .permissionRequired:
      "Full Disk Access is required to read Apple's installed Siri models."
    case .engineUnavailable: "The selected local speech engine is unavailable."
    case .workerCrashed: "A speech synthesis worker exited unexpectedly."
    case .timeout: "Speech synthesis exceeded the configured deadline."
    case .synthesisFailed: "The selected speech engine could not synthesize this input."
    }
  }
}

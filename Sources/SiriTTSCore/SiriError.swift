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

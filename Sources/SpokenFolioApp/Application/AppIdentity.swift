import Foundation

enum AppIdentity {
  static let displayName = "SpokenFolio"
  static let executableName = "spokenfolio"
  static let bundleIdentifier = "com.xrishox.spokenfolio"
  static let keychainService = "com.xrishox.spokenfolio.storyteller"
  static let windowAutosaveName = "SpokenFolioMainWindow"

  static let legacyDisplayName = "Siri TTS Server"
  static let legacyExecutableName = "siri-tts-server"
  static let legacyBundleIdentifier = "com.xrishox.macos-tts-server"
  static let legacyKeychainService = "com.xrishox.macos-tts-server.storyteller"
  static let legacyWindowAutosaveName = "SiriTTSStudioWindow"

  static var applicationSupportDirectory: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(
        "Library/Application Support/\(bundleIdentifier)", isDirectory: true)
  }

  static var legacyApplicationSupportDirectory: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(
        "Library/Application Support/\(legacyBundleIdentifier)", isDirectory: true)
  }
}

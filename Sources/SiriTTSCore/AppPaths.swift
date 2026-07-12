import Foundation

/// Filesystem locations shared by the server and the audiobook pipeline.
package enum AppPaths {
  package static var applicationSupportDirectory: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(
        "Library/Application Support/com.xrishox.macos-tts-server", isDirectory: true)
  }
}

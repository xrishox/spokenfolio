import Foundation
import TTSKit

package enum SiriPermissionPreflight {
  package static var modelDirectory: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Group Containers/group.com.apple.SiriTTS/BNNSModels")
  }

  /// Siri's private engine reads shared BNNS models outside the app's own
  /// container. Probe an actual byte before spawning workers so a missing
  /// Full Disk Access grant becomes an actionable state instead of a child
  /// crash/retry loop.
  package static func verifyModelAccess(
    at directory: URL = modelDirectory,
    fileManager: FileManager = .default
  ) throws {
    guard fileManager.fileExists(atPath: directory.path) else { return }
    do {
      _ = try fileManager.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
      var enumerationError: Error?
      let enumerator = fileManager.enumerator(
        at: directory,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
      ) { _, error in
        enumerationError = error
        return false
      }
      var foundModel = false
      while let file = enumerator?.nextObject() as? URL {
        guard file.pathExtension == "bin" else { continue }
        foundModel = true
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        guard let byte = try handle.read(upToCount: 1), !byte.isEmpty else {
          throw TTSBackendError.unavailable
        }
        return
      }
      if enumerationError != nil { throw TTSBackendError.permissionRequired }
      if !foundModel { throw TTSBackendError.unavailable }
    } catch let error as TTSBackendError {
      throw error
    } catch {
      throw TTSBackendError.permissionRequired
    }
  }
}

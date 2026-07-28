import Darwin
import Foundation

/// App-support home for synthesis-timeline sidecars, keyed by the SHA-256 of
/// the finished audiobook they describe. Managed jobs adopt the sidecar the
/// synthesizer wrote beside the M4B into this store so the user's books
/// folder holds only product files; the standalone CLI keeps the
/// beside-the-audiobook layout and never consults the store.
package struct SynthesisTimelineStore: Sendable {
  package let root: URL

  package init(root: URL) {
    self.root = root
  }

  package func url(forAudiobookSHA256 sha256: String) -> URL {
    root.appendingPathComponent("\(sha256).json")
  }

  package func exists(forAudiobookSHA256 sha256: String) -> Bool {
    FileManager.default.fileExists(atPath: url(forAudiobookSHA256: sha256).path)
  }

  /// Removes the stored sidecar for a deleted audiobook. Tolerates an absent
  /// entry (a CLI-authored M4B keeps its sidecar beside the file and never
  /// adopts into the store, so there may be nothing here).
  package func delete(forAudiobookSHA256 sha256: String) {
    try? FileManager.default.removeItem(at: url(forAudiobookSHA256: sha256))
  }

  /// Moves a sidecar into the store, replacing any previous entry for the
  /// same audiobook digest atomically.
  package func adopt(sidecarAt source: URL, forAudiobookSHA256 sha256: String) throws {
    guard sha256.count == 64, sha256 == sha256.lowercased(),
      sha256.allSatisfy(\.isHexDigit)
    else {
      throw BookJobError.invalidRequest(
        "a synthesis timeline can only be stored under a SHA-256 digest")
    }
    guard FileManager.default.fileExists(atPath: source.path) else {
      throw BookJobError.io("synthesis timeline sidecar does not exist: \(source.path)")
    }
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o755])
    let destination = url(forAudiobookSHA256: sha256)
    if rename(source.path, destination.path) == 0 {
      return
    }
    guard errno == EXDEV else {
      throw BookJobError.io(
        "could not adopt synthesis timeline sidecar: \(String(cString: strerror(errno)))")
    }
    // The sidecar sits on a different volume (external books folder): stage a
    // copy inside the store, publish it atomically, then remove the original.
    let temporary = root.appendingPathComponent(".\(UUID().uuidString).tmp")
    do {
      try FileManager.default.copyItem(at: source, to: temporary)
      guard rename(temporary.path, destination.path) == 0 else {
        throw BookJobError.io(
          "could not adopt synthesis timeline sidecar: \(String(cString: strerror(errno)))")
      }
    } catch {
      try? FileManager.default.removeItem(at: temporary)
      throw error
    }
    try FileManager.default.removeItem(at: source)
  }
}

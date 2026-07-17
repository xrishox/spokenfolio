import CryptoKit
import Darwin
import Foundation

package enum DurableFileCommit {
  static func synchronizeFile(at url: URL) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.synchronize()
  }

  static func synchronizeDirectory(containing url: URL) throws {
    let directory = url.deletingLastPathComponent().path
    let descriptor = Darwin.open(directory, O_RDONLY | O_CLOEXEC)
    guard descriptor >= 0 else {
      throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: directory])
    }
    defer { Darwin.close(descriptor) }
    guard fsync(descriptor) == 0 else {
      throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: directory])
    }
  }

  package static func replace(
    _ finalURL: URL, with temporaryURL: URL, expectedExistingSHA256: String? = nil
  ) throws {
    if let expectedExistingSHA256 {
      guard FileManager.default.fileExists(atPath: finalURL.path),
        try sha256(finalURL) == expectedExistingSHA256
      else { throw AudiobookAudioError.outputChanged(finalURL) }
    }
    if FileManager.default.fileExists(atPath: finalURL.path) {
      _ = try FileManager.default.replaceItemAt(finalURL, withItemAt: temporaryURL)
    } else {
      try FileManager.default.moveItem(at: temporaryURL, to: finalURL)
    }
    try synchronizeDirectory(containing: finalURL)
  }

  /// Publishes a verified staged file while retaining the stage until its
  /// caller has durably recorded the new product. This closes the crash window
  /// between a replacement rename and job-state persistence.
  package static func replaceKeepingSource(
    _ finalURL: URL, with stagedURL: URL, expectedExistingSHA256: String
  ) throws {
    let publish = finalURL.deletingLastPathComponent().appendingPathComponent(
      ".\(finalURL.lastPathComponent).\(UUID().uuidString).replacement")
    defer { try? FileManager.default.removeItem(at: publish) }
    try FileManager.default.copyItem(at: stagedURL, to: publish)
    try synchronizeFile(at: publish)
    try replace(finalURL, with: publish, expectedExistingSHA256: expectedExistingSHA256)
  }

  private static func sha256(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hash = SHA256()
    while let data = try handle.read(upToCount: 4 << 20), !data.isEmpty {
      hash.update(data: data)
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }

  /// Atomically publish a same-directory temporary file without replacing an
  /// output that appeared while a long-running job was being synthesized.
  static func publishWithoutClobber(_ temporaryURL: URL, to finalURL: URL) throws {
    if Darwin.renameatx_np(
      AT_FDCWD, temporaryURL.path, AT_FDCWD, finalURL.path, UInt32(RENAME_EXCL)) == 0
    {
      try synchronizeDirectory(containing: finalURL)
      return
    }
    if errno == EEXIST { throw CocoaError(.fileWriteFileExists) }
    guard errno == ENOTSUP || errno == EINVAL else {
      throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: finalURL.path])
    }

    // Compatibility fallback for filesystems that do not implement
    // renameatx_np(RENAME_EXCL). It preserves the same no-clobber guarantee
    // when same-filesystem hard links are supported.
    guard Darwin.link(temporaryURL.path, finalURL.path) == 0 else {
      if errno == EEXIST { throw CocoaError(.fileWriteFileExists) }
      throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: finalURL.path])
    }
    guard Darwin.unlink(temporaryURL.path) == 0 else {
      try? FileManager.default.removeItem(at: finalURL)
      throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temporaryURL.path])
    }
    try synchronizeDirectory(containing: finalURL)
  }
}

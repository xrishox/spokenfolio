import Darwin
import Foundation

enum DurableFileCommit {
  static func synchronizeFile(at url: URL) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.synchronize()
  }

  static func synchronizeDirectory(containing url: URL) throws {
    let directory = url.deletingLastPathComponent().path
    let descriptor = Darwin.open(directory, O_RDONLY)
    guard descriptor >= 0 else {
      throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: directory])
    }
    defer { Darwin.close(descriptor) }
    guard fsync(descriptor) == 0 else {
      throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: directory])
    }
  }

  static func replace(_ finalURL: URL, with temporaryURL: URL) throws {
    if FileManager.default.fileExists(atPath: finalURL.path) {
      _ = try FileManager.default.replaceItemAt(finalURL, withItemAt: temporaryURL)
    } else {
      try FileManager.default.moveItem(at: temporaryURL, to: finalURL)
    }
    try synchronizeDirectory(containing: finalURL)
  }

  /// Atomically publish a same-directory temporary file without replacing an
  /// output that appeared while a long-running job was being synthesized.
  static func publishWithoutClobber(_ temporaryURL: URL, to finalURL: URL) throws {
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

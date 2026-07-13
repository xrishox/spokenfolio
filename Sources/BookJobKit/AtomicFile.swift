import Darwin
import Foundation

enum AtomicBookFile {
  static func write(_ data: Data, to destination: URL, permissions: mode_t = 0o600) throws {
    let directory = destination.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let temporary = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
    do {
      try data.write(to: temporary, options: [])
      _ = chmod(temporary.path, permissions)
      let descriptor = Darwin.open(temporary.path, O_RDONLY)
      guard descriptor >= 0 else { throw BookJobError.io("could not open temporary state") }
      defer { Darwin.close(descriptor) }
      guard fsync(descriptor) == 0 else {
        throw BookJobError.io("could not synchronize temporary state")
      }
      if rename(temporary.path, destination.path) != 0 {
        throw BookJobError.io(String(cString: strerror(errno)))
      }
      let directoryDescriptor = Darwin.open(directory.path, O_RDONLY)
      if directoryDescriptor >= 0 {
        _ = fsync(directoryDescriptor)
        Darwin.close(directoryDescriptor)
      }
    } catch {
      try? FileManager.default.removeItem(at: temporary)
      throw error
    }
  }
}

package final class BookFileLock: @unchecked Sendable {
  private let descriptor: Int32

  package init(url: URL, nonblocking: Bool = false) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    descriptor = Darwin.open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { throw BookJobError.io("could not open lock") }
    let operation = LOCK_EX | (nonblocking ? LOCK_NB : 0)
    guard flock(descriptor, operation) == 0 else {
      Darwin.close(descriptor)
      throw BookJobError.io("lock is already held")
    }
  }

  deinit {
    _ = flock(descriptor, LOCK_UN)
    Darwin.close(descriptor)
  }
}

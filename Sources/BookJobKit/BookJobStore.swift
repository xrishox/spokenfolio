import CryptoKit
import Darwin
import Foundation

package final class BookJobLease: @unchecked Sendable {
  private let descriptor: Int32
  package let directory: URL

  package init(directory: URL) throws {
    self.directory = directory
    let path = directory.appendingPathComponent("run.lock").path
    descriptor = Darwin.open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { throw BookJobError.io("could not open run lock") }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      Darwin.close(descriptor)
      throw BookJobError.alreadyRunning(directory)
    }
  }

  deinit {
    _ = flock(descriptor, LOCK_UN)
    Darwin.close(descriptor)
  }
}

package actor BookJobStore {
  package let root: URL
  private let encoder: JSONEncoder
  private let decoder = JSONDecoder()

  package init(root: URL) {
    self.root = root
    encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    // Foundation's native numeric Date representation preserves the request
    // exactly; ISO8601's default formatter drops sub-second precision.
    encoder.dateEncodingStrategy = .deferredToDate
    decoder.dateDecodingStrategy = .deferredToDate
  }

  package func create(_ request: BookJobRequest) throws -> BookJobState {
    try request.validate()
    try ensureRoot()
    let directory = jobDirectory(request.id)
    guard !FileManager.default.fileExists(atPath: directory.path) else {
      throw BookJobError.invalidRequest("job \(request.id) already exists")
    }
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    let requestData = try encoder.encode(request)
    let state = BookJobState(jobID: request.id, requestSHA256: Self.sha256(requestData))
    do {
      try AtomicBookFile.write(requestData, to: directory.appendingPathComponent("request.json"))
      try AtomicBookFile.write(
        encoder.encode(state), to: directory.appendingPathComponent("state.json"))
      try AtomicBookFile.write(
        encoder.encode(BookJobControl()), to: directory.appendingPathComponent("control.json"))
      return state
    } catch {
      try? FileManager.default.removeItem(at: directory)
      throw error
    }
  }

  package func loadRequest(_ id: UUID) throws -> BookJobRequest {
    let data = try read("request.json", id: id)
    let request = try decode(BookJobRequest.self, from: data)
    try request.validate()
    return request
  }

  package func loadState(_ id: UUID) throws -> BookJobState {
    let state = try decode(BookJobState.self, from: read("state.json", id: id))
    guard state.schemaVersion == BookJobState.schemaVersion, state.jobID == id else {
      throw BookJobError.corruptState("schema or job ID mismatch")
    }
    let expectedStages = Set(BookJobStage.allCases)
    let actualStages = state.stages.map(\.stage)
    guard Set(actualStages) == expectedStages, actualStages.count == expectedStages.count,
      state.stages.filter({ $0.status == .running }).count <= 1,
      state.stages.allSatisfy({ stage in
        guard let fraction = stage.fraction else { return true }
        return fraction.isFinite && (0...1).contains(fraction)
      }),
      Set(state.products.map(\.kind)).count == state.products.count,
      state.products.allSatisfy({
        $0.size > 0 && $0.sha256.count == 64 && $0.sha256 == $0.sha256.lowercased()
          && $0.sha256.allSatisfy(\.isHexDigit)
      })
    else { throw BookJobError.corruptState("invalid stage or product state") }
    return state
  }

  package func loadJob(_ id: UUID) throws -> (BookJobRequest, BookJobState) {
    let requestData = try read("request.json", id: id)
    let request = try decode(BookJobRequest.self, from: requestData)
    try request.validate()
    let state = try loadState(id)
    guard state.requestSHA256 == Self.sha256(requestData) else {
      throw BookJobError.corruptState("request checksum mismatch")
    }
    return (request, state)
  }

  package func loadControl(_ id: UUID) throws -> BookJobControl {
    try decode(BookJobControl.self, from: read("control.json", id: id))
  }

  package func saveState(_ state: BookJobState) throws {
    guard state.schemaVersion == BookJobState.schemaVersion else {
      throw BookJobError.unsupportedSchema(state.schemaVersion)
    }
    try AtomicBookFile.write(
      encoder.encode(state), to: jobDirectory(state.jobID).appendingPathComponent("state.json"))
  }

  package func requestCancellation(_ id: UUID, attempt: UInt64) throws {
    var control = (try? loadControl(id)) ?? BookJobControl()
    control.cancelRequestedForAttempt = attempt
    control.interruption = .init(attempt: attempt, kind: .pause)
    try saveControl(control, id: id)
  }

  package func saveControl(_ control: BookJobControl, id: UUID) throws {
    try AtomicBookFile.write(
      encoder.encode(control), to: jobDirectory(id).appendingPathComponent("control.json"))
  }

  package func enqueue(_ id: UUID, sequence: UInt64) throws {
    var control = try loadControl(id)
    control.queueSequence = sequence
    control.queueDisposition = .ready
    control.interruption = nil
    control.cancelRequestedForAttempt = nil
    try saveControl(control, id: id)
  }

  package func requestInterruption(
    _ id: UUID, attempt: UInt64, kind: BookJobControl.InterruptionKind
  ) throws {
    var control = try loadControl(id)
    control.cancelRequestedForAttempt = attempt
    control.interruption = .init(attempt: attempt, kind: kind)
    control.queueDisposition = .held
    try saveControl(control, id: id)
  }

  package func setQueueDisposition(
    _ disposition: BookJobControl.QueueDisposition, id: UUID
  ) throws {
    var control = try loadControl(id)
    control.queueDisposition = disposition
    if disposition == .ready {
      control.cancelRequestedForAttempt = nil
      control.interruption = nil
    }
    try saveControl(control, id: id)
  }

  package func list() throws -> [(BookJobRequest, BookJobState)] {
    try ensureRoot()
    return try FileManager.default.contentsOfDirectory(
      at: root, includingPropertiesForKeys: [.isDirectoryKey]
    )
    .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    .compactMap { UUID(uuidString: $0.lastPathComponent) }
    .map { try loadJob($0) }
    .sorted { $0.0.createdAt > $1.0.createdAt }
  }

  package struct ScanIssue: Sendable, Equatable {
    package var directory: String
    package var message: String
    package init(directory: String, message: String) {
      self.directory = directory
      self.message = message
    }
  }

  package struct ScanResult: Sendable {
    package var jobs: [(BookJobRequest, BookJobState)]
    package var issues: [ScanIssue]
  }

  package func scan() throws -> ScanResult {
    try ensureRoot()
    var jobs: [(BookJobRequest, BookJobState)] = []
    var issues: [ScanIssue] = []
    for directory in try FileManager.default.contentsOfDirectory(
      at: root, includingPropertiesForKeys: [.isDirectoryKey])
    where (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
      guard let id = UUID(uuidString: directory.lastPathComponent) else { continue }
      do { jobs.append(try loadJob(id)) } catch {
        issues.append(.init(directory: directory.lastPathComponent, message: error.localizedDescription))
      }
    }
    jobs.sort { $0.0.createdAt > $1.0.createdAt }
    return ScanResult(jobs: jobs, issues: issues)
  }

  package func acquireLease(_ id: UUID) throws -> BookJobLease {
    try BookJobLease(directory: jobDirectory(id))
  }

  package func appendEvent(_ event: BookJobEvent, maximumBytes: Int = 1 << 20) throws {
    let url = jobDirectory(event.jobID).appendingPathComponent("events.ndjson")
    var line = try JSONEncoder().encode(event)
    line.append(UInt8(ascii: "\n"))
    if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
      size + line.count > maximumBytes
    {
      let rotated = url.appendingPathExtension("old")
      try? FileManager.default.removeItem(at: rotated)
      try? FileManager.default.moveItem(at: url, to: rotated)
    }
    if !FileManager.default.fileExists(atPath: url.path) {
      FileManager.default.createFile(
        atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
    }
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: line)
  }

  package func jobDirectory(_ id: UUID) -> URL {
    root.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
  }

  private func ensureRoot() throws {
    do {
      try FileManager.default.createDirectory(
        at: root, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    } catch { throw BookJobError.io(error.localizedDescription) }
  }

  private func read(_ name: String, id: UUID) throws -> Data {
    do { return try Data(contentsOf: jobDirectory(id).appendingPathComponent(name)) } catch {
      throw BookJobError.io(error.localizedDescription)
    }
  }

  private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    do { return try decoder.decode(type, from: data) } catch {
      throw BookJobError.corruptState(error.localizedDescription)
    }
  }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

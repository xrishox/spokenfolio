import Foundation

package struct StudioSettings: Codable, Sendable, Equatable {
  package static let schemaVersion = 1
  package var schemaVersion: Int
  /// Nil means the conventional `~/Books/SpokenFolio` default.
  package var processedDirectory: String?

  package init(processedDirectory: String? = nil) {
    schemaVersion = Self.schemaVersion
    self.processedDirectory = processedDirectory
  }

  package func resolvedProcessedDirectory(home: URL) -> URL {
    processedDirectory.map { URL(fileURLWithPath: $0).standardizedFileURL }
      ?? home.appendingPathComponent("Books/SpokenFolio", isDirectory: true)
  }

  package func validate() throws {
    guard schemaVersion == Self.schemaVersion else {
      throw BookJobError.unsupportedSchema(schemaVersion)
    }
    if let processedDirectory {
      guard (processedDirectory as NSString).isAbsolutePath else {
        throw BookJobError.invalidRequest("Processed directory must be absolute")
      }
    }
  }
}

package actor StudioSettingsStore {
  package let url: URL
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  package init(url: URL) {
    self.url = url
    encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    decoder = JSONDecoder()
  }

  package func load() throws -> StudioSettings {
    guard FileManager.default.fileExists(atPath: url.path) else { return StudioSettings() }
    do {
      let settings = try decoder.decode(
        StudioSettings.self, from: try boundedData(url, maximumBytes: 1 << 20))
      try settings.validate()
      return settings
    } catch let error as BookJobError { throw error } catch {
      throw BookJobError.corruptState(error.localizedDescription)
    }
  }

  package func save(_ settings: StudioSettings) throws {
    try settings.validate()
    try AtomicBookFile.write(encoder.encode(settings), to: url)
  }

  private func boundedData(_ url: URL, maximumBytes: Int) throws -> Data {
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values.isRegularFile == true, let size = values.fileSize, size <= maximumBytes else {
      throw BookJobError.corruptState("settings file is not bounded")
    }
    return try Data(contentsOf: url, options: [.mappedIfSafe])
  }
}

package struct BookSchedulerState: Codable, Sendable, Equatable {
  package static let schemaVersion = 1
  package var schemaVersion: Int
  package var isSuspended: Bool
  package var nextQueueSequence: UInt64
  package var updatedAt: Date

  package init(isSuspended: Bool = true, nextQueueSequence: UInt64 = 0) {
    schemaVersion = Self.schemaVersion
    self.isSuspended = isSuspended
    self.nextQueueSequence = nextQueueSequence
    updatedAt = Date()
  }
}

package actor BookSchedulerStore {
  package let url: URL
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  package init(url: URL) {
    self.url = url
    encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .deferredToDate
    decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .deferredToDate
  }

  package func load() throws -> BookSchedulerState {
    guard FileManager.default.fileExists(atPath: url.path) else { return BookSchedulerState() }
    do {
      let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
      guard values.isRegularFile == true, let size = values.fileSize, size <= 1 << 20 else {
        throw BookJobError.corruptState("scheduler state is not bounded")
      }
      let state = try decoder.decode(
        BookSchedulerState.self, from: Data(contentsOf: url, options: [.mappedIfSafe]))
      guard state.schemaVersion == BookSchedulerState.schemaVersion else {
        throw BookJobError.unsupportedSchema(state.schemaVersion)
      }
      return state
    } catch let error as BookJobError { throw error } catch {
      throw BookJobError.corruptState(error.localizedDescription)
    }
  }

  package func save(_ state: BookSchedulerState) throws {
    guard state.schemaVersion == BookSchedulerState.schemaVersion else {
      throw BookJobError.unsupportedSchema(state.schemaVersion)
    }
    try AtomicBookFile.write(encoder.encode(state), to: url)
  }

  package func reserve(count: Int) throws -> [UInt64] {
    guard count >= 0 else { throw BookJobError.invalidRequest("negative queue reservation") }
    var state = try load()
    let start = state.nextQueueSequence
    let (end, overflow) = start.addingReportingOverflow(UInt64(count))
    guard !overflow else { throw BookJobError.corruptState("queue sequence exhausted") }
    state.nextQueueSequence = end
    state.updatedAt = Date()
    try save(state)
    return (0..<count).map { start + UInt64($0) }
  }

  package func setSuspended(_ suspended: Bool) throws -> BookSchedulerState {
    var state = try load()
    state.isSuspended = suspended
    state.updatedAt = Date()
    try save(state)
    return state
  }
}

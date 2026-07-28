import Foundation

/// The production settings the user last queued with, remembered so every
/// form opens where they left off instead of resetting to configuration
/// defaults. Purely a starting point: each value is re-validated against the
/// live catalog and current limits before it is offered again, and a
/// remembered voice that is no longer installed simply falls back.
package struct RememberedProductionSettings: Codable, Sendable, Equatable {
  package var backendID: String
  package var modelID: String
  package var voiceID: String
  package var pacePreset: Int?
  package var expressivityPreset: Int?
  package var bitrateKbps: Int
  package var workers: Int
  package var announceTitles: Bool
  package var paragraphPauseSeconds: Double
  package var chapterPauseSeconds: Double
  package var createReadAloud: Bool
  package var readAloudBitrateKbps: Int
  package var readAloudASREngineID: String
  package var readAloudASRModelID: String?
  package var storytellerConnectionID: UUID?
  package var sendSourceEPUB: Bool
  package var sendM4B: Bool
  package var sendReadAloud: Bool
  package var updatedAt: Date

  package init(
    backendID: String, modelID: String, voiceID: String,
    pacePreset: Int? = nil, expressivityPreset: Int? = nil,
    bitrateKbps: Int, workers: Int, announceTitles: Bool,
    paragraphPauseSeconds: Double, chapterPauseSeconds: Double,
    createReadAloud: Bool = false, readAloudBitrateKbps: Int,
    readAloudASREngineID: String, readAloudASRModelID: String? = nil,
    storytellerConnectionID: UUID? = nil, sendSourceEPUB: Bool = false,
    sendM4B: Bool = false, sendReadAloud: Bool = false, updatedAt: Date = Date()
  ) {
    self.backendID = backendID
    self.modelID = modelID
    self.voiceID = voiceID
    self.pacePreset = pacePreset
    self.expressivityPreset = expressivityPreset
    self.bitrateKbps = bitrateKbps
    self.workers = workers
    self.announceTitles = announceTitles
    self.paragraphPauseSeconds = paragraphPauseSeconds
    self.chapterPauseSeconds = chapterPauseSeconds
    self.createReadAloud = createReadAloud
    self.readAloudBitrateKbps = readAloudBitrateKbps
    self.readAloudASREngineID = readAloudASREngineID
    self.readAloudASRModelID = readAloudASRModelID
    self.storytellerConnectionID = storytellerConnectionID
    self.sendSourceEPUB = sendSourceEPUB
    self.sendM4B = sendM4B
    self.sendReadAloud = sendReadAloud
    self.updatedAt = updatedAt
  }
}

package struct StudioSettings: Codable, Sendable, Equatable {
  package static let schemaVersion = 1
  package var schemaVersion: Int
  /// Nil means the conventional `~/Books/SpokenFolio` default.
  package var processedDirectory: String?
  /// Absent until the first book is queued.
  package var lastProduction: RememberedProductionSettings?

  package init(
    processedDirectory: String? = nil,
    lastProduction: RememberedProductionSettings? = nil
  ) {
    schemaVersion = Self.schemaVersion
    self.processedDirectory = processedDirectory
    self.lastProduction = lastProduction
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

  /// Remembers the settings a book was just queued with, leaving every other
  /// setting untouched. Failing to remember must never fail the queueing that
  /// already succeeded, so callers may ignore the error.
  package func rememberProduction(_ value: RememberedProductionSettings) throws {
    var settings = try load()
    settings.lastProduction = value
    try save(settings)
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

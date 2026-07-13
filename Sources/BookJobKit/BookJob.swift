import Foundation
import PublicationKit

package enum BookJobStage: String, Codable, Sendable, CaseIterable {
  case preparation
  case m4bSynthesis
  case m4bAssembly
  case m4bVerification
  case readAloudAudioProcessing
  case readAloudTranscription
  case readAloudMarkup
  case readAloudAlignment
  case readAloudVerification
  case storytellerPreflight
  case storytellerUpload
  case storytellerReconciliation
}

package enum BookJobStageStatus: String, Codable, Sendable {
  case pending, running, succeeded, failed, paused, needsAttention, skipped
}

package enum BookJobLifecycle: String, Codable, Sendable {
  case queued, running, paused, needsAttention, completed, cancelled
}

package enum BookProductKind: String, Codable, Sendable {
  case sourceEPUB, m4b, readAloudEPUB
}

package struct BookJobRequest: Codable, Sendable, Equatable {
  package static let schemaVersion = 2

  package enum Operation: String, Codable, Sendable {
    case production
    case readAloud
    case storytellerDelivery
  }

  package struct Source: Codable, Sendable, Equatable {
    package var path: String
    package var sha256: String
    package var format: String
    package var importerVersion: Int
    package var identifiers: [String]
    package var typedIdentifiers: [PublicationIdentifier]
    package init(
      path: String, sha256: String, format: String, importerVersion: Int,
      identifiers: [String] = [], typedIdentifiers: [PublicationIdentifier] = []
    ) {
      self.path = path
      self.sha256 = sha256
      self.format = format
      self.importerVersion = importerVersion
      self.identifiers = identifiers
      self.typedIdentifiers = typedIdentifiers
    }

    private enum CodingKeys: String, CodingKey {
      case path, sha256, format, importerVersion, identifiers, typedIdentifiers
    }

    package init(from decoder: Decoder) throws {
      let values = try decoder.container(keyedBy: CodingKeys.self)
      path = try values.decode(String.self, forKey: .path)
      sha256 = try values.decode(String.self, forKey: .sha256)
      format = try values.decode(String.self, forKey: .format)
      importerVersion = try values.decode(Int.self, forKey: .importerVersion)
      identifiers = try values.decodeIfPresent([String].self, forKey: .identifiers) ?? []
      typedIdentifiers =
        try values.decodeIfPresent([PublicationIdentifier].self, forKey: .typedIdentifiers) ?? []
    }
  }

  package struct AlignmentAudio: Codable, Sendable, Equatable {
    package enum Mode: String, Codable, Sendable { case existingM4B, temporaryResynthesis }
    package var mode: Mode
    package var path: String?
    package var size: UInt64?
    package var sha256: String?

    package init(
      mode: Mode, path: String? = nil, size: UInt64? = nil, sha256: String? = nil
    ) {
      self.mode = mode
      self.path = path
      self.size = size
      self.sha256 = sha256
    }
  }

  package struct Narration: Codable, Sendable, Equatable {
    package var backendID: String
    package var modelID: String
    package var modelRevision: String?
    package var voiceID: String
    package var voiceRevision: String?
    package var includedSectionIDs: [String]
    package var excludedSectionIDs: [String]
    package var bitrateKbps: Int
    package var workers: Int
    package var paragraphPauseSeconds: Double
    package var chapterPauseSeconds: Double
    package var announceTitles: Bool

    package init(
      backendID: String, modelID: String, modelRevision: String? = nil,
      voiceID: String, voiceRevision: String? = nil,
      includedSectionIDs: [String], excludedSectionIDs: [String] = [],
      bitrateKbps: Int, workers: Int, paragraphPauseSeconds: Double,
      chapterPauseSeconds: Double, announceTitles: Bool
    ) {
      self.backendID = backendID
      self.modelID = modelID
      self.modelRevision = modelRevision
      self.voiceID = voiceID
      self.voiceRevision = voiceRevision
      self.includedSectionIDs = includedSectionIDs
      self.excludedSectionIDs = excludedSectionIDs
      self.bitrateKbps = bitrateKbps
      self.workers = workers
      self.paragraphPauseSeconds = paragraphPauseSeconds
      self.chapterPauseSeconds = chapterPauseSeconds
      self.announceTitles = announceTitles
    }
  }

  package struct ReadAloud: Codable, Sendable, Equatable {
    package var outputPath: String
    package var opusBitrateKbps: Int
    package var language: String?
    package var backendID: String
    package init(
      outputPath: String, opusBitrateKbps: Int = 32, language: String? = nil,
      backendID: String = "stalign"
    ) {
      self.outputPath = outputPath
      self.opusBitrateKbps = opusBitrateKbps
      self.language = language
      self.backendID = backendID
    }
  }

  package struct StorytellerDelivery: Codable, Sendable, Equatable {
    package var connectionID: UUID
    package var remoteBookID: UUID
    package var products: Set<BookProductKind>
    package init(connectionID: UUID, remoteBookID: UUID, products: Set<BookProductKind>) {
      self.connectionID = connectionID
      self.remoteBookID = remoteBookID
      self.products = products
    }
  }

  package var schemaVersion: Int
  /// Optional so requests written before delivery-only jobs were introduced
  /// continue to decode as ordinary production jobs under schema version 1.
  package var operation: Operation?
  package var id: UUID
  package var catalogID: UUID?
  package var batchID: UUID?
  package var batchOrdinal: Int?
  package var batchCount: Int?
  package var managedByStudio: Bool?
  package var createdAt: Date
  package var title: String
  package var author: String?
  package var source: Source
  package var narration: Narration
  package var m4bOutputPath: String
  package var m4bWorkDirectory: String?
  package var allowOverwrite: Bool
  package var readAloud: ReadAloud?
  package var alignmentAudio: AlignmentAudio?
  package var storyteller: StorytellerDelivery?

  package init(
    id: UUID = UUID(), catalogID: UUID? = nil, batchID: UUID? = nil,
    batchOrdinal: Int? = nil, batchCount: Int? = nil, managedByStudio: Bool = false,
    createdAt: Date = Date(), title: String, author: String?,
    source: Source, narration: Narration, m4bOutputPath: String,
    m4bWorkDirectory: String? = nil,
    allowOverwrite: Bool = false, readAloud: ReadAloud? = nil,
    alignmentAudio: AlignmentAudio? = nil,
    storyteller: StorytellerDelivery? = nil, operation: Operation = .production
  ) {
    schemaVersion = Self.schemaVersion
    self.operation = operation
    self.id = id
    self.catalogID = catalogID
    self.batchID = batchID
    self.batchOrdinal = batchOrdinal
    self.batchCount = batchCount
    self.managedByStudio = managedByStudio
    self.createdAt = createdAt
    self.title = title
    self.author = author
    self.source = source
    self.narration = narration
    self.m4bOutputPath = m4bOutputPath
    self.m4bWorkDirectory = m4bWorkDirectory
    self.allowOverwrite = allowOverwrite
    self.readAloud = readAloud
    self.alignmentAudio = alignmentAudio
    self.storyteller = storyteller
  }

  package var resolvedOperation: Operation { operation ?? .production }

  package func validate() throws {
    guard [1, Self.schemaVersion].contains(schemaVersion) else {
      throw BookJobError.unsupportedSchema(schemaVersion)
    }
    guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !source.path.isEmpty, source.sha256.count == 64,
      source.sha256.allSatisfy({ $0.isHexDigit }), source.sha256 == source.sha256.lowercased(),
      source.format == "epub",
      !narration.voiceID.isEmpty, !m4bOutputPath.isEmpty
    else {
      throw BookJobError.invalidRequest("source and M4B destination are required")
    }
    guard narration.paragraphPauseSeconds.isFinite,
      narration.chapterPauseSeconds.isFinite,
      (0...3).contains(narration.paragraphPauseSeconds),
      (0...5).contains(narration.chapterPauseSeconds)
    else { throw BookJobError.invalidRequest("pause settings are out of range") }
    guard [32, 64, 128, 256].contains(narration.bitrateKbps) else {
      throw BookJobError.invalidRequest("AAC bitrate must be 32, 64, 128, or 256 kbps")
    }
    guard (1...16).contains(narration.workers) else {
      throw BookJobError.invalidRequest("worker count must be between 1 and 16")
    }
    guard narration.backendID == "siri", narration.modelID == "siri-private" else {
      throw BookJobError.invalidRequest("unsupported narration backend or model")
    }
    let sourceURL = URL(fileURLWithPath: source.path).standardizedFileURL
    let m4bURL = URL(fileURLWithPath: m4bOutputPath).standardizedFileURL
    guard (source.path as NSString).isAbsolutePath,
      (m4bOutputPath as NSString).isAbsolutePath,
      sourceURL != m4bURL, sourceURL.pathExtension.lowercased() == "epub",
      m4bURL.pathExtension.lowercased() == "m4b"
    else { throw BookJobError.invalidRequest("source and M4B paths or extensions are invalid") }
    if let work = m4bWorkDirectory, !work.isEmpty {
      let workURL = URL(fileURLWithPath: work).standardizedFileURL
      guard (work as NSString).isAbsolutePath, workURL != sourceURL, workURL != m4bURL else {
        throw BookJobError.invalidRequest("M4B work directory overlaps an input or output")
      }
    }
    guard Set(narration.includedSectionIDs).count == narration.includedSectionIDs.count,
      Set(narration.excludedSectionIDs).count == narration.excludedSectionIDs.count,
      Set(narration.includedSectionIDs).isDisjoint(with: narration.excludedSectionIDs),
      !(narration.includedSectionIDs + narration.excludedSectionIDs).contains(where: { $0.isEmpty })
    else { throw BookJobError.invalidRequest("section overrides are invalid") }
    if let readAloud {
      let readAloudURL = URL(fileURLWithPath: readAloud.outputPath).standardizedFileURL
      guard !readAloud.outputPath.isEmpty, readAloudURL != m4bURL,
        readAloudURL != sourceURL, readAloudURL.pathExtension.lowercased() == "epub",
        readAloud.backendID == "stalign"
      else {
        throw BookJobError.invalidRequest("ReadAloud destination is invalid")
      }
      guard [16, 32, 64, 96].contains(readAloud.opusBitrateKbps) else {
        throw BookJobError.invalidRequest("ReadAloud Opus bitrate must be 16, 32, 64, or 96 kbps")
      }
      guard narration.announceTitles == false else {
        throw BookJobError.invalidRequest(
          "synthetic chapter announcements must be disabled for ReadAloud jobs")
      }
    }
    if resolvedOperation == .readAloud {
      guard schemaVersion >= 2, catalogID != nil, readAloud != nil, let alignmentAudio else {
        throw BookJobError.invalidRequest(
          "a ReadAloud-only job requires a catalog and alignment audio plan")
      }
      if alignmentAudio.mode == .existingM4B {
        guard let path = alignmentAudio.path, (path as NSString).isAbsolutePath,
          let size = alignmentAudio.size, size > 0,
          let sha = alignmentAudio.sha256, sha.count == 64,
          sha == sha.lowercased(), sha.allSatisfy(\.isHexDigit)
        else { throw BookJobError.invalidRequest("existing alignment audio is invalid") }
      }
    }
    let batchValues = [batchID != nil, batchOrdinal != nil, batchCount != nil]
    guard batchValues.allSatisfy({ $0 }) || batchValues.allSatisfy({ !$0 }) else {
      throw BookJobError.invalidRequest("batch identity must be complete")
    }
    if let batchOrdinal, let batchCount {
      guard batchCount > 0, batchOrdinal >= 0, batchOrdinal < batchCount else {
        throw BookJobError.invalidRequest("batch position is invalid")
      }
    }
    if let storyteller {
      guard !storyteller.products.isEmpty else {
        throw BookJobError.invalidRequest("Storyteller delivery has no selected products")
      }
      if storyteller.products.contains(.readAloudEPUB), readAloud == nil {
        throw BookJobError.invalidRequest("ReadAloud delivery requires ReadAloud creation")
      }
    }
    if resolvedOperation == .storytellerDelivery, storyteller == nil {
      throw BookJobError.invalidRequest(
        "a Storyteller delivery-only job requires a connection and selected products")
    }
  }
}

package struct BookJobProduct: Codable, Sendable, Equatable {
  package var kind: BookProductKind
  package var path: String
  package var size: UInt64
  package var sha256: String
  package var verifiedAt: Date
  package init(kind: BookProductKind, path: String, size: UInt64, sha256: String, verifiedAt: Date)
  {
    self.kind = kind
    self.path = path
    self.size = size
    self.sha256 = sha256
    self.verifiedAt = verifiedAt
  }
}

package struct BookJobStageState: Codable, Sendable, Equatable {
  package var stage: BookJobStage
  package var status: BookJobStageStatus
  package var fraction: Double?
  package var message: String?
  package var startedAt: Date?
  package var finishedAt: Date?

  package init(stage: BookJobStage, status: BookJobStageStatus = .pending) {
    self.stage = stage
    self.status = status
  }
}

package struct BookJobRunnerIdentity: Codable, Sendable, Equatable {
  package var pid: Int32
  package var launchToken: UUID
  package var executablePath: String
  package var heartbeatAt: Date
  package init(pid: Int32, launchToken: UUID, executablePath: String, heartbeatAt: Date) {
    self.pid = pid
    self.launchToken = launchToken
    self.executablePath = executablePath
    self.heartbeatAt = heartbeatAt
  }
}

package struct BookJobAudiobookProgress: Codable, Sendable, Equatable {
  package var totalChapters: Int
  package var totalCharacters: Int
  package var reusedChapters: Int
  package var chapterCharacters: [Int]
  package var currentChapterIndex: Int?
  package var currentChapterTitle: String?
  package var completedUnits: Int
  package var totalUnits: Int

  package init(
    totalChapters: Int, totalCharacters: Int, reusedChapters: Int,
    chapterCharacters: [Int]
  ) {
    self.totalChapters = totalChapters
    self.totalCharacters = totalCharacters
    self.reusedChapters = reusedChapters
    self.chapterCharacters = chapterCharacters
    completedUnits = 0
    totalUnits = 0
  }
}

package struct BookJobState: Codable, Sendable, Equatable {
  package static let schemaVersion = 1
  package var schemaVersion: Int
  package var jobID: UUID
  package var requestSHA256: String
  package var revision: UInt64
  package var attempt: UInt64
  package var lifecycle: BookJobLifecycle
  package var stages: [BookJobStageState]
  package var products: [BookJobProduct]
  package var warnings: [String]
  package var lastError: String?
  package var runner: BookJobRunnerIdentity?
  package var audiobookProgress: BookJobAudiobookProgress?
  package var storytellerBookID: UUID?
  package var storytellerBaselineBookIDs: [UUID]?
  package var updatedAt: Date

  package init(jobID: UUID, requestSHA256: String) {
    schemaVersion = Self.schemaVersion
    self.jobID = jobID
    self.requestSHA256 = requestSHA256
    revision = 0
    attempt = 0
    lifecycle = .queued
    stages = BookJobStage.allCases.map { BookJobStageState(stage: $0) }
    products = []
    warnings = []
    audiobookProgress = nil
    storytellerBookID = nil
    storytellerBaselineBookIDs = nil
    updatedAt = Date()
  }

  package mutating func transition(to next: BookJobLifecycle) throws {
    let legal: Set<BookJobLifecycle>
    switch lifecycle {
    case .queued: legal = [.running, .cancelled]
    case .running: legal = [.paused, .needsAttention, .completed, .cancelled]
    case .paused: legal = [.running, .cancelled]
    case .needsAttention: legal = [.running, .cancelled]
    case .completed, .cancelled: legal = []
    }
    guard legal.contains(next) else {
      throw BookJobError.illegalTransition(from: lifecycle, to: next)
    }
    lifecycle = next
    revision += 1
    updatedAt = Date()
  }

  package mutating func updateStage(
    _ stage: BookJobStage, status: BookJobStageStatus,
    fraction: Double? = nil, message: String? = nil
  ) throws {
    guard let index = stages.firstIndex(where: { $0.stage == stage }) else {
      throw BookJobError.invalidRequest("unknown job stage")
    }
    if status == .running,
      stages.contains(where: { $0.status == .running && $0.stage != stage })
    {
      throw BookJobError.invalidRequest("only one job stage may run at a time")
    }
    let now = Date()
    stages[index].status = status
    stages[index].fraction = fraction.map { min(1, max(0, $0)) }
    stages[index].message = message
    if status == .running, stages[index].startedAt == nil { stages[index].startedAt = now }
    if [.succeeded, .failed, .paused, .needsAttention, .skipped].contains(status) {
      stages[index].finishedAt = now
    }
    revision += 1
    updatedAt = now
  }

  package mutating func prepareForRetry() {
    for index in stages.indices
    where [.running, .paused, .failed, .needsAttention].contains(stages[index].status) {
      stages[index].status = .pending
      stages[index].fraction = nil
      stages[index].message = nil
      stages[index].finishedAt = nil
    }
    lastError = nil
    revision += 1
    updatedAt = Date()
  }

  package mutating func touch() {
    revision += 1
    updatedAt = Date()
  }
}

package struct BookJobControl: Codable, Sendable, Equatable {
  package enum QueueDisposition: String, Codable, Sendable { case ready, held }
  package enum InterruptionKind: String, Codable, Sendable { case pause, cancel }
  package struct Interruption: Codable, Sendable, Equatable {
    package var attempt: UInt64
    package var kind: InterruptionKind
    package init(attempt: UInt64, kind: InterruptionKind) {
      self.attempt = attempt
      self.kind = kind
    }
  }

  package var cancelRequestedForAttempt: UInt64?
  package var queueSequence: UInt64?
  package var queueDisposition: QueueDisposition?
  package var interruption: Interruption?

  package init(
    cancelRequestedForAttempt: UInt64? = nil, queueSequence: UInt64? = nil,
    queueDisposition: QueueDisposition? = nil, interruption: Interruption? = nil
  ) {
    self.cancelRequestedForAttempt = cancelRequestedForAttempt
    self.queueSequence = queueSequence
    self.queueDisposition = queueDisposition
    self.interruption = interruption
  }
}

package struct BookJobEvent: Codable, Sendable, Equatable {
  package static let schemaVersion = 1
  package var schemaVersion = Self.schemaVersion
  package var jobID: UUID
  package var attempt: UInt64
  package var sequence: UInt64
  package var timestamp: Date
  package var type: String
  package var stage: BookJobStage?
  package var fraction: Double?
  package var message: String?
}

package enum BookJobError: Error, LocalizedError, Equatable {
  case unsupportedSchema(Int)
  case invalidRequest(String)
  case illegalTransition(from: BookJobLifecycle, to: BookJobLifecycle)
  case corruptState(String)
  case alreadyRunning(URL)
  case io(String)

  package var errorDescription: String? {
    switch self {
    case .unsupportedSchema(let version): "Unsupported job schema version \(version)."
    case .invalidRequest(let message): "Invalid book job: \(message)."
    case .illegalTransition(let from, let to):
      "Illegal job transition \(from.rawValue) → \(to.rawValue)."
    case .corruptState(let message): "Corrupt book job state: \(message)."
    case .alreadyRunning(let url): "Book job is already running at '\(url.path)'."
    case .io(let message): "Could not persist book job: \(message)."
    }
  }
}

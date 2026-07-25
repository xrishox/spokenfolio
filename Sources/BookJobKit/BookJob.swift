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
  /// Human-narrated files downloaded from Storyteller into the Book
  /// Library. They are never produced locally and never sent back up; they
  /// exist so the library can hold EVERYTHING for a book.
  case humanAudiobook, humanReadAloudEPUB
}

package struct BookJobRequest: Codable, Sendable, Equatable {
  package static let schemaVersion = 4

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
    /// Runtime identity captured by the authoritative synthesis runner. It is
    /// intentionally separate from the requested model and voice revisions:
    /// a queued job may run after macOS or an installed voice has changed.
    package struct Runtime: Codable, Sendable, Equatable {
      package var macOSVersion: String
      package var macOSBuild: String
      package var frameworkIdentifier: String
      package var frameworkVersion: String
      package var frameworkSDKVersion: String?
      package var frameworkSDKBuild: String?

      package init(
        macOSVersion: String, macOSBuild: String, frameworkIdentifier: String,
        frameworkVersion: String, frameworkSDKVersion: String? = nil,
        frameworkSDKBuild: String? = nil
      ) {
        self.macOSVersion = macOSVersion
        self.macOSBuild = macOSBuild
        self.frameworkIdentifier = frameworkIdentifier
        self.frameworkVersion = frameworkVersion
        self.frameworkSDKVersion = frameworkSDKVersion
        self.frameworkSDKBuild = frameworkSDKBuild
      }
    }

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
    package var runtime: Runtime?

    package init(
      backendID: String, modelID: String, modelRevision: String? = nil,
      voiceID: String, voiceRevision: String? = nil,
      includedSectionIDs: [String], excludedSectionIDs: [String] = [],
      bitrateKbps: Int, workers: Int, paragraphPauseSeconds: Double,
      chapterPauseSeconds: Double, announceTitles: Bool, runtime: Runtime? = nil
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
      self.runtime = runtime
    }
  }

  package struct ProductReplacement: Codable, Sendable, Equatable {
    package var kind: BookProductKind
    package var expectedSHA256: String

    package init(kind: BookProductKind, expectedSHA256: String) {
      self.kind = kind
      self.expectedSHA256 = expectedSHA256
    }
  }

  package struct ReadAloud: Codable, Sendable, Equatable {
    package var outputPath: String
    package var opusBitrateKbps: Int
    package var language: String?
    package var backendID: String
    /// Persistence-neutral ASR identifiers. Requests written before schema 3
    /// omit both fields and retain the historical Whisper/tiny behavior.
    package var asrEngineID: String?
    package var asrModelID: String?
    package init(
      outputPath: String, opusBitrateKbps: Int = 32, language: String? = nil,
      backendID: String = "stalign", asrEngineID: String = "synthesis",
      asrModelID: String? = nil
    ) {
      self.outputPath = outputPath
      self.opusBitrateKbps = opusBitrateKbps
      self.language = language
      self.backendID = backendID
      self.asrEngineID = asrEngineID
      self.asrModelID = asrModelID
    }

    package var resolvedASREngineID: String { asrEngineID ?? "whisper" }
    package var resolvedASRModelID: String? {
      if let asrModelID { return asrModelID }
      return asrEngineID == nil ? "tiny" : nil
    }
  }

  package struct StorytellerDelivery: Codable, Sendable, Equatable {
    /// One remote asset the user explicitly confirmed destroying when a
    /// whole-book replacement was approved. Preflight re-verifies each of
    /// these against the live remote book and aborts on any drift — the
    /// delete never happens against state the user did not see.
    package struct ExpectedRemoteAsset: Codable, Sendable, Equatable {
      package var format: String
      package var assetID: UUID
      package var size: UInt64?
      package var sha256: String?

      package init(format: String, assetID: UUID, size: UInt64?, sha256: String?) {
        self.format = format
        self.assetID = assetID
        self.size = size
        self.sha256 = sha256
      }
    }

    package var connectionID: UUID
    package var remoteBookID: UUID
    package var products: Set<BookProductKind>
    /// Remote formats ("ebook"/"audiobook"/"readaloud") the user explicitly
    /// acknowledged replacing. Each is replaced individually through
    /// Storyteller's own replace-asset API after its confirmation snapshot
    /// re-verifies; nothing else on the book is touched and no book is
    /// ever deleted.
    package var replaceFormats: [String]?
    package var expectedRemoteAssets: [ExpectedRemoteAsset]?
    /// Narration provenance the user declared for the delivered ReadAloud
    /// ("human" or "spokenFolioTTS"); recorded as an assertion after
    /// successful reconciliation.
    package var assertNarration: String?

    package init(
      connectionID: UUID, remoteBookID: UUID, products: Set<BookProductKind>,
      replaceFormats: [String]? = nil,
      expectedRemoteAssets: [ExpectedRemoteAsset]? = nil,
      assertNarration: String? = nil
    ) {
      self.connectionID = connectionID
      self.remoteBookID = remoteBookID
      self.products = products
      self.replaceFormats = replaceFormats
      self.expectedRemoteAssets = expectedRemoteAssets
      self.assertNarration = assertNarration
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
  /// Optional for schema 1-3 compatibility. A non-empty value is explicit
  /// authorization to atomically supersede the named catalog products.
  package var productReplacements: [ProductReplacement]?

  package init(
    id: UUID = UUID(), catalogID: UUID? = nil, batchID: UUID? = nil,
    batchOrdinal: Int? = nil, batchCount: Int? = nil, managedByStudio: Bool = false,
    createdAt: Date = Date(), title: String, author: String?,
    source: Source, narration: Narration, m4bOutputPath: String,
    m4bWorkDirectory: String? = nil,
    allowOverwrite: Bool = false, readAloud: ReadAloud? = nil,
    alignmentAudio: AlignmentAudio? = nil,
    storyteller: StorytellerDelivery? = nil, operation: Operation = .production,
    productReplacements: [ProductReplacement] = []
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
    self.productReplacements = productReplacements
  }

  package var resolvedOperation: Operation { operation ?? .production }
  package var resolvedProductReplacements: [ProductReplacement] { productReplacements ?? [] }

  package func validate() throws {
    guard (1...Self.schemaVersion).contains(schemaVersion) else {
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
      (0...10).contains(narration.paragraphPauseSeconds),
      (0...10).contains(narration.chapterPauseSeconds)
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
      guard (readAloud.outputPath as NSString).isAbsolutePath,
        !readAloud.outputPath.isEmpty, readAloudURL != m4bURL,
        readAloudURL != sourceURL, readAloudURL.pathExtension.lowercased() == "epub",
        readAloud.backendID == "stalign"
      else {
        throw BookJobError.invalidRequest("ReadAloud destination is invalid")
      }
      guard [16, 32, 64, 96].contains(readAloud.opusBitrateKbps) else {
        throw BookJobError.invalidRequest("ReadAloud Opus bitrate must be 16, 32, 64, or 96 kbps")
      }
      if let language = readAloud.language {
        guard !language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          language.utf8.count <= 128
        else { throw BookJobError.invalidRequest("ReadAloud language is invalid") }
      }
      let engine = readAloud.resolvedASREngineID
      guard ["synthesis", "apple", "whisper"].contains(engine) else {
        throw BookJobError.invalidRequest("unsupported ReadAloud ASR engine")
      }
      if engine != "whisper" {
        guard readAloud.asrModelID == nil else {
          throw BookJobError.invalidRequest("only Whisper ReadAloud ASR takes a model")
        }
      } else {
        guard let model = readAloud.resolvedASRModelID,
          !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          model.utf8.count <= 128
        else { throw BookJobError.invalidRequest("Whisper ReadAloud ASR requires a model") }
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
      guard
        storyteller.products.isDisjoint(with: [.humanAudiobook, .humanReadAloudEPUB])
      else {
        throw BookJobError.invalidRequest(
          "human-narrated downloads are never sent back to Storyteller")
      }
      if storyteller.products.contains(.readAloudEPUB), readAloud == nil {
        throw BookJobError.invalidRequest("ReadAloud delivery requires ReadAloud creation")
      }
      if let replaceFormats = storyteller.replaceFormats, !replaceFormats.isEmpty {
        let valid = Set(["ebook", "audiobook", "readaloud"])
        guard replaceFormats.allSatisfy({ valid.contains($0) }) else {
          throw BookJobError.invalidRequest("unknown remote replacement format")
        }
        let confirmed = Set((storyteller.expectedRemoteAssets ?? []).map(\.format))
        guard replaceFormats.allSatisfy({ confirmed.contains($0) }) else {
          throw BookJobError.invalidRequest(
            "every remote replacement requires its confirmed asset snapshot")
        }
        guard schemaVersion >= 4 else {
          throw BookJobError.invalidRequest("remote replacement requires schema version 4")
        }
      }
      if let narration = storyteller.assertNarration {
        guard ["human", "spokenFolioTTS"].contains(narration) else {
          throw BookJobError.invalidRequest("unsupported delivered-narration assertion")
        }
      }
    }
    if resolvedOperation == .storytellerDelivery, storyteller == nil {
      throw BookJobError.invalidRequest(
        "a Storyteller delivery-only job requires a connection and selected products")
    }
    let replacements = resolvedProductReplacements
    guard Set(replacements.map(\.kind)).count == replacements.count,
      replacements.allSatisfy({ replacement in
        [.m4b, .readAloudEPUB].contains(replacement.kind)
          && replacement.expectedSHA256.count == 64
          && replacement.expectedSHA256 == replacement.expectedSHA256.lowercased()
          && replacement.expectedSHA256.allSatisfy(\.isHexDigit)
      })
    else { throw BookJobError.invalidRequest("product replacement plan is invalid") }
    if !replacements.isEmpty {
      let planMatchesOperation: Bool
      switch resolvedOperation {
      case .production:
        planMatchesOperation = replacements.contains(where: { $0.kind == .m4b })
      case .readAloud:
        // Recreating a ReadAloud in place (e.g. with different ASR settings):
        // exactly the ReadAloud product is replaced, digest-guarded.
        planMatchesOperation = replacements.allSatisfy { $0.kind == .readAloudEPUB }
      case .storytellerDelivery:
        planMatchesOperation = false
      }
      guard schemaVersion >= 4, catalogID != nil, allowOverwrite, planMatchesOperation else {
        throw BookJobError.invalidRequest(
          "product replacement requires an overwrite-enabled production or ReadAloud job whose replacement plan matches its operation")
      }
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
  package var actualNarration: BookJobRequest.Narration?
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
    actualNarration = nil
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
    try bumpRevision()
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
    try bumpRevision()
    updatedAt = now
  }

  package mutating func prepareForRetry() throws {
    for index in stages.indices
    where [.running, .paused, .failed, .needsAttention].contains(stages[index].status) {
      stages[index].status = .pending
      stages[index].fraction = nil
      stages[index].message = nil
      stages[index].startedAt = nil
      stages[index].finishedAt = nil
    }
    lastError = nil
    try bumpRevision()
    updatedAt = Date()
  }

  package mutating func touch() throws {
    try bumpRevision()
    updatedAt = Date()
  }

  private mutating func bumpRevision() throws {
    let (next, overflow) = revision.addingReportingOverflow(1)
    guard !overflow else { throw BookJobError.corruptState("job revision exhausted") }
    revision = next
  }
}

package struct BookJobControl: Codable, Sendable, Equatable {
  package enum QueueDisposition: String, Codable, Sendable {
    case ready
    case retryReady = "retry-ready"
    case held
  }
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

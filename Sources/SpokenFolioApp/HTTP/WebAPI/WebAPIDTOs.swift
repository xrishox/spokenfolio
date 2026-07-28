import AudiobookKit
import BookJobKit
import Foundation
import ReadAloudKit
import Vapor

/// Stable wire types for `/api`. Domain values that are already Codable are
/// embedded as-is; presentation fields ride alongside so the frontend never
/// re-implements status vocabulary.

struct ServerStatusDTO: Content {
  let health: String
  let endpoint: String
  let host: String
  let port: Int
  let voiceCount: Int
  let defaultVoice: String?
  let studioHosted: Bool
  let schedulerState: String
  let fullDiskAccessInstructions: String?
}

struct QueueStatusDTO: Content {
  let isSuspended: Bool
  let activeJobID: UUID?
  /// The delivery-only child running alongside the heavyweight job, if any.
  let deliveryActiveJobID: UUID?
  let queuedCount: Int
  let runningCount: Int
  let error: String?
  let scanIssueCount: Int
  let sequence: UInt64
}

struct JobSummaryDTO: Content {
  let id: UUID
  let title: String
  let author: String?
  let kindTitle: String
  let statusTitle: String
  let lifecycle: String
  let queueDisposition: String
  let queuePosition: Int?
  let progress: Double?
  let createdAt: Date
  let updatedAt: Date
}

struct VoicesDTO: Content {
  struct Voice: Content {
    let id: String
    let name: String
    let language: String
  }
  let voices: [Voice]
  let defaultVoiceID: String?
}

struct SettingsDTO: Content {
  struct Capabilities: Content {
    let launchAtLogin: Bool
    let revealInFinder: Bool
    let restartServer: Bool
  }
  let processedDirectory: String
  /// Whether `studio-settings.json` exists yet — false drives first-run
  /// onboarding in the clients.
  let configured: Bool
  /// Non-nil while a library relocation is running or has finished during
  /// this process lifetime.
  let relocation: RelocationStatusDTO?
  let capabilities: Capabilities

  /// The one settings snapshot every handler returns, so GET and PUT can
  /// never drift apart.
  static func current(services: StudioServices) async throws -> SettingsDTO {
    let store = StudioSettingsStore(url: AppPaths.studioSettingsURL)
    let directory = (try await store.load()).resolvedProcessedDirectory(
      home: FileManager.default.homeDirectoryForCurrentUser)
    let snapshot = await services.relocation.currentSnapshot
    return SettingsDTO(
      processedDirectory: directory.path,
      configured: FileManager.default.fileExists(atPath: AppPaths.studioSettingsURL.path),
      relocation: snapshot.sequence == 0 ? nil : RelocationStatusDTO(snapshot),
      capabilities: .init(
        launchAtLogin: false, revealInFinder: false, restartServer: false))
  }
}

struct RelocationStatusDTO: Content {
  struct Failure: Content {
    let title: String
    let reason: String
  }
  let active: Bool
  let total: Int
  let completed: Int
  let currentTitle: String?
  let destination: String?
  let failures: [Failure]
  let sequence: UInt64

  init(_ snapshot: LibraryRelocationService.Snapshot) {
    active = snapshot.isBusy
    total = snapshot.total
    completed = snapshot.completed
    currentTitle = snapshot.currentTitle
    destination = snapshot.destination
    failures = snapshot.failures.map { Failure(title: $0.title, reason: $0.reason) }
    sequence = snapshot.sequence
  }
}

struct JobStageDTO: Content {
  let stage: String
  let title: String
  let status: String
  let statusTitle: String
  let fraction: Double?
  let message: String?
}

struct JobProductDTO: Content {
  let kind: String
  let path: String
  let sizeBytes: UInt64
  let sha256: String
  let verifiedAt: Date
}

struct JobDetailDTO: Content {
  let summary: JobSummaryDTO
  let stages: [JobStageDTO]
  let lastError: String?
  let attempt: UInt64
  let warnings: [String]
  let products: [JobProductDTO]
  let settings: JobSettingsDTO
  let runtime: JobRuntimeDTO?
  let audiobookProgress: JobAudiobookProgressDTO?
  let batch: JobBatchDTO?
  let catalogID: UUID?
}

struct JobSettingsDTO: Content {
  let backendID: String
  let modelID: String
  let voiceID: String
  let pacePreset: Int?
  let expressivityPreset: Int?
  let bitrateKbps: Int
  let workers: Int
  let paragraphPauseSeconds: Double
  let chapterPauseSeconds: Double
  let announceTitles: Bool
  let readAloudBitrateKbps: Int?
  let readAloudEngine: String?
  let readAloudModel: String?
  let storytellerConnectionName: String?
  let storytellerProducts: [String]
}

struct JobRuntimeDTO: Content {
  let backendID: String
  let modelID: String
  let voiceID: String
  let voiceRevision: String?
  let macOSVersion: String?
  let macOSBuild: String?
  let frameworkVersion: String?
}

struct JobAudiobookProgressDTO: Content {
  let totalChapters: Int
  let totalCharacters: Int
  let reusedChapters: Int
  let currentChapterIndex: Int?
  let currentChapterTitle: String?
}

struct JobBatchDTO: Content {
  let ordinal: Int
  let count: Int
}

struct JobControlRequestDTO: Content {
  let ids: [UUID]
}

struct JobControlResultDTO: Content {
  let failures: [String: String]
}

struct QueuePauseRequestDTO: Content {
  let interruptActive: Bool?
}

struct CancelWaitingRequestDTO: Content {
  let includeActive: Bool?
}

struct WebDraftDTO: Content {
  struct Section: Content {
    let id: Int
    let title: String
    let role: String
    let characterCount: Int
    let initiallyIncluded: Bool
    let included: Bool
  }
  let id: UUID
  let displayName: String
  let status: String
  let statusMessage: String?
  let title: String?
  let author: String?
  let language: String?
  let chapterCount: Int
  let sourceSize: UInt64
  let sourceSHA256: String?
  let hasCover: Bool
  let inLibrary: Bool
  let sections: [Section]
}

/// The wire projection of `ProductionDefaults`: the qualified default TTS
/// selection, audiobook and ReadAloud settings, where the worker count came
/// from, and the environment facts (Full Disk Access warning, Storyteller
/// connections) the web forms need. The catalog of models and voices is not
/// repeated here — clients read it from `GET /api/tts/catalog`.
struct ProductionDefaultsDTO: Content {
  typealias WorkerSource = ProductionDefaults.WorkerSource

  let publicModelID: String
  let backendID: String
  let modelID: String
  let voiceID: String
  let pacePreset: Int?
  let expressivityPreset: Int?
  let bitrateKbps: Int
  let workers: Int
  let workerSource: WorkerSource
  let workerWarning: String?
  let announceTitles: Bool
  let paragraphPauseSeconds: Double
  let chapterPauseSeconds: Double
  let readAloudBitrateKbps: Int
  let readAloudASREngineID: String
  let readAloudASRModelID: String?
  /// Remembered from the last queued book; a fresh install starts these off.
  let createReadAloud: Bool
  let storytellerConnectionID: UUID?
  let sendSourceEPUB: Bool
  let sendM4B: Bool
  let sendReadAloud: Bool
  let permissionWarning: String?
  let connections: [StorytellerConnectionDTO]

  init(defaults: ProductionDefaults, connections: [StorytellerConnection]) {
    publicModelID = defaults.publicModelID
    backendID = defaults.backendID
    modelID = defaults.modelID
    voiceID = defaults.voiceID
    pacePreset = defaults.pacePreset
    expressivityPreset = defaults.expressivityPreset
    bitrateKbps = defaults.bitrateKbps
    workers = defaults.workers
    workerSource = defaults.workerSource
    workerWarning = defaults.workerWarning
    announceTitles = defaults.announceTitles
    paragraphPauseSeconds = defaults.paragraphPauseSeconds
    chapterPauseSeconds = defaults.chapterPauseSeconds
    readAloudBitrateKbps = defaults.readAloudBitrateKbps
    readAloudASREngineID = defaults.readAloudASREngineID
    readAloudASRModelID = defaults.readAloudASRModelID
    createReadAloud = defaults.createReadAloud
    // A remembered connection that has since been removed must not be offered.
    storytellerConnectionID =
      connections.contains { $0.id == defaults.storytellerConnectionID }
      ? defaults.storytellerConnectionID : nil
    sendSourceEPUB = defaults.sendSourceEPUB
    sendM4B = defaults.sendM4B
    sendReadAloud = defaults.sendReadAloud
    permissionWarning = defaults.permissionWarning
    self.connections = connections.map {
      StorytellerConnectionDTO(id: $0.id, label: $0.displayName)
    }
  }
}

struct StorytellerConnectionDTO: Content {
  let id: UUID
  let label: String
}

struct DraftQueueRequestDTO: Content {
  struct Entry: Content {
    let draftID: UUID
    let backendID: String
    let modelID: String
    let voiceID: String
    let pacePreset: Int?
    let expressivityPreset: Int?
    let bitrateKbps: Int
    let workers: Int
    let announceTitles: Bool
    let paragraphPauseSeconds: Double
    let chapterPauseSeconds: Double
    let includedSections: [Int]
    let createReadAloud: Bool
    let reprocessAudiobook: Bool
    let readAloudBitrateKbps: Int
    let readAloudASREngineID: String
    let readAloudASRModelID: String?
    let storytellerConnectionID: UUID?
    let sendSourceEPUB: Bool
    let sendM4B: Bool
    let sendReadAloud: Bool
    let outputDirectory: String?
  }
  let drafts: [Entry]
}

struct DraftQueueResultDTO: Content {
  struct Outcome: Content {
    let draftID: UUID
    let status: String
    let message: String?
  }
  let outcomes: [Outcome]
}

struct LibraryRowDTO: Content {
  struct Slots: Content {
    let epub: String
    let ttsAudiobook: String
    let ttsReadAloud: String
    let humanAudiobook: String
    let humanReadAloud: String
  }
  /// What is KNOWN to be on the linked Storyteller book per slot:
  /// "verified" (receipt proves the server copy equals the current local
  /// file, re-validated against live metadata), "present" (a file is there
  /// and the slot attribution is certain), or null (absent or unknown —
  /// clients must display nothing).
  struct SlotPresence: Content {
    let epub: String?
    let ttsAudiobook: String?
    let ttsReadAloud: String?
    let humanAudiobook: String?
    let humanReadAloud: String?
  }
  struct RemoteAsset: Content {
    let state: String
    let sizeBytes: UInt64?
    let status: String?
    let stage: String?
    let stageProgress: Double?
  }
  struct LocalProduct: Content {
    let kind: String
    let path: String
    let sizeBytes: UInt64
  }
  struct Identifier: Content {
    let kind: String
    let value: String
  }
  let id: String
  let title: String
  let author: String?
  let level: Int
  let levelLabel: String
  let presence: String
  let narration: String
  let slots: Slots
  let storytellerSlots: SlotPresence
  /// Remote formats this book has that are not yet stored locally.
  let downloadableFormats: [String]
  let ttsProvenance: String?
  let localQualityVerdict: String?
  let remoteQualityVerdict: String?
  let updatedAt: Date
  let inLibrary: Bool
  let recordID: UUID?
  let localProducts: [LocalProduct]
  let identifiers: [Identifier]
  let remoteEPUB: RemoteAsset?
  let remoteAudiobook: RemoteAsset?
  let remoteReadAloud: RemoteAsset?
  let suggestedRemoteTitle: String?
  let suggestedRemoteAuthors: [String]
  let suggestedRemoteBookID: UUID?
  let localReadAloudProductID: UUID?
  let remoteBookID: UUID?
  let remoteReadAloudAssetID: UUID?
  let remoteReadAloudReady: Bool
  let canStartRemoteReadAloud: Bool
  let hasStorytellerLink: Bool
}

struct LibraryDTO: Content {
  typealias Connection = StorytellerConnectionDTO
  let rows: [LibraryRowDTO]
  let issues: [String]
  let editionGapCount: Int
  let snapshotStale: Bool
  let error: String?
  /// True when the refresh failed with a 401: the stored session is dead and
  /// the fix is reconnecting in Settings, not retrying.
  let authExpired: Bool?
  let connections: [Connection]
  /// True when the requested `?connection=` id no longer exists — the client
  /// should drop its remembered selection and re-run auto-select.
  let connectionMissing: Bool?

  static let empty = LibraryDTO(
    rows: [], issues: [], editionGapCount: 0, snapshotStale: false,
    error: nil, authExpired: nil, connections: [], connectionMissing: nil)
}

struct ProcessPlanDTO: Content {
  struct Book: Content {
    let id: String
    let title: String
    let author: String?
    let source: String
    let hasAudiobook: Bool
    let hasReadAloud: Bool
    let audiobookAlignsDirectly: Bool
  }
  struct Skipped: Content {
    let title: String
    let reason: String
  }
  /// Per-asset replacement manifest for one book: the sent formats whose
  /// remote slots are occupied with different content. Mirrors
  /// LibraryProcessPlanner.ReplacementImpact.
  struct Replacement: Content {
    struct Asset: Content {
      let format: String
      let humanNarration: Bool
      let size: UInt64?
    }
    let rowID: String
    let title: String
    let remoteNarration: String
    let losesHumanAudio: Bool
    let assets: [Asset]
  }
  let books: [Book]
  let skipped: [Skipped]
  /// The plan carries no TTS catalog of its own: clients read the models and
  /// voices once from `GET /api/tts/catalog` and re-plan only for the books
  /// and delivery toggles that actually changed.
  let defaults: ProductionDefaultsDTO
  /// Present only when the plan request carried delivery toggles.
  let replacements: [Replacement]?
}

struct ProcessQueueRequestDTO: Content {
  let rowIDs: [String]
  let createMissingAudiobooks: Bool
  let recreateExistingAudiobooks: Bool
  let createMissingReadAlouds: Bool
  let recreateExistingReadAlouds: Bool
  let sendToStoryteller: Bool
  let deliveryConnectionID: UUID?
  let sendEPUB: Bool
  let sendM4B: Bool
  let sendReadAloud: Bool
  let confirmedRemoteBookID: UUID?
  let backendID: String
  let modelID: String
  let voiceID: String
  let pacePreset: Int?
  let expressivityPreset: Int?
  let bitrateKbps: Int
  let workers: Int
  let announceTitles: Bool
  let paragraphPauseSeconds: Double
  let chapterPauseSeconds: Double
  let readAloudBitrateKbps: Int
  let readAloudASREngineID: String
  let readAloudASRModelID: String?
  /// Row IDs whose whole-book replacement the user acknowledged after seeing
  /// the loss manifest. Occupied-and-different books without an entry fail.
  let replaceAcknowledgedRowIDs: [String]?
  /// "human" | "spokenFolioTTS" — declared provenance of a sent ReadAloud.
  let assertNarration: String?
}

struct ProcessQueueResultDTO: Content {
  struct Failure: Content {
    let title: String
    let reason: String
  }
  let queued: Int
  let failures: [Failure]
}

struct LibraryDeletePlanRequestDTO: Content {
  let rowIDs: [String]
  /// BookProductKind raw values: sourceEPUB, m4b, readAloudEPUB,
  /// humanAudiobook, humanReadAloudEPUB.
  let slots: [String]
  /// "local" | "storyteller" | "both".
  let scope: String
}

/// Per-book deletion manifest: exactly what each selected slot + scope would
/// remove. `wholeBookLocal` means the source slot was chosen and the entire
/// local book (record + folder) goes; `losesHumanContent` drives the escalated
/// warning. Mirrors LibraryDeletePlanner.DeletionImpact.
struct LibraryDeletePlanDTO: Content {
  struct Book: Content {
    struct RemoteSlot: Content {
      let format: String
      let humanNarration: Bool
      let size: UInt64?
    }
    let rowID: String
    let title: String
    let wholeBookLocal: Bool
    let losesHumanContent: Bool
    /// BookProductKind raw values of local products to remove (empty for a
    /// whole-book delete, which supersedes them).
    let localSlots: [String]
    let remoteSlots: [RemoteSlot]
  }
  struct Skipped: Content {
    let rowID: String
    let title: String
    let reason: String
  }
  let books: [Book]
  let skipped: [Skipped]
}

struct LibraryDeleteRequestDTO: Content {
  let rowIDs: [String]
  let slots: [String]
  let scope: String
  /// Row IDs the user acknowledged after seeing the manifest. A whole-book
  /// delete or a delete that loses human content is refused without it.
  let acknowledgedRowIDs: [String]
}

struct LibraryDeleteResultDTO: Content {
  struct Book: Content {
    struct Failure: Content {
      let label: String
      let reason: String
    }
    let rowID: String
    let title: String
    /// Non-nil when the book was skipped for active work; nothing was touched.
    let blocked: String?
    let wholeBookDeleted: Bool
    let localDeleted: [String]
    let remoteDeleted: [String]
    let failures: [Failure]
  }
  let books: [Book]
  /// The library snapshot after the deletions, so the client re-renders.
  let library: LibraryDTO
}

struct ProcessReviewDTO: Content {
  struct Candidate: Content {
    let remoteBookID: UUID
    let title: String
    let authors: [String]
    let reason: String
  }
  let code: String
  let candidates: [Candidate]
}

struct MatchFindResultDTO: Content {
  struct Candidate: Content {
    let remoteBookID: UUID
    let title: String
    let authors: [String]
    let reason: String
  }
  let outcome: String
  let candidates: [Candidate]
}

struct MirrorStatusDTO: Content {
  struct Failure: Content {
    let title: String
    let reason: String
  }
  let isBusy: Bool
  let total: Int
  let completed: Int
  let currentTitle: String?
  let failures: [Failure]
  let sequence: UInt64
  /// The connection the mirror run belongs to, so the Library banner only
  /// renders for the connection it describes.
  let connectionID: UUID?
}

struct AsinSearchDTO: Content {
  struct Candidate: Content {
    let asin: String
    let title: String
    let authors: [String]
    let narrators: [String]
  }
  let candidates: [Candidate]
}

struct AsinResolveDTO: Content {
  let asin: String
  let found: Bool
  let title: String?
  let authors: [String]
  let narrators: [String]
}

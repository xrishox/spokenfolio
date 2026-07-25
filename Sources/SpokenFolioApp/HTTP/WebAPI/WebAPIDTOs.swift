import BookJobKit
import Foundation
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
  let voiceID: String
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

struct AudiobookVoicesDTO: Content {
  struct Voice: Content {
    let id: String
    let name: String
    let language: String
    let quality: String
  }
  let voices: [Voice]
  let defaultVoiceID: String
  let permissionWarning: String?
}

struct DraftQueueRequestDTO: Content {
  struct Entry: Content {
    let draftID: UUID
    let voiceID: String
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
  struct Connection: Content {
    let id: UUID
    let label: String
  }
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
  struct Defaults: Content {
    let voiceID: String
    let bitrateKbps: Int
    let workers: Int
    let announceTitles: Bool
    let paragraphPauseSeconds: Double
    let chapterPauseSeconds: Double
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
  let defaults: Defaults
  let voices: [AudiobookVoicesDTO.Voice]
  let permissionWarning: String?
  let connections: [LibraryDTO.Connection]
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
  let voiceID: String
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

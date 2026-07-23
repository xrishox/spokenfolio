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
  let capabilities: Capabilities
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

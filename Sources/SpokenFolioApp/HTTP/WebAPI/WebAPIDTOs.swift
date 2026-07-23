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

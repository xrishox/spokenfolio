import BookJobKit
import Foundation

enum ProductionWorkspaceMode: String, CaseIterable, Identifiable {
  case create = "Create"
  case queue = "Queue"
  case history = "History"

  var id: Self { self }
}

enum ProductionHistorySort: String, CaseIterable, Identifiable {
  case newest = "Newest"
  case title = "Title"
  case result = "Result"

  var id: Self { self }
}

enum ProductionJobPresentation {
  static func rows(
    _ rows: [StudioJobCoordinator.Row], mode: ProductionWorkspaceMode,
    search: String, historySort: ProductionHistorySort = .newest
  ) -> [StudioJobCoordinator.Row] {
    let terminal: Set<BookJobLifecycle> = [.completed, .cancelled]
    let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let filtered = rows.filter { row in
      let belongs = switch mode {
      case .create: false
      case .queue: !terminal.contains(row.state.lifecycle)
      case .history: terminal.contains(row.state.lifecycle)
      }
      guard belongs else { return false }
      guard !query.isEmpty else { return true }
      return row.request.title.lowercased().contains(query)
        || (row.request.author?.lowercased().contains(query) == true)
        || kindTitle(row).lowercased().contains(query)
    }
    if mode == .queue {
      return filtered.sorted { left, right in
        let lhs = left.control.queueSequence ?? UInt64.max
        let rhs = right.control.queueSequence ?? UInt64.max
        return lhs == rhs ? left.request.createdAt < right.request.createdAt : lhs < rhs
      }
    }
    return filtered.sorted { left, right in
      switch historySort {
      case .newest:
        if left.state.updatedAt != right.state.updatedAt {
          return left.state.updatedAt > right.state.updatedAt
        }
      case .title:
        let order = left.request.title.localizedStandardCompare(right.request.title)
        if order != .orderedSame { return order == .orderedAscending }
      case .result:
        let lhs = statusRank(left.state.lifecycle)
        let rhs = statusRank(right.state.lifecycle)
        if lhs != rhs { return lhs < rhs }
      }
      if left.request.createdAt != right.request.createdAt {
        return left.request.createdAt < right.request.createdAt
      }
      return left.id.uuidString < right.id.uuidString
    }
  }

  static func statusTitle(_ row: StudioJobCoordinator.Row) -> String {
    switch row.state.lifecycle {
    case .queued:
      return row.control.queueDisposition == .held ? "Held" : "Waiting"
    case .running:
      return row.state.stages.first(where: { $0.status == .running })
        .map { stageTitle($0.stage) } ?? "Running"
    case .paused: return "Paused"
    case .needsAttention:
      return row.control.queueDisposition == .retryReady ? "Waiting to Retry" : "Needs Attention"
    case .completed: return "Completed"
    case .cancelled: return "Cancelled"
    }
  }

  static func kindTitle(_ row: StudioJobCoordinator.Row) -> String {
    switch row.request.resolvedOperation {
    case .readAloud: return "ReadAloud"
    case .storytellerDelivery: return "Storyteller Delivery"
    case .production:
      if row.request.readAloud != nil, row.request.storyteller != nil {
        return "Audiobook, ReadAloud & Delivery"
      }
      if row.request.readAloud != nil { return "Audiobook & ReadAloud" }
      if row.request.storyteller != nil { return "Audiobook & Delivery" }
      return "Audiobook"
    }
  }

  static func progress(_ row: StudioJobCoordinator.Row) -> Double? {
    if row.state.lifecycle == .completed { return 1 }
    return row.state.stages.first(where: { $0.status == .running })?.fraction
      ?? row.state.stages.last(where: { $0.status == .paused })?.fraction
  }

  static func stageTitle(_ stage: BookJobStage) -> String {
    switch stage {
    case .preparation: "Preparing"
    case .m4bSynthesis: "Synthesizing Audiobook"
    case .m4bAssembly: "Assembling M4B"
    case .m4bVerification: "Verifying Audiobook"
    case .readAloudAudioProcessing: "Preparing ReadAloud Audio"
    case .readAloudTranscription: "Transcribing ReadAloud"
    case .readAloudMarkup: "Preparing EPUB Markup"
    case .readAloudAlignment: "Aligning ReadAloud"
    case .readAloudVerification: "Verifying ReadAloud"
    case .storytellerPreflight: "Checking Storyteller"
    case .storytellerUpload: "Uploading to Storyteller"
    case .storytellerReconciliation: "Confirming Storyteller Delivery"
    }
  }

  static func stageStatusTitle(_ status: BookJobStageStatus) -> String {
    switch status {
    case .pending: "Pending"
    case .running: "Running"
    case .succeeded: "Complete"
    case .failed: "Failed"
    case .paused: "Paused"
    case .needsAttention: "Needs Attention"
    case .skipped: "Not Required"
    }
  }

  private static func statusRank(_ lifecycle: BookJobLifecycle) -> Int {
    switch lifecycle {
    case .cancelled: 0
    case .completed: 1
    case .needsAttention: 2
    case .paused: 3
    case .queued: 4
    case .running: 5
    }
  }
}

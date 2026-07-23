import Foundation
import Vapor

/// Bridges service snapshots into the event broker as JSON SSE payloads.
/// One pump per server application; the lifecycle handler cancels its tasks
/// on shutdown so test applications do not leak pollers.
final class WebAPIEventPump: LifecycleHandler, @unchecked Sendable {
  private var tasks: [Task<Void, Never>] = []

  func start(services: StudioServices) {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    tasks.append(
      Task {
        for await snapshot in await services.jobs.snapshots() {
          guard !Task.isCancelled else { return }
          if let queue = try? encoder.encode(WebAPIController.queueDTO(snapshot)) {
            await services.events.publish(.queue, payload: queue)
          }
          if let jobs = try? encoder.encode(
            WebAPIController.jobDTOs(snapshot, scope: "all"))
          {
            await services.events.publish(.jobs, payload: jobs)
          }
        }
      })
  }

  func startDrafts(services: StudioServices) {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    tasks.append(
      Task {
        for await _ in await services.drafts.revisions() {
          guard !Task.isCancelled else { return }
          let drafts = await services.drafts.allDrafts.map(DraftsAPIController.dto)
          if let payload = try? encoder.encode(drafts) {
            await services.events.publish(.drafts, payload: payload)
          }
        }
      })
  }

  func shutdown(_ application: Application) {
    for task in tasks { task.cancel() }
    tasks = []
  }
}

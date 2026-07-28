import BookJobKit
import Foundation
import LibraryKit

/// The process-wide Studio service graph: one instance per process, hosting
/// everything an interface (SwiftUI, web API, future CLI) needs to drive
/// production, quality, the library, and Create drafts. The GUI's
/// `ApplicationRuntime` constructs one and hands it to the embedded server;
/// a headless `serve --studio` constructs the identical graph without
/// AppKit. Process-singleton safety comes from `scheduler.lock` and
/// `quality.lock`, not from this type.
final class StudioServices: Sendable {
  let jobs: JobSchedulerService
  let quality: QualityQueueService
  let drafts: DraftImportService
  let events = EventBroker()
  let deviceAuth = DeviceAuthSessionStore()
  let mirror: LibraryMirrorService
  let relocation: LibraryRelocationService
  /// Exclusive leases on the books being mutated. Every interface routes
  /// production, quality, download, and deletion through this one actor, so
  /// work cannot start against a book another operation is already changing.
  let mutations: LibraryMutationCoordinator
  let libraryDatabaseURL: URL

  init(
    jobs: JobSchedulerService = JobSchedulerService(),
    quality: QualityQueueService = QualityQueueService(),
    drafts: DraftImportService = DraftImportService(),
    libraryDatabaseURL: URL = AppPaths.libraryDatabaseURL
  ) {
    self.jobs = jobs
    self.quality = quality
    self.drafts = drafts
    self.libraryDatabaseURL = libraryDatabaseURL
    let mutations = LibraryMutationCoordinator { keys in
      await LibraryDeleteService.pendingWorkReason(
        keys: keys, jobs: jobs, libraryDatabaseURL: libraryDatabaseURL)
    }
    self.mutations = mutations
    let mirror = LibraryMirrorService(mutations: mutations)
    self.mirror = mirror
    self.relocation = LibraryRelocationService(
      jobs: jobs, quality: quality, mirror: mirror,
      libraryDatabaseURL: libraryDatabaseURL)
    jobs.attach(mutations: mutations)
    quality.attach(mutations: mutations)
  }

  /// Library reads/writes run through a fresh store per call site; GRDB's
  /// serialized queue provides thread safety, and callers must never block a
  /// server event loop with these synchronous calls — hop through a task.
  func makeLibraryStore() throws -> LibraryStore {
    try LibraryStore(databaseURL: libraryDatabaseURL)
  }
}

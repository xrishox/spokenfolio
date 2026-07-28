import BookJobKit
import Foundation
import LibraryKit
import StorytellerKit

/// Executes a `LibraryDeletePlanner` manifest: per book, it blocks books with
/// active work (never the whole selection), deletes acknowledged remote assets
/// through Storyteller's per-asset endpoint under the same ceiling
/// verification an acknowledged replacement uses, and removes local products
/// (or the whole edition) plus their files and synthesis-timeline sidecars.
///
/// Remote and local deletions are independent per book so a remote hiccup
/// never blocks a local delete the user asked for, and every step is
/// idempotent (deleting an already-absent slot succeeds). The remote deleter
/// and the per-book active-work check are injected so the whole engine is unit
/// testable without a network or the live scheduler.
struct LibraryDeleteService: Sendable {
  struct Outcome: Sendable, Equatable {
    struct Failure: Sendable, Equatable {
      let label: String
      let reason: String
    }
    let rowID: String
    let title: String
    /// Non-nil when the book was skipped because it had active work; nothing
    /// was touched.
    var blocked: String?
    var wholeBookDeleted = false
    var localDeleted: [BookProductKind] = []
    var remoteDeleted: [LibraryRemoteFormat] = []
    var failures: [Failure] = []

    var didSomething: Bool {
      wholeBookDeleted || !localDeleted.isEmpty || !remoteDeleted.isEmpty
    }
  }

  let catalogStore: BookCatalogStore
  let synthesisTimelineRoot: URL
  /// Exclusive leases on the book being deleted, held across the remote
  /// mutation, the filesystem changes, and the catalog changes. A snapshot
  /// check alone cannot stop work that starts right after it is read.
  let mutations: LibraryMutationCoordinator?
  /// Resolves the remote deleter for a connection, or nil when the connection
  /// is gone.
  let makeDeleter: @Sendable (UUID) async throws -> StorytellerAssetDeleter?
  /// Returns a human reason when a book must not be deleted right now (active
  /// or queued production/quality work, or an in-flight download), else nil.
  let blockedReason: @Sendable (_ catalogID: UUID?, _ rowID: String) async -> String?

  func execute(_ impacts: [LibraryDeletePlanner.DeletionImpact]) async -> [Outcome] {
    var outcomes: [Outcome] = []
    for impact in impacts { outcomes.append(await delete(impact)) }
    return outcomes
  }

  private func delete(_ impact: LibraryDeletePlanner.DeletionImpact) async -> Outcome {
    var outcome = Outcome(rowID: impact.rowID, title: impact.title)
    var lease: LibraryMutationCoordinator.Lease?
    if let mutations {
      switch await mutations.acquireForDeletion(Self.mutationKeys(impact)) {
      case .success(let value): lease = value
      case .failure(let refusal):
        outcome.blocked = refusal.reason
        return outcome
      }
    } else if let reason = await blockedReason(impact.catalogID, impact.rowID) {
      outcome.blocked = reason
      return outcome
    }
    // Remote first: a ceiling abort (the asset changed since confirmation)
    // leaves everything intact and is reported; local deletion is independent.
    if !impact.remoteSlots.isEmpty { await deleteRemote(impact, into: &outcome) }
    if impact.wholeBookLocal {
      await deleteWholeLocalBook(impact, into: &outcome)
    } else if !impact.localSlots.isEmpty {
      await deleteLocalSlots(impact, into: &outcome)
    }
    // Released before returning, not in a detached task: the next book in the
    // same run (or the next request) must not be refused by a key this
    // deletion has already finished with.
    if let lease, let mutations { await mutations.release(lease) }
    return outcome
  }

  /// Everything one deletion touches: the local edition, the library row, and
  /// the linked remote book.
  static func mutationKeys(
    _ impact: LibraryDeletePlanner.DeletionImpact
  ) -> Set<LibraryMutationCoordinator.Key> {
    var keys: Set<LibraryMutationCoordinator.Key> = [.row(impact.rowID)]
    if let catalogID = impact.catalogID { keys.insert(.edition(catalogID)) }
    if let remoteBookID = impact.remoteBookID { keys.insert(.remoteBook(remoteBookID)) }
    return keys
  }

  private func deleteRemote(
    _ impact: LibraryDeletePlanner.DeletionImpact, into outcome: inout Outcome
  ) async {
    guard let connectionID = impact.connectionID, let remoteBookID = impact.remoteBookID else {
      outcome.failures.append(
        .init(label: "Storyteller", reason: "the book has no linked Storyteller connection"))
      return
    }
    let deleter: StorytellerAssetDeleter
    do {
      guard let resolved = try await makeDeleter(connectionID) else {
        outcome.failures.append(
          .init(label: "Storyteller", reason: "the Storyteller connection for this book is gone"))
        return
      }
      deleter = resolved
      try await deleter.ensureCanUpdate()
    } catch {
      outcome.failures.append(.init(label: "Storyteller", reason: Self.message(error)))
      return
    }

    for slot in impact.remoteSlots {
      guard let format = StorytellerFormat(rawValue: slot.format.rawValue) else { continue }
      do {
        guard let book = try await deleter.liveBook(remoteBookID),
          let asset = book.asset(format)
        else {
          // Vanished asset (or book) — the deletion goal is already met.
          // Ceiling semantics: a vanished asset destroys nothing extra.
          outcome.remoteDeleted.append(slot.format)
          await dropReceiptIfKept(impact, format: slot.format)
          continue
        }
        // Identity, size, and fingerprint are always checked. A confirmed
        // content hash must be re-proved: a probe that fails or returns
        // nothing fails the deletion closed rather than passing it.
        let liveHash = await StorytellerMutationVerifier.liveHash {
          try await deleter.assetHash(
            bookID: remoteBookID, format: format, expectedSize: asset.fileSize ?? 0)
        }
        try StorytellerMutationVerifier.verify(
          format: format, asset: asset, liveHash: liveHash,
          expected: impact.expectedRemoteAssets, action: .deletion)
        let updated = try await deleter.deleteAsset(bookID: remoteBookID, format: format)
        guard updated.asset(format) == nil else {
          throw StorytellerAPIError.conflict(
            "the remote \(format.rawValue) asset still exists after deletion")
        }
        outcome.remoteDeleted.append(slot.format)
        await dropReceiptIfKept(impact, format: slot.format)
      } catch {
        outcome.failures.append(
          .init(label: "Storyteller \(slot.format.rawValue)", reason: Self.message(error)))
      }
    }
  }

  /// Drops the delivery receipt for a deleted remote format, unless the whole
  /// local book is being removed anyway (which drops all of them).
  private func dropReceiptIfKept(
    _ impact: LibraryDeletePlanner.DeletionImpact, format: LibraryRemoteFormat
  ) async {
    guard let catalogID = impact.catalogID, !impact.wholeBookLocal else { return }
    try? await catalogStore.dropDeliveryReceipts(catalogID: catalogID, format: format)
  }

  private func deleteWholeLocalBook(
    _ impact: LibraryDeletePlanner.DeletionImpact, into outcome: inout Outcome
  ) async {
    guard let catalogID = impact.catalogID, let sourceSHA = impact.sourceSHA256 else {
      outcome.failures.append(
        .init(label: "Local book", reason: "the book is not cataloged locally"))
      return
    }
    // Quarantine the folder first: a same-volume rename is atomic and
    // reversible, so a failing database mutation can put the bytes back
    // instead of leaving a catalog row pointing at deleted files.
    var quarantine: Quarantine?
    if let directory = impact.outputDirectory {
      let source = URL(fileURLWithPath: directory)
      if FileManager.default.fileExists(atPath: source.path) {
        do {
          quarantine = try Quarantine(moving: source)
        } catch {
          outcome.failures.append(
            .init(
              label: "Local book",
              reason: "the book folder could not be removed: \(Self.message(error))"))
          return
        }
      }
    }
    do {
      try await catalogStore.deleteEdition(catalogID: catalogID, expectedSourceSHA256: sourceSHA)
    } catch {
      // Put the files back before reporting the failure; the catalog still
      // references them.
      quarantine?.restore()
      outcome.failures.append(.init(label: "Local book", reason: Self.message(error)))
      return
    }
    if let quarantine, let reason = quarantine.discard() {
      outcome.failures.append(.init(label: "Local book files", reason: reason))
    }
    let timelines = SynthesisTimelineStore(root: synthesisTimelineRoot)
    for sha in impact.audiobookSHA256s { timelines.delete(forAudiobookSHA256: sha) }
    outcome.wholeBookDeleted = true
  }

  /// A same-volume holding area for files a deletion is about to remove. The
  /// move is atomic and reversible; the bytes are unlinked only once the
  /// database agrees they are gone.
  private struct Quarantine {
    let original: URL
    let staged: URL

    init(moving url: URL) throws {
      original = url
      staged = url.deletingLastPathComponent()
        .appendingPathComponent(".spokenfolio-deleting-\(UUID().uuidString)", isDirectory: false)
      try FileManager.default.moveItem(at: url, to: staged)
    }

    func restore() {
      try? FileManager.default.removeItem(at: original)
      try? FileManager.default.moveItem(at: staged, to: original)
    }

    /// Unlinks the quarantined bytes. Returns a reason when they could not be
    /// removed, so the outcome never claims a deletion that did not happen.
    func discard() -> String? {
      do {
        try FileManager.default.removeItem(at: staged)
        return nil
      } catch {
        return "the catalog entry was removed but the files could not be deleted "
          + "(they remain at \(staged.path)): \(error.localizedDescription)"
      }
    }
  }

  private func deleteLocalSlots(
    _ impact: LibraryDeletePlanner.DeletionImpact, into outcome: inout Outcome
  ) async {
    guard let catalogID = impact.catalogID else {
      outcome.failures.append(.init(label: "Local", reason: "the book is not cataloged locally"))
      return
    }
    let timelines = SynthesisTimelineStore(root: synthesisTimelineRoot)
    for slot in impact.localSlots {
      let file = URL(fileURLWithPath: slot.path)
      var quarantine: Quarantine?
      if FileManager.default.fileExists(atPath: file.path) {
        do {
          quarantine = try Quarantine(moving: file)
        } catch {
          outcome.failures.append(
            .init(
              label: "Local \(slot.kind.rawValue)",
              reason: "the file could not be removed: \(Self.message(error))"))
          continue
        }
      }
      do {
        _ = try await catalogStore.deleteProduct(
          catalogID: catalogID, kind: slot.kind, expectedSHA256: slot.sha256)
      } catch {
        quarantine?.restore()
        outcome.failures.append(
          .init(label: "Local \(slot.kind.rawValue)", reason: Self.message(error)))
        continue
      }
      if let quarantine, let reason = quarantine.discard() {
        outcome.failures.append(.init(label: "Local \(slot.kind.rawValue) file", reason: reason))
      }
      if slot.kind == .m4b { timelines.delete(forAudiobookSHA256: slot.sha256) }
      outcome.localDeleted.append(slot.kind)
    }
  }

  static func message(_ error: Error) -> String {
    if let error = error as? StorytellerAPIError { return error.errorDescription ?? "\(error)" }
    if let error = error as? BookJobError { return error.localizedDescription }
    if let error = error as? LibraryStoreError { return error.localizedDescription }
    return error.localizedDescription
  }
}

/// The remote operations the delete service needs, abstracted so it is unit
/// testable without a live Storyteller server.
protocol StorytellerAssetDeleter: Sendable {
  /// Throws unless the account may update (delete) assets on this connection.
  func ensureCanUpdate() async throws
  func liveBook(_ id: UUID) async throws -> StorytellerBook?
  func assetHash(bookID: UUID, format: StorytellerFormat, expectedSize: UInt64) async throws
    -> String?
  func deleteAsset(bookID: UUID, format: StorytellerFormat) async throws -> StorytellerBook
}

/// The production adapter over a real `StorytellerClient`.
struct LiveStorytellerAssetDeleter: StorytellerAssetDeleter {
  let client: StorytellerClient
  func ensureCanUpdate() async throws { _ = try await client.requirePermissions(create: false, update: true) }
  func liveBook(_ id: UUID) async throws -> StorytellerBook? { try await client.book(id) }
  func assetHash(bookID: UUID, format: StorytellerFormat, expectedSize: UInt64) async throws
    -> String?
  { try await client.assetHash(bookID: bookID, format: format, expectedSize: expectedSize) }
  func deleteAsset(bookID: UUID, format: StorytellerFormat) async throws -> StorytellerBook {
    try await client.deleteAsset(bookID: bookID, format: format)
  }
}

extension LibraryDeleteService {
  /// The production configuration: remote deleters resolved from the connection
  /// store, and per-book blocking that consults the live scheduler, quality
  /// queue (via the library store), and mirror service.
  static func live(
    catalogStore: BookCatalogStore, jobs: JobSchedulerService, mirror: LibraryMirrorService,
    mutations: LibraryMutationCoordinator? = nil,
    libraryDatabaseURL: URL = AppPaths.libraryDatabaseURL,
    synthesisTimelineRoot: URL = AppPaths.synthesisTimelineDirectory
  ) -> LibraryDeleteService {
    LibraryDeleteService(
      catalogStore: catalogStore, synthesisTimelineRoot: synthesisTimelineRoot,
      mutations: mutations,
      makeDeleter: { connectionID in
        let connections = try await StorytellerConnectionStore.shared.connections()
        guard let connection = connections.first(where: { $0.id == connectionID }) else {
          return nil
        }
        let client = try StorytellerClient(origin: connection.origin) {
          try await StorytellerConnectionStore.shared.token(connectionID)
        }
        return LiveStorytellerAssetDeleter(client: client)
      },
      blockedReason: { catalogID, rowID in
        await liveBlockedReason(
          catalogID: catalogID, rowID: rowID, jobs: jobs, mirror: mirror,
          libraryDatabaseURL: libraryDatabaseURL)
      })
  }

  /// Durable work that is queued but not running: a production job the
  /// scheduler has not dispatched yet, or a quality run waiting in its FIFO.
  /// Neither can hold an in-memory lease (they outlive the process), so the
  /// coordinator asks for them explicitly before allowing a deletion.
  static func pendingWorkReason(
    keys: Set<LibraryMutationCoordinator.Key>, jobs: JobSchedulerService,
    libraryDatabaseURL: URL
  ) async -> String? {
    let editionIDs = Set(
      keys.compactMap { $0.scope == .edition ? UUID(uuidString: $0.value) : nil })
    guard !editionIDs.isEmpty else { return nil }
    let rows = await jobs.currentSnapshot.rows
    if rows.contains(where: {
      guard let catalogID = $0.request.catalogID, editionIDs.contains(catalogID) else {
        return false
      }
      return $0.state.lifecycle == .running || JobSchedulerSnapshot.isDispatchable($0)
    }) {
      return "a production job for this book is active or queued"
    }
    let auditBusy =
      (try? await Task.detached(priority: .utility) { () -> Bool in
        let store = try LibraryStore(databaseURL: libraryDatabaseURL)
        var productIDs: Set<UUID> = []
        for editionID in editionIDs {
          productIDs.formUnion(try store.edition(editionID).products.map(\.id))
        }
        guard !productIDs.isEmpty else { return false }
        return try store.readAloudAudits(limit: 5_000).contains { run in
          guard [.running, .queued].contains(run.lifecycle) else { return false }
          if case .localProduct(let productID) = run.target { return productIDs.contains(productID) }
          return false
        }
      }.value) ?? false
    return auditBusy ? "a ReadAloud quality check for this book is running or queued" : nil
  }

  static func liveBlockedReason(
    catalogID: UUID?, rowID: String, jobs: JobSchedulerService, mirror: LibraryMirrorService,
    libraryDatabaseURL: URL
  ) async -> String? {
    if let catalogID {
      let rows = await jobs.currentSnapshot.rows
      if rows.contains(where: {
        $0.request.catalogID == catalogID
          && ($0.state.lifecycle == .running || JobSchedulerSnapshot.isDispatchable($0))
      }) {
        return "a production job for this book is active or queued"
      }
      let auditBusy =
        (try? await Task.detached(priority: .utility) { () -> Bool in
          let store = try LibraryStore(databaseURL: libraryDatabaseURL)
          let productIDs = Set(try store.edition(catalogID).products.map(\.id))
          guard !productIDs.isEmpty else { return false }
          return try store.readAloudAudits(limit: 5_000).contains { run in
            guard [.running, .queued].contains(run.lifecycle) else { return false }
            if case .localProduct(let productID) = run.target { return productIDs.contains(productID) }
            return false
          }
        }.value) ?? false
      if auditBusy { return "a ReadAloud quality check for this book is running or queued" }
    }
    if await mirror.currentSnapshot.activeRowIDs.contains(rowID) {
      return "a Storyteller download for this book is in progress"
    }
    return nil
  }
}

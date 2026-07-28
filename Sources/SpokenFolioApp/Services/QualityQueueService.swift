import BookJobKit
import Foundation
import LibraryKit
import ReadAloudKit
import StorytellerKit

/// A point-in-time view of the ReadAloud quality queue, safe to send to any
/// interface. `revision` increments whenever durable audit rows changed, so
/// consumers know to re-read the library store.
struct QualityQueueSnapshot: Sendable {
  var currentRunID: UUID?
  var currentTarget: LibraryReadAloudAuditTarget?
  var progress: Double?
  var status = ""
  var isBusy = false
  var error: String?
  /// Titles learned from live Storyteller polls (fresher than store rows).
  var learnedTitles: [LibraryReadAloudAuditTarget: String] = [:]
  var revision: UInt64 = 0
  var sequence: UInt64 = 0
}

/// The serial ReadAloud quality audit queue, extracted from the GUI model so
/// any interface can host it. Durable authority is the library store's audit
/// rows; this engine dispatches exactly one audit at a time, reconciles
/// Storyteller automatic-audit intents, and publishes snapshots. Exactly one
/// instance may run audits per machine: a `quality.lock` beside the library
/// database arbitrates, mirroring the production scheduler's lock.
///
/// Deliberately a lock-guarded class rather than an actor: the enqueue and
/// cancel paths are synchronous GRDB work that the SwiftUI adapter and tests
/// call inline, matching the historical model surface.
final class QualityQueueService: @unchecked Sendable {
  enum AutomaticAuditResolution: Equatable {
    case waiting
    case ready(LibraryReadAloudAuditTarget)
    case failed(String)
  }

  private let databaseURL: URL
  private let qualityLockURL: URL
  private let lock = NSLock()

  // Lock-guarded state.
  private var snapshot = QualityQueueSnapshot()
  private var subscribers: [UUID: AsyncStream<QualityQueueSnapshot>.Continuation] = [:]
  private var titles: [LibraryReadAloudAuditTarget: String] = [:]
  private var auditTask: Task<Void, Never>?
  private var activeExecutionTask: Task<Void, Error>?
  private var automaticAuditTask: Task<Void, Never>?
  private var currentCancellationIsUserInitiated = false
  private var isShuttingDown = false
  private var queueLock: BookFileLock?
  private var remoteBookCache: [UUID: [StorytellerBook]] = [:]
  /// Test seam: replaces the real audit execution so lifecycle tests are
  /// hermetic. Never set in production.
  var executeOverride: (@Sendable (LibraryReadAloudAuditRun) async throws -> Void)? {
    get { lock.withLock { _executeOverride } }
    set { lock.withLock { _executeOverride = newValue } }
  }
  private var _executeOverride: (@Sendable (LibraryReadAloudAuditRun) async throws -> Void)?

  init(databaseURL: URL = AppPaths.libraryDatabaseURL) {
    self.databaseURL = databaseURL
    self.qualityLockURL = databaseURL.deletingLastPathComponent()
      .appendingPathComponent("quality.lock")
  }

  private func makeStore() throws -> LibraryStore {
    try LibraryStore(databaseURL: databaseURL)
  }

  // MARK: - Observation

  var currentSnapshot: QualityQueueSnapshot { lock.withLock { snapshot } }

  func snapshots() -> AsyncStream<QualityQueueSnapshot> {
    let id = UUID()
    return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
      let current = lock.withLock { () -> QualityQueueSnapshot in
        subscribers[id] = continuation
        return snapshot
      }
      continuation.yield(current)
      continuation.onTermination = { [weak self] _ in
        guard let self else { return }
        self.lock.withLock { _ = self.subscribers.removeValue(forKey: id) }
      }
    }
  }

  private func publish(
    revisionChanged: Bool = false, _ mutate: (inout QualityQueueSnapshot) -> Void
  ) {
    let (value, continuations) = lock.withLock {
      () -> (QualityQueueSnapshot, [AsyncStream<QualityQueueSnapshot>.Continuation]) in
      mutate(&snapshot)
      if revisionChanged { snapshot.revision &+= 1 }
      snapshot.sequence &+= 1
      return (snapshot, Array(subscribers.values))
    }
    for continuation in continuations { continuation.yield(value) }
  }

  /// Interfaces with richer metadata (the GUI's artifact assembly) push their
  /// title map so transient status lines match what the user sees.
  func updateTitles(_ values: [LibraryReadAloudAuditTarget: String]) {
    lock.withLock { titles = values }
  }

  func title(for target: LibraryReadAloudAuditTarget) -> String {
    let known = lock.withLock { titles[target] ?? snapshot.learnedTitles[target] }
    if let known, !known.isEmpty { return known }
    switch target {
    case .localProduct(let id): return "Local ReadAloud \(id.uuidString.prefix(8))"
    case .remote(_, let bookID, _): return "Storyteller book \(bookID.uuidString.prefix(8))"
    case .standalone(let path):
      return URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    }
  }

  // MARK: - Enqueue and cancellation

  /// Queues quality checks for targets not already queued or running.
  /// Returns the queued count; status/error land in the snapshot.
  @discardableResult
  func enqueue(_ targets: [LibraryReadAloudAuditTarget], mode: ReadAloudAuditMode) -> Int {
    do {
      let store = try makeStore()
      let unique = targets.reduce(into: [LibraryReadAloudAuditTarget]()) { result, target in
        if !result.contains(target) { result.append(target) }
      }
      let active = Set(try store.readAloudAudits(limit: 5_000).compactMap {
        [.queued, .running].contains($0.lifecycle) ? $0.target : nil
      })
      let runs = Self.queueRuns(
        targets: unique, excluding: active, mode: mode, now: Date())
      guard !runs.isEmpty else {
        publish {
          $0.status = unique.isEmpty
            ? "No selected ReadAlouds are available to audit"
            : "Selected audits are already queued or running"
        }
        return 0
      }
      try store.saveReadAloudAudits(runs)
      publish(revisionChanged: true) {
        $0.error = nil
        $0.status = "Queued \(runs.count) quality check\(runs.count == 1 ? "" : "s")"
      }
      startQueueIfNeeded()
      return runs.count
    } catch {
      publish { $0.error = error.localizedDescription }
      return 0
    }
  }

  static func queueRuns(
    targets: [LibraryReadAloudAuditTarget],
    excluding active: Set<LibraryReadAloudAuditTarget>,
    mode: ReadAloudAuditMode, now: Date
  ) -> [LibraryReadAloudAuditRun] {
    var seen = Set<LibraryReadAloudAuditTarget>()
    let candidates = targets.filter {
      seen.insert($0).inserted && !active.contains($0)
    }
    return candidates.enumerated().map { index, target in
      let timestamp = now.addingTimeInterval(Double(index) / 1_000)
      return LibraryReadAloudAuditRun(
        target: target, analyzerIdentity: "readaloud-quality-v1",
        policyVersion: ReadAloudQualityAuditor.policyVersion,
        mode: mode.rawValue, lifecycle: .queued, progress: 0,
        progressMessage: "Queued", startedAt: timestamp, updatedAt: timestamp)
    }
  }

  static func requeuedAfterGracefulInterruption(
    _ run: LibraryReadAloudAuditRun, at date: Date = Date()
  ) -> LibraryReadAloudAuditRun {
    var value = run
    value.artifactSHA256 = nil
    value.referenceSHA256 = nil
    value.lifecycle = .queued
    value.progress = 0
    value.progressMessage = "Queued after application restart"
    value.verdict = nil
    value.evidenceAdequacy = nil
    value.modelIdentity = nil
    value.toolIdentity = nil
    value.metricsData = nil
    value.reportData = nil
    value.updatedAt = date
    value.completedAt = nil
    value.error = nil
    value.findings = []
    return value
  }

  static func cancelledWaitingRuns(
    _ runs: [LibraryReadAloudAuditRun], selectedIDs: Set<UUID>? = nil,
    at date: Date = Date()
  ) -> [LibraryReadAloudAuditRun] {
    runs.compactMap { run in
      guard run.lifecycle == .queued,
        selectedIDs.map({ $0.contains(run.id) }) ?? true
      else { return nil }
      var value = run
      value.lifecycle = .cancelled
      value.progressMessage = "Removed from queue"
      // queueRuns future-dates startedAt by milliseconds for FIFO ordering;
      // a transition inside that window must not write updatedAt < startedAt
      // (the store rejects such records).
      value.updatedAt = max(date, run.startedAt)
      value.completedAt = value.updatedAt
      value.error = nil
      return value
    }
  }

  /// Cancels waiting runs (optionally only the selected IDs). Returns the
  /// IDs actually cancelled.
  @discardableResult
  func cancelWaitingAudits(_ selectedIDs: Set<UUID>? = nil) -> Set<UUID> {
    do {
      let store = try makeStore()
      let currentRunID = lock.withLock { snapshot.currentRunID }
      let waiting = try store.readAloudAudits(limit: 5_000).filter { $0.id != currentRunID }
      let changed = Self.cancelledWaitingRuns(waiting, selectedIDs: selectedIDs)
      guard !changed.isEmpty else {
        publish { $0.status = "No waiting quality checks were selected" }
        return []
      }
      try store.saveReadAloudAudits(changed)
      publish(revisionChanged: true) {
        $0.status = "Removed \(changed.count) waiting check\(changed.count == 1 ? "" : "s")"
        $0.error = nil
      }
      return Set(changed.map(\.id))
    } catch {
      publish { $0.error = error.localizedDescription }
      return []
    }
  }

  func cancelCurrentAudit() {
    let execution = lock.withLock { () -> Task<Void, Error>? in
      guard snapshot.currentRunID != nil, let task = activeExecutionTask else { return nil }
      currentCancellationIsUserInitiated = true
      return task
    }
    guard let execution else { return }
    publish { $0.status = "Cancelling the current quality check…" }
    execution.cancel()
  }

  func cancelAllAudits() {
    let (count, hadCurrentAudit): (Int, Bool)
    do {
      let store = try makeStore()
      let currentRunID = lock.withLock { snapshot.currentRunID }
      let pending = try store.readAloudAudits(limit: 5_000).filter {
        [.queued, .running].contains($0.lifecycle) || $0.id == currentRunID
      }
      count = Set(pending.map(\.id)).count
      hadCurrentAudit = currentRunID != nil
    } catch {
      publish { $0.error = error.localizedDescription }
      return
    }
    cancelWaitingAudits()
    cancelCurrentAudit()
    if count > 0 {
      let verb = hadCurrentAudit ? "Cancelling" : "Cancelled"
      let suffix = hadCurrentAudit ? "…" : ""
      publish {
        $0.status = "\(verb) all \(count) quality check\(count == 1 ? "" : "s")\(suffix)"
      }
    }
  }

  func resumeQueuedAudits() {
    startQueueIfNeeded()
    startAutomaticAuditMonitorIfNeeded()
  }

  // MARK: - Queue processing

  /// Exclusive leases on the books being audited, so a deletion cannot land
  /// while a quality run is reading the very files it checks.
  private var mutations: LibraryMutationCoordinator?

  func attach(mutations: LibraryMutationCoordinator) {
    lock.withLock { self.mutations = mutations }
  }

  /// The keys a run occupies. A standalone audit reads a loose file that no
  /// edition owns, so it takes nothing.
  static func mutationKeys(
    _ target: LibraryReadAloudAuditTarget, editionID: UUID?
  ) -> Set<LibraryMutationCoordinator.Key> {
    switch target {
    case .localProduct:
      return editionID.map { [.edition($0)] } ?? []
    case .remote(_, let bookID, _):
      return [.remoteBook(bookID)]
    case .standalone:
      return []
    }
  }

  /// The edition owning an audited local product, resolved once so the audit
  /// can claim it. Nil when the product is not (or no longer) cataloged.
  private func editionIDForAudit(_ target: LibraryReadAloudAuditTarget) -> UUID? {
    guard case .localProduct(let productID) = target else { return nil }
    return try? makeStore().scanEditions().editions.first {
      $0.products.contains { $0.id == productID }
    }?.id
  }

  private func startQueueIfNeeded() {
    do {
      let hasQueued = try makeStore()
        .readAloudAudits(limit: 5_000).contains { $0.lifecycle == .queued }
      guard hasQueued else { return }
      guard acquireQueueLockIfNeeded() else { return }
      let started: Bool = lock.withLock {
        guard auditTask == nil else { return false }
        auditTask = Task { [weak self] in await self?.processQueue() }
        return true
      }
      _ = started
    } catch {
      publish { $0.error = error.localizedDescription }
    }
  }

  /// The quality queue is a process singleton, like the production
  /// scheduler: the lock file beside the library database arbitrates.
  private func acquireQueueLockIfNeeded() -> Bool {
    lock.withLock {
      if queueLock != nil { return true }
      do {
        queueLock = try BookFileLock(url: qualityLockURL, nonblocking: true)
        return true
      } catch {
        snapshot.error = "Another quality queue is already active."
        return false
      }
    }
  }

  private func processQueue() async {
    publish {
      $0.isBusy = true
    }
    lock.withLock { remoteBookCache.removeAll() }
    defer {
      publish {
        $0.isBusy = false
        $0.progress = nil
        $0.currentTarget = nil
        $0.currentRunID = nil
      }
      lock.withLock { auditTask = nil }
    }
    while !Task.isCancelled {
      do {
        let store = try makeStore()
        let pending = try store.readAloudAudits(limit: 5_000)
          .filter { $0.lifecycle == .queued }
          .sorted {
            if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
            return $0.id.uuidString < $1.id.uuidString
          }
        guard let run = pending.first else {
          publish(revisionChanged: true) { $0.status = "Quality queue complete" }
          return
        }
        publish(revisionChanged: true) {
          $0.currentTarget = run.target
          $0.currentRunID = run.id
          $0.progress = 0
          $0.status = "Starting quality check · \(pending.count) queued"
        }
        lock.withLock { currentCancellationIsUserInitiated = false }
        let override = executeOverride
        let coordinator = lock.withLock { mutations }
        let execution = Task {
          // Hold the book for the whole audit; released however it ends.
          var lease: LibraryMutationCoordinator.Lease?
          if let coordinator {
            let keys = Self.mutationKeys(
              run.target, editionID: self.editionIDForAudit(run.target))
            if case .success(let value) = await coordinator.acquire(keys, for: .quality) {
              lease = value
            }
          }
          do {
            if let override {
              try await override(run)
            } else {
              try await self.execute(run)
            }
          } catch {
            if let lease, let coordinator { await coordinator.release(lease) }
            throw error
          }
          if let lease, let coordinator { await coordinator.release(lease) }
        }
        lock.withLock { activeExecutionTask = execution }
        do {
          try await execution.value
        } catch is CancellationError {
          lock.withLock { activeExecutionTask = nil }
          let shuttingDown = lock.withLock { isShuttingDown }
          if shuttingDown || Task.isCancelled,
            let interrupted = try store.readAloudAudits(limit: 5_000).first(where: {
              $0.id == run.id
            })
          {
            try store.saveReadAloudAudit(Self.requeuedAfterGracefulInterruption(interrupted))
            publish(revisionChanged: true) { _ in }
            return
          }
          // Every cancellation reaches a terminal state; an unclassifiable
          // interruption must not leave a zombie .running row behind.
          let userInitiated = lock.withLock { currentCancellationIsUserInitiated }
          try cancelIfNonterminal(
            runID: run.id,
            message: userInitiated ? "Cancelled by user" : "Interrupted unexpectedly",
            store: store)
          // Resolve the title before publishing: title(for:) takes the same
          // non-recursive lock publish holds during its mutate closure.
          let cancelledTitle = userInitiated ? title(for: run.target) : nil
          publish(revisionChanged: true) {
            if let cancelledTitle {
              $0.status = "Cancelled \(cancelledTitle)"
            }
            $0.currentTarget = nil
            $0.currentRunID = nil
            $0.progress = nil
          }
          lock.withLock { currentCancellationIsUserInitiated = false }
          continue
        } catch {
          lock.withLock { activeExecutionTask = nil }
          let userInitiated = lock.withLock { currentCancellationIsUserInitiated }
          if userInitiated {
            // The user's cancel raced the stage teardown; the stage's own
            // error is a consequence of cancelling, not an audit failure.
            try cancelIfNonterminal(runID: run.id, message: "Cancelled by user", store: store)
            lock.withLock { currentCancellationIsUserInitiated = false }
            let cancelledTitle = title(for: run.target)
            publish(revisionChanged: true) {
              $0.status = "Cancelled \(cancelledTitle)"
            }
          } else {
            try failIfNonterminal(
              runID: run.id, message: error.localizedDescription, store: store)
            publish(revisionChanged: true) { $0.error = error.localizedDescription }
          }
        }
        lock.withLock { activeExecutionTask = nil }
        publish(revisionChanged: true) {
          $0.currentTarget = nil
          $0.currentRunID = nil
          $0.progress = nil
        }
      } catch {
        publish { $0.error = error.localizedDescription }
        return
      }
    }
  }

  private func execute(_ run: LibraryReadAloudAuditRun) async throws {
    guard let mode = ReadAloudAuditMode(rawValue: run.mode) else {
      throw LibraryStoreError.invalidRecord("queued ReadAloud audit has an invalid mode")
    }
    let service = ReadAloudAuditService()
    let update: @Sendable (ReadAloudAuditProgress) -> Void = { [weak self] value in
      guard let self else { return }
      let matches = self.lock.withLock { self.snapshot.currentRunID == run.id }
      guard matches else { return }
      self.publish {
        $0.progress = value.fraction
        $0.status = value.message
      }
    }
    switch run.target {
    case .localProduct(let productID):
      let store = try makeStore()
      guard let match = try store.scanEditions().editions.lazy.compactMap({ edition in
        edition.products.first(where: { $0.id == productID }).map { (edition, $0) }
      }).first else { throw LibraryStoreError.notFound("queued local ReadAloud product") }
      _ = try await service.auditLocal(
        epub: URL(fileURLWithPath: match.1.path),
        sourceEPUB: URL(fileURLWithPath: match.0.source.path),
        target: run.target, runID: run.id, mode: mode, progress: update)
    case .standalone(let path):
      _ = try await service.auditLocal(
        epub: URL(fileURLWithPath: path), target: run.target,
        runID: run.id, mode: mode, progress: update)
    case .remote(let connectionID, let bookID, let assetID):
      let available = try await StorytellerConnectionStore.shared.connections()
      guard let connection = available.first(where: { $0.id == connectionID }) else {
        throw LibraryStoreError.notFound("Storyteller connection for queued quality check")
      }
      let token = try await Self.storytellerToken(connectionID)
      let client = try StorytellerClient(origin: connection.origin, tokenProvider: { token })
      let books: [StorytellerBook]
      if let cached = lock.withLock({ remoteBookCache[connectionID] }) {
        books = cached
      } else {
        books = try await client.books()
        lock.withLock { remoteBookCache[connectionID] = books }
      }
      guard let book = books.first(where: { $0.uuid == bookID }),
        book.asset(.readaloud)?.uuid == assetID
      else { throw LibraryStoreError.notFound("queued Storyteller ReadAloud asset") }
      _ = try await service.auditStoryteller(
        client: client, connectionID: connectionID, book: book,
        runID: run.id, mode: mode, progress: update)
    }
  }

  private func failIfNonterminal(runID: UUID, message: String, store: LibraryStore) throws {
    guard var current = try store.readAloudAudits(limit: 5_000).first(where: { $0.id == runID }),
      [.queued, .running].contains(current.lifecycle)
    else { return }
    current.lifecycle = .failed
    current.progressMessage = "Failed"
    current.error = String(message.prefix(4_096))
    current.updatedAt = max(Date(), current.startedAt)
    current.completedAt = current.updatedAt
    try store.saveReadAloudAudit(current)
  }

  private func cancelIfNonterminal(runID: UUID, message: String, store: LibraryStore) throws {
    guard var current = try store.readAloudAudits(limit: 5_000).first(where: { $0.id == runID }),
      [.queued, .running].contains(current.lifecycle)
    else { return }
    current.lifecycle = .cancelled
    current.progressMessage = message
    current.updatedAt = max(Date(), current.startedAt)
    current.completedAt = current.updatedAt
    current.error = nil
    try store.saveReadAloudAudit(current)
  }

  // MARK: - Automatic remote audits

  static func automaticAuditResolution(
    connectionID: UUID, book: StorytellerBook
  ) -> AutomaticAuditResolution {
    guard let asset = book.readaloud else { return .waiting }
    switch asset.status?.uppercased() {
    case "ERROR", "STOPPED":
      return .failed(
        "Storyteller ReadAloud processing ended with status \(asset.status ?? "unknown")")
    case "ALIGNED" where asset.isAvailable:
      return .ready(
        .remote(connectionID: connectionID, bookID: book.uuid, assetID: asset.uuid))
    default:
      return .waiting
    }
  }

  private func startAutomaticAuditMonitorIfNeeded() {
    let started: Bool = lock.withLock {
      guard automaticAuditTask == nil else { return false }
      automaticAuditTask = Task { [weak self] in
        guard let self else { return }
        while !Task.isCancelled {
          await self.reconcileAutomaticAudits()
          do { try await Task.sleep(for: .seconds(30)) } catch { return }
        }
      }
      return true
    }
    _ = started
  }

  private func reconcileAutomaticAudits() async {
    do {
      let store = try makeStore()
      let intents = try store.pendingRemoteReadAloudAutoAudits()
      guard !intents.isEmpty else { return }
      let available = try await StorytellerConnectionStore.shared.connections()
      let connectionsByID = Dictionary(uniqueKeysWithValues: available.map { ($0.id, $0) })
      for connectionID in Set(intents.map(\.connectionID)) {
        guard !Task.isCancelled, let connection = connectionsByID[connectionID] else { continue }
        let token = try await Self.storytellerToken(connectionID)
        let client = try StorytellerClient(origin: connection.origin, tokenProvider: { token })
        let books = try await client.books()
        learnRemoteTitles(connectionID: connectionID, books: books)
        let booksByID = Dictionary(uniqueKeysWithValues: books.map { ($0.uuid, $0) })
        for intent in intents where intent.connectionID == connectionID {
          guard let book = booksByID[intent.bookID] else { continue }
          switch Self.automaticAuditResolution(connectionID: connectionID, book: book) {
          case .failed(let message):
            try store.failRemoteReadAloudAutoAudit(intent.id, message: message)
            publish(revisionChanged: true) { _ in }
          case .ready(let target):
            _ = enqueue([target], mode: .standard)
            let active = try store.readAloudAudits(limit: 5_000).contains {
              $0.target == target && [.queued, .running].contains($0.lifecycle)
            }
            if active { try store.completeRemoteReadAloudAutoAudit(intent.id) }
          case .waiting:
            continue
          }
        }
      }
    } catch {
      // Authentication and network failures are retryable. Keep the durable
      // intent and try it again on the next pass.
      publish {
        $0.error = "Automatic ReadAloud quality check is waiting: \(error.localizedDescription)"
      }
    }
  }

  private func learnRemoteTitles(connectionID: UUID, books: [StorytellerBook]) {
    publish { snapshot in
      for book in books {
        guard let asset = book.asset(.readaloud) else { continue }
        snapshot.learnedTitles[
          .remote(connectionID: connectionID, bookID: book.uuid, assetID: asset.uuid)
        ] = book.title
      }
    }
  }

  private static func storytellerToken(_ connectionID: UUID) async throws -> String {
    try await StorytellerConnectionStore.shared.token(connectionID)
  }

  // MARK: - Shutdown

  func cancelAndWait() async {
    let (execution, audit, automatic) = lock.withLock {
      () -> (Task<Void, Error>?, Task<Void, Never>?, Task<Void, Never>?) in
      isShuttingDown = true
      return (activeExecutionTask, auditTask, automaticAuditTask)
    }
    execution?.cancel()
    audit?.cancel()
    automatic?.cancel()
    _ = await execution?.result
    await audit?.value
    await automatic?.value
    lock.withLock {
      activeExecutionTask = nil
      auditTask = nil
      automaticAuditTask = nil
      isShuttingDown = false
      queueLock = nil
    }
  }
}

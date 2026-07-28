import Foundation

/// The one place that decides whether a book may be mutated right now.
///
/// Snapshot checks alone cannot make that decision: reading "no job is
/// running" and then deleting is two operations, and work can be queued or
/// started in the gap between them. This actor closes that gap by handing out
/// exclusive leases on the keys a mutation touches — the local edition, the
/// library row, and the linked remote book — and holding them for the whole
/// operation, not just the check.
///
/// Durable queued work (a production job the scheduler has not started, a
/// quality run waiting in its FIFO) cannot hold an in-memory lease across
/// process restarts, so the coordinator also consults a caller-supplied probe
/// of that persistent state. Both answers come from here, so no interface has
/// to remember to ask twice.
actor LibraryMutationCoordinator {
  enum Holder: String, Sendable {
    case production, quality, download, deletion

    var describedWork: String {
      switch self {
      case .production: "a production job for this book is running"
      case .quality: "a quality check for this book is running"
      case .download: "a Storyteller download for this book is in progress"
      case .deletion: "this book is being deleted"
      }
    }
  }

  struct Key: Hashable, Sendable {
    enum Scope: String, Sendable { case edition, row, remoteBook }
    let scope: Scope
    let value: String

    static func edition(_ id: UUID) -> Key { .init(scope: .edition, value: id.uuidString) }
    static func row(_ id: String) -> Key { .init(scope: .row, value: id) }
    static func remoteBook(_ id: UUID) -> Key { .init(scope: .remoteBook, value: id.uuidString) }
  }

  /// Why a mutation may not proceed, carrying the user-facing reason.
  struct Refusal: Error, Sendable, Equatable {
    let reason: String
  }

  /// Held for the duration of a mutation. Releasing is the caller's
  /// responsibility; a dropped lease keeps its keys blocked, which fails
  /// safe (refusing work) rather than unsafe (concurrent mutation).
  struct Lease: Sendable, Equatable {
    let id: UUID
    let holder: Holder
    fileprivate let keys: Set<Key>
  }

  /// Persistent work that is queued but not yet running. Returns a reason to
  /// refuse, or nil. Consulted only for deletion, which is the operation that
  /// must not race with work about to start.
  private let pendingWork: @Sendable (Set<Key>) async -> String?
  private var held: [Key: (holder: Holder, lease: UUID)] = [:]

  init(pendingWork: @escaping @Sendable (Set<Key>) async -> String? = { _ in nil }) {
    self.pendingWork = pendingWork
  }

  /// Takes every key or none. Returns the refusal reason when any key is
  /// already held, so the caller can report which work is in the way.
  func acquire(_ keys: Set<Key>, for holder: Holder) -> Result<Lease, Refusal> {
    guard !keys.isEmpty else {
      return .success(Lease(id: UUID(), holder: holder, keys: []))
    }
    if let conflict = keys.compactMap({ held[$0] }).first {
      return .failure(Refusal(reason: conflict.holder.describedWork))
    }
    let lease = Lease(id: UUID(), holder: holder, keys: keys)
    for key in keys { held[key] = (holder, lease.id) }
    return .success(lease)
  }

  /// Deletion additionally refuses when durable queued work names the book:
  /// such work would start the moment the lease is released, against a book
  /// that no longer exists.
  func acquireForDeletion(_ keys: Set<Key>) async -> Result<Lease, Refusal> {
    let lease: Lease
    switch acquire(keys, for: .deletion) {
    case .success(let value): lease = value
    case .failure(let reason): return .failure(reason)
    }
    if let reason = await pendingWork(keys) {
      release(lease)
      return .failure(Refusal(reason: reason))
    }
    return .success(lease)
  }

  /// Breaks `.production` leases the scheduler does not recognize as its own.
  ///
  /// Every production lease belongs to the scheduler, which remembers the one
  /// lease per lane it is currently running under. A `.production` holder
  /// absent from that set is an orphan — leaked by a hop that died between
  /// claim and launch — and an orphan never releases itself, so leaving it
  /// would block its book forever. Only the production side may call this,
  /// and only production leases are touched: quality, download, and deletion
  /// holders describe operations that are genuinely still running.
  func reclaimOrphanedProductionLeases(
    _ keys: Set<Key>, recognizedLeaseIDs: Set<UUID>
  ) -> Bool {
    var reclaimed = false
    for key in keys {
      guard let entry = held[key], entry.holder == .production,
        !recognizedLeaseIDs.contains(entry.lease)
      else { continue }
      held.removeValue(forKey: key)
      reclaimed = true
    }
    return reclaimed
  }

  func release(_ lease: Lease?) {
    guard let lease else { return }
    for key in lease.keys where held[key]?.lease == lease.id {
      held.removeValue(forKey: key)
    }
  }

  /// Read-only peek for display. Never use this to decide whether to mutate —
  /// that is what `acquire` is for.
  func currentHolder(of key: Key) -> Holder? { held[key]?.holder }
}

import AudiobookKit
import BookJobKit
import EPUBKit
import Foundation
import LibraryKit
import StorytellerKit

/// Downloads Storyteller ebook sources into the local catalog ("mirroring"):
/// each book's EPUB is fetched, imported through the standard digest-verified
/// pipeline, staged into the managed output layout by `resolveCatalog`, and
/// linked to its remote edition. Audiobooks and ReadAlouds are deliberately
/// never downloaded (invariant 22) — a mirrored book becomes locally
/// processable, and local products are synthesized, not fetched.
///
/// One drain worker runs at most three books in flight at once: enough
/// parallelism to hide per-book network latency when mirroring 100+ books,
/// while still bounding pressure on the remote server and the local importer.
actor LibraryMirrorService {
  struct Item: Sendable {
    let rowID: String
    let title: String
    let remote: LibraryRemoteBookSnapshot
  }

  struct Snapshot: Sendable {
    var isBusy = false
    var total = 0
    var completed = 0
    var currentTitle: String?
    var failures: [(title: String, reason: String)] = []
    var lastCompletedAt: Date?
    var sequence: UInt64 = 0
    /// The connection the current/most recent run downloads from, so status
    /// banners can scope themselves to the connection they describe.
    var connectionID: UUID?
  }

  /// How many books may be downloaded/imported concurrently in one drain run.
  private static let maximumInFlight = 3

  private var snapshot = Snapshot()
  private var queue: [Item] = []
  private var worker: Task<Void, Never>?
  private var onChange: (@Sendable (Snapshot) -> Void)?
  /// One client (and thus one URLSession) per connection per drain run.
  /// Cleared when the run finishes; the token provider re-reads the Keychain
  /// on every request, so a cached client never pins a stale token.
  private var clients: [UUID: StorytellerClient] = [:]

  func setChangeHandler(_ handler: @escaping @Sendable (Snapshot) -> Void) {
    onChange = handler
  }

  var currentSnapshot: Snapshot { snapshot }

  private func publish(_ mutate: (inout Snapshot) -> Void) {
    mutate(&snapshot)
    snapshot.sequence &+= 1
    onChange?(snapshot)
  }

  /// Enqueues items not already queued; starts the worker if idle.
  /// Returns the number newly queued.
  @discardableResult
  func enqueue(_ items: [Item]) -> Int {
    let queuedIDs = Set(queue.map(\.rowID))
    let fresh = items.filter { !queuedIDs.contains($0.rowID) }
    guard !fresh.isEmpty else { return 0 }
    queue.append(contentsOf: fresh)
    publish {
      $0.connectionID = fresh.first?.remote.connectionID ?? $0.connectionID
      $0.total += fresh.count
      if !$0.isBusy {
        $0.failures = []
        $0.completed = 0
        $0.total = fresh.count
      }
    }
    startWorkerIfNeeded()
    return fresh.count
  }

  private func startWorkerIfNeeded() {
    guard worker == nil else { return }
    worker = Task { await self.drain() }
  }

  private func drain() async {
    publish { $0.isBusy = true }
    defer {
      clients = [:]
      publish {
        $0.isBusy = false
        $0.currentTitle = nil
        $0.lastCompletedAt = Date()
      }
      worker = nil
    }
    // One catalog/settings handle per run; the processed directory is read
    // once because a mid-run settings change should not split one drain's
    // output across two layouts.
    let catalogStore = BookCatalogStore(root: AppPaths.bookCatalogRoot)
    let processedDirectory: URL
    do {
      let settingsStore = StudioSettingsStore(url: AppPaths.studioSettingsURL)
      processedDirectory = (try await settingsStore.load())
        .resolvedProcessedDirectory(home: FileManager.default.homeDirectoryForCurrentUser)
    } catch {
      while !queue.isEmpty {
        let item = queue.removeFirst()
        publish {
          $0.failures.append((item.title, error.localizedDescription))
          $0.completed += 1
        }
      }
      return
    }
    // Downloads/imports run in child tasks off the actor; queue mutation and
    // snapshot publishing stay on the actor between suspension points.
    await withTaskGroup(of: (Item, (any Error)?).self) { group in
      var inFlight = 0
      while inFlight > 0 || !queue.isEmpty {
        while inFlight < Self.maximumInFlight, !queue.isEmpty {
          let item = queue.removeFirst()
          publish { $0.currentTitle = item.title }
          inFlight += 1
          group.addTask {
            do {
              try await self.mirror(
                item, catalogStore: catalogStore, processedDirectory: processedDirectory)
              return (item, nil)
            } catch {
              return (item, error)
            }
          }
        }
        guard let (item, failure) = await group.next() else { break }
        inFlight -= 1
        publish {
          if let failure { $0.failures.append((item.title, failure.localizedDescription)) }
          $0.completed += 1
        }
      }
    }
  }

  /// Returns the run-scoped client for a connection, creating it on first use.
  private func client(for connection: StorytellerConnection) throws -> StorytellerClient {
    if let cached = clients[connection.id] { return cached }
    let connectionID = connection.id
    let client = try StorytellerClient(origin: connection.origin) {
      try await StorytellerConnectionStore.shared.token(connectionID)
    }
    clients[connectionID] = client
    return client
  }

  private nonisolated func mirror(
    _ item: Item, catalogStore: BookCatalogStore, processedDirectory: URL
  ) async throws {
    let remote = item.remote
    let connections = try await StorytellerConnectionStore.shared.connections()
    guard let connection = connections.first(where: { $0.id == remote.connectionID }) else {
      throw BookJobError.invalidRequest("the Storyteller connection for this book is gone")
    }
    guard connection.permissions.bookDownload else {
      throw BookJobError.invalidRequest(
        "the \(connection.displayName) account cannot download ebook sources")
    }
    guard remote.asset(.ebook)?.state == .ready else {
      throw BookJobError.invalidRequest("Storyteller has no ready ebook for this title")
    }
    let client = try await client(for: connection)
    let staging = FileManager.default.temporaryDirectory
      .appendingPathComponent("spokenfolio-mirror-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: staging) }
    let downloaded = staging.appendingPathComponent("source.epub")
    let downloadedAsset = try await client.downloadAsset(
      bookID: remote.remoteBookID, format: .ebook, to: downloaded, maximumBytes: 1 << 30)

    let imported = try await Task.detached {
      let sha256 = try BookFileDigest.sha256(downloaded)
      let size = try BookFileDigest.size(downloaded)
      let publication = try EPUBImporter().load(url: downloaded)
      let plan = try AudiobookPlanner.plan(publication: publication)
      return (sha256, size, plan.metadata)
    }.value
    let record = try await BookProcessRequestBuilder.resolveCatalog(
      store: catalogStore, sourceURL: downloaded,
      sourceSHA256: imported.0, sourceSize: imported.1,
      title: imported.2.title, author: imported.2.author,
      language: imported.2.language, publisher: imported.2.publisher,
      publicationDate: imported.2.date, identifiers: imported.2.identifiers,
      outputDirectory: processedDirectory)
    // Link the mirrored record to its remote edition so the row merges.
    // The download itself is the proof: the bytes on disk came from the
    // server's ebook asset, so a receipt records that the local EPUB and the
    // remote copy are identical (kept honest later by the row builder's
    // metadata cross-checks and the Verify action's hash probes).
    let ebookReceipt = remote.asset(.ebook).map { asset in
      BookCatalogRemoteReceipt(
        format: LibraryRemoteFormat.ebook.rawValue,
        localSHA256: imported.0,
        remoteAssetID: asset.assetID.uuidString.lowercased(),
        remoteSize: downloadedAsset.byteCount,
        remoteFingerprint: asset.fingerprint,
        remoteSHA256: downloadedAsset.serverSHA256 ?? imported.0)
    }
    _ = try await LibraryAPIController.persistLink(
      record, remoteID: remote.remoteBookID, connectionID: remote.connectionID,
      evidence: .userConfirmed, catalogStore: catalogStore,
      addingReceipts: ebookReceipt.map { [$0] } ?? [])
  }
}

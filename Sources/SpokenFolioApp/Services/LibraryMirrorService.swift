import AudiobookKit
import BookJobKit
import EPUBKit
import Foundation
import LibraryKit
import StorytellerKit

/// Downloads Storyteller books into the local Book Library ("mirroring").
/// Each requested format is fetched and stored in the book's folder: the
/// EPUB imports through the digest-verified pipeline and establishes the
/// catalog record; human-narrated audiobook and readaloud downloads are
/// cataloged as human products alongside it. Every download records a proof
/// receipt, so downloaded slots can show verified. The Book Library is meant
/// to hold everything for a book.
///
/// One drain worker runs at most three books in flight at once: enough
/// parallelism to hide per-book network latency when mirroring 100+ books,
/// while still bounding pressure on the remote server and the local importer.
actor LibraryMirrorService {
  /// One book to mirror, plus which remote formats to pull down. The EPUB is
  /// always required to establish the local catalog record; human audiobook
  /// and readaloud are optional downloads stored alongside it.
  struct Item: Sendable {
    let rowID: String
    let title: String
    let remote: LibraryRemoteBookSnapshot
    var formats: Set<LibraryRemoteFormat> = [.ebook]
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
  /// Row IDs with a download child currently in flight. Dedup covers the
  /// queue AND these, so re-enqueuing a book that is mid-download can never
  /// spawn a second task racing on the same book folder.
  private var active: Set<String> = []
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
    let inProgress = Set(queue.map(\.rowID)).union(active)
    let fresh = items.filter { !inProgress.contains($0.rowID) }
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
          active.insert(item.rowID)
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
        active.remove(item.rowID)
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
    let client = try await client(for: connection)
    let staging = FileManager.default.temporaryDirectory
      .appendingPathComponent("spokenfolio-mirror-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: staging) }

    // The EPUB establishes (or finds) the local catalog record every other
    // downloaded format attaches to. It is required, and is skipped only
    // when the book is already cataloged locally.
    var record: BookCatalogRecord
    if let existing = try await existingRecord(remote: remote, catalogStore: catalogStore) {
      record = existing
    } else {
      guard remote.asset(.ebook)?.state == .ready else {
        throw BookJobError.invalidRequest("Storyteller has no ready ebook for this title")
      }
      let downloaded = staging.appendingPathComponent("source.epub")
      let asset = try await client.downloadAsset(
        bookID: remote.remoteBookID, format: .ebook, to: downloaded, maximumBytes: 1 << 30)
      let imported = try await Task.detached {
        let sha256 = try BookFileDigest.sha256(downloaded)
        let size = try BookFileDigest.size(downloaded)
        let publication = try EPUBImporter().load(url: downloaded)
        let plan = try AudiobookPlanner.plan(publication: publication)
        return (sha256, size, plan.metadata)
      }.value
      record = try await BookProcessRequestBuilder.resolveCatalog(
        store: catalogStore, sourceURL: downloaded,
        sourceSHA256: imported.0, sourceSize: imported.1,
        title: imported.2.title, author: imported.2.author,
        language: imported.2.language, publisher: imported.2.publisher,
        publicationDate: imported.2.date, identifiers: imported.2.identifiers,
        outputDirectory: processedDirectory)
      // Persist the link (with the ebook proof receipt) NOW, before the
      // large human downloads. The link is the identity anchor
      // `existingRecord` matches on, so a failure during a later download
      // never forces the EPUB to be re-fetched on retry.
      let ebookReceipt = remote.asset(.ebook).map {
        Self.receipt(.ebook, localSHA256: imported.0, remote: $0, downloaded: asset)
      }
      record = try await mergeLink(
        record, remote: remote, catalogStore: catalogStore,
        receipts: ebookReceipt.map { [$0] } ?? [])
    }

    // Human-narrated downloads: fetch each requested format straight into the
    // book folder (downloadAsset commits atomically and verifies the server
    // hash), catalog the product, then merge its proof receipt.
    for format in [LibraryRemoteFormat.audiobook, .readaloud]
    where item.formats.contains(format) {
      guard let remoteAsset = remote.asset(format), remoteAsset.state == .ready else { continue }
      let kind: BookProductKind = format == .audiobook ? .humanAudiobook : .humanReadAloudEPUB
      if record.product(kind) != nil { continue }
      let ext = format == .audiobook
        ? Self.audiobookExtension(remoteAsset.filepath) : "epub"
      let destination = format == .audiobook
        ? record.layout.humanAudiobook(extension: ext) : record.layout.humanReadAloud
      let asset = try await client.downloadAsset(
        bookID: remote.remoteBookID, format: storytellerFormat(format), to: destination,
        maximumBytes: 4 << 30)
      let sha256 = try BookFileDigest.sha256(destination)
      let size = try BookFileDigest.size(destination)
      record = try await catalogStore.reconcile(
        catalogID: record.id,
        product: BookCatalogProduct(
          kind: kind, path: destination.path, size: size, sha256: sha256, verifiedAt: Date()))
      record = try await mergeLink(
        record, remote: remote, catalogStore: catalogStore,
        receipts: [Self.receipt(format, localSHA256: sha256, remote: remoteAsset, downloaded: asset)])
    }
  }

  /// Merges proof receipts into the book's remote link, retrying once against
  /// a fresh revision if a concurrent writer (e.g. a delivery child) bumped it
  /// meanwhile — a benign optimistic-lock conflict must not fail the download.
  private nonisolated func mergeLink(
    _ record: BookCatalogRecord, remote: LibraryRemoteBookSnapshot,
    catalogStore: BookCatalogStore, receipts: [BookCatalogRemoteReceipt]
  ) async throws -> BookCatalogRecord {
    do {
      return try await LibraryAPIController.persistLink(
        record, remoteID: remote.remoteBookID, connectionID: remote.connectionID,
        evidence: .userConfirmed, catalogStore: catalogStore, addingReceipts: receipts)
    } catch {
      guard
        let fresh = try await catalogStore.scan().records.first(where: { $0.id == record.id })
      else { throw error }
      return try await LibraryAPIController.persistLink(
        fresh, remoteID: remote.remoteBookID, connectionID: remote.connectionID,
        evidence: .userConfirmed, catalogStore: catalogStore, addingReceipts: receipts)
    }
  }

  private nonisolated func existingRecord(
    remote: LibraryRemoteBookSnapshot, catalogStore: BookCatalogStore
  ) async throws -> BookCatalogRecord? {
    try await catalogStore.scan().records.first {
      $0.remoteLinks.contains {
        $0.providerID == "storyteller" && $0.connectionID == remote.connectionID
          && $0.remoteBookID == remote.remoteBookID.uuidString.lowercased()
      }
    }
  }

  private nonisolated static func receipt(
    _ format: LibraryRemoteFormat, localSHA256: String,
    remote: LibraryRemoteAssetSnapshot, downloaded: StorytellerDownloadedAsset
  ) -> BookCatalogRemoteReceipt {
    BookCatalogRemoteReceipt(
      format: format.rawValue,
      localSHA256: localSHA256,
      remoteAssetID: remote.assetID.uuidString.lowercased(),
      remoteSize: downloaded.byteCount,
      remoteFingerprint: remote.fingerprint,
      remoteSHA256: downloaded.serverSHA256 ?? localSHA256)
  }

  /// The extension for a downloaded human audiobook, taken from the server's
  /// own filepath so playback apps recognize the container.
  private nonisolated static func audiobookExtension(_ filepath: String?) -> String {
    guard let filepath, let ext = filepath.split(separator: ".").last, ext.count <= 5 else {
      return "m4b"
    }
    return String(ext).lowercased()
  }

  private nonisolated func storytellerFormat(_ format: LibraryRemoteFormat) -> StorytellerFormat {
    switch format {
    case .ebook: .ebook
    case .audiobook: .audiobook
    case .readaloud: .readaloud
    }
  }
}

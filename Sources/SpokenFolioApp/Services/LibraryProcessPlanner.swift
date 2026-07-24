import AudiobookKit
import BookJobKit
import EPUBKit
import Foundation
import LibraryKit
import StorytellerKit

/// The Library "Process Books" engine, extracted from the GUI sheet so the
/// web API queues the identical jobs: source resolution (including the
/// download-from-Storyteller backfill), per-book settings, delivery
/// resolution with the single-book match-review flow, and batch enqueue.
enum LibraryProcessPlanner {
  struct Book: Sendable {
    enum Source: Sendable {
      case cataloged(BookCatalogRecord)
      case download(LibraryRemoteBookSnapshot)
    }
    let id: String
    let title: String
    let author: String?
    let source: Source
    let hasAudiobook: Bool
    let hasReadAloud: Bool
    let audiobookNarration: BookJobRequest.Narration?
    let audiobookAlignsDirectly: Bool
    let remote: LibraryRemoteBookSnapshot?
  }

  struct Plan: Sendable {
    var books: [Book] = []
    var skipped: [(title: String, reason: String)] = []
  }

  struct Toggles: Sendable {
    var createMissingAudiobooks: Bool
    var recreateExistingAudiobooks: Bool
    var createMissingReadAlouds: Bool
    var recreateExistingReadAlouds: Bool
    var sendToStoryteller: Bool
    var deliveryConnectionID: UUID?
    var sendEPUB: Bool
    var sendM4B: Bool
    var sendReadAloud: Bool
    var confirmedRemoteBookID: UUID?
  }

  struct SharedSettings: Sendable {
    var voiceID: String
    var bitrateKbps: Int
    var workers: Int
    var announceTitles: Bool
    var paragraphPause: Double
    var chapterPause: Double
    var readAloudBitrateKbps: Int
    var readAloudASREngineID: String
    var readAloudASRModelID: String
  }

  enum Outcome: Sendable {
    case queued(count: Int, failures: [(title: String, reason: String)])
    case review(candidates: [StorytellerMatchCandidate])
  }

  /// Splits rows into processable books and skipped rows — the sheet's init.
  static func plan(rows: [StudioLibraryRow]) -> Plan {
    var result = Plan()
    for row in rows {
      if let record = row.record {
        let audiobook = record.product(.m4b)
        result.books.append(
          Book(
            id: row.id, title: row.title, author: row.author,
            source: .cataloged(record),
            hasAudiobook: audiobook != nil,
            hasReadAloud: record.product(.readAloudEPUB) != nil,
            audiobookNarration: audiobook?.narration,
            audiobookAlignsDirectly: audiobook?.narration?.announceTitles == false,
            remote: row.remote))
      } else if let remote = row.remote, remote.asset(.ebook)?.state == .ready {
        result.books.append(
          Book(
            id: row.id, title: row.title, author: row.author,
            source: .download(remote),
            hasAudiobook: false, hasReadAloud: false,
            audiobookNarration: nil, audiobookAlignsDirectly: false, remote: remote))
      } else {
        result.skipped.append(
          (row.title, "No local EPUB, and Storyteller has no ready ebook to download."))
      }
    }
    return result
  }

  /// The sheet's performQueue, verbatim semantics, with a progress callback
  /// instead of observable phase state.
  static func execute(
    books: [Book], toggles: Toggles, settings shared: SharedSettings,
    connections: [StorytellerConnection],
    catalogStore: BookCatalogStore,
    voices: [VoiceDescriptorLite],
    processedDirectory: URL,
    configuredWorkDirectory: String?,
    scheduler: JobSchedulerService,
    progress: @Sendable (String) -> Void
  ) async throws -> Outcome {
    var requests: [BookJobRequest] = []
    var failures: [(String, String)] = []
    var requestTitles: [UUID: String] = [:]
    let batchID = books.count > 1 ? UUID() : nil

    let deliveryConnection = toggles.sendToStoryteller
      ? connections.first(where: { $0.id == toggles.deliveryConnectionID })
      : nil
    if toggles.sendToStoryteller, deliveryConnection == nil {
      throw BookJobError.invalidRequest("Select a Storyteller connection for delivery.")
    }

    for book in books {
      do {
        progress("Preparing \(book.title)…")
        let catalog = try await resolveSource(
          for: book, connections: connections, catalogStore: catalogStore,
          processedDirectory: processedDirectory, progress: progress)
        let settings = makeSettings(
          for: book, toggles: toggles, shared: shared, voices: voices,
          configuredWorkDirectory: configuredWorkDirectory)
        var delivery: BookProcessSettings.Delivery?
        var workingCatalog = catalog
        if let connection = deliveryConnection {
          var products = Set<BookProductKind>()
          if toggles.sendEPUB { products.insert(.sourceEPUB) }
          if toggles.sendM4B,
            book.hasAudiobook || settings.createReadAloud || toggles.createMissingAudiobooks
          {
            products.insert(.m4b)
          }
          if toggles.sendReadAloud, book.hasReadAloud || settings.createReadAloud {
            products.insert(.readAloudEPUB)
          }
          if products.isEmpty {
            failures.append((book.title, "No products selected for delivery."))
            continue
          }
          if let confirmed = toggles.confirmedRemoteBookID, books.count == 1 {
            delivery = .init(
              connectionID: connection.id, remoteBookID: confirmed, products: products)
            try await persistConfirmedLink(
              catalog: workingCatalog, connectionID: connection.id,
              remoteBookID: confirmed, catalogStore: catalogStore)
          } else {
            progress("Matching \(book.title) on \(connection.displayName)…")
            switch try await BookProcessRequestBuilder.resolveDelivery(
              catalog: workingCatalog, catalogStore: catalogStore,
              connection: connection, products: products)
            {
            case .resolved(let value, let updated):
              delivery = value
              if let updated { workingCatalog = updated }
            case .review(let candidates):
              if books.count == 1 {
                return .review(candidates: candidates)
              }
              failures.append(
                (book.title, "Storyteller has similar editions; review the match individually."))
              continue
            }
          }
        }

        let needsSynthesis = bookNeedsSynthesis(book, toggles: toggles)
        let narrationOverride = !needsSynthesis ? book.audiobookNarration : nil
        let request = try BookProcessRequestBuilder.request(
          catalog: workingCatalog, settings: settings, delivery: delivery,
          narrationOverride: narrationOverride, batchID: batchID)
        requestTitles[request.id] = book.title
        requests.append(request)
      } catch {
        failures.append((book.title, error.localizedDescription))
      }
    }

    guard !requests.isEmpty else {
      return .queued(count: 0, failures: failures)
    }
    for index in requests.indices {
      requests[index].batchOrdinal = batchID == nil ? nil : index
      requests[index].batchCount = batchID == nil ? nil : requests.count
    }
    progress("Adding to the durable queue…")
    let enqueueFailures = await scheduler.enqueue(requests)
    for request in requests {
      if let message = enqueueFailures[request.id] {
        failures.append((requestTitles[request.id] ?? "Book", message))
      }
    }
    let queued = requests.count { enqueueFailures[$0.id] == nil }
    return .queued(count: queued, failures: failures)
  }

  /// A voice's identity fields without depending on the full descriptor.
  struct VoiceDescriptorLite: Sendable {
    let voiceID: String
    let modelRevision: String?
    let voiceRevision: String?
  }

  static func bookNeedsSynthesis(_ book: Book, toggles: Toggles) -> Bool {
    let wantsReadAloud = (toggles.createMissingReadAlouds && !book.hasReadAloud)
      || (toggles.recreateExistingReadAlouds && book.hasReadAloud)
    if !book.hasAudiobook { return toggles.createMissingAudiobooks || wantsReadAloud }
    if toggles.recreateExistingAudiobooks { return true }
    return wantsReadAloud && !book.audiobookAlignsDirectly
  }

  private static func makeSettings(
    for book: Book, toggles: Toggles, shared: SharedSettings,
    voices: [VoiceDescriptorLite], configuredWorkDirectory: String?
  ) -> BookProcessSettings {
    let selectedVoice = voices.first { $0.voiceID == shared.voiceID }
    let wantsReadAloud = (toggles.createMissingReadAlouds && !book.hasReadAloud)
      || (toggles.recreateExistingReadAlouds && book.hasReadAloud)
    return BookProcessSettings(
      voiceID: shared.voiceID,
      voiceModelRevision: selectedVoice?.modelRevision,
      voiceRevision: selectedVoice?.voiceRevision,
      bitrateKbps: shared.bitrateKbps, workers: shared.workers,
      announceTitles: shared.announceTitles,
      paragraphPauseSeconds: shared.paragraphPause,
      chapterPauseSeconds: shared.chapterPause,
      createReadAloud: wantsReadAloud,
      recreateReadAloud: toggles.recreateExistingReadAlouds && book.hasReadAloud,
      reprocessAudiobook: toggles.recreateExistingAudiobooks && book.hasAudiobook,
      readAloudBitrateKbps: shared.readAloudBitrateKbps,
      readAloudASREngineID: shared.readAloudASREngineID,
      readAloudASRModelID: shared.readAloudASRModelID,
      language: nil, workDirectory: configuredWorkDirectory)
  }

  private static func resolveSource(
    for book: Book, connections: [StorytellerConnection],
    catalogStore: BookCatalogStore, processedDirectory: URL,
    progress: @Sendable (String) -> Void
  ) async throws -> BookCatalogRecord {
    switch book.source {
    case .cataloged(let record):
      return record
    case .download(let remote):
      guard let connection = connections.first(where: { $0.id == remote.connectionID }) else {
        throw BookJobError.invalidRequest("the Storyteller connection for this book is gone")
      }
      guard connection.permissions.bookDownload else {
        throw BookJobError.invalidRequest(
          "the \(connection.displayName) account cannot download ebook sources")
      }
      progress("Downloading \(book.title)…")
      let token = try await StorytellerConnectionStore.shared.token(connection.id)
      let client = try StorytellerClient(origin: connection.origin, tokenProvider: { token })
      let staging = FileManager.default.temporaryDirectory
        .appendingPathComponent("spokenfolio-download-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: staging) }
      let downloaded = staging.appendingPathComponent("source.epub")
      try await client.downloadEbook(bookID: remote.remoteBookID, to: downloaded)

      progress("Importing \(book.title)…")
      let imported = try await Task.detached {
        let sha256 = try BookFileDigest.sha256(downloaded)
        let size = try BookFileDigest.size(downloaded)
        let publication = try EPUBImporter().load(url: downloaded)
        let plan = try AudiobookPlanner.plan(publication: publication)
        return (sha256, size, plan.metadata)
      }.value
      return try await BookProcessRequestBuilder.resolveCatalog(
        store: catalogStore, sourceURL: downloaded,
        sourceSHA256: imported.0, sourceSize: imported.1,
        title: imported.2.title, author: imported.2.author,
        language: imported.2.language, publisher: imported.2.publisher,
        publicationDate: imported.2.date, identifiers: imported.2.identifiers,
        outputDirectory: processedDirectory)
    }
  }

  static func persistConfirmedLink(
    catalog: BookCatalogRecord, connectionID: UUID, remoteBookID: UUID,
    catalogStore: BookCatalogStore
  ) async throws {
    var updated = catalog
    let previous = updated.remoteLinks.first {
      $0.providerID == "storyteller" && $0.connectionID == connectionID
    }
    updated.upsertRemoteLink(
      .init(
        providerID: "storyteller", connectionID: connectionID,
        remoteBookID: remoteBookID.uuidString.lowercased(),
        evidence: .userConfirmed,
        linkedAt: previous?.linkedAt ?? Date(),
        lastObservedAt: previous?.lastObservedAt,
        remoteTitle: previous?.remoteTitle,
        remoteAuthors: previous?.remoteAuthors ?? [],
        receipts: previous?.receipts ?? [],
        excludedRemoteBookIDs: previous?.excludedRemoteBookIDs ?? []))
    if updated != catalog {
      try await catalogStore.update(updated, expectedRevision: catalog.revision)
    }
  }
}

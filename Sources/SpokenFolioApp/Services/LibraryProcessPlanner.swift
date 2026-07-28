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
    let remoteNarration: NarrationProvenance

    var record: BookCatalogRecord? {
      if case .cataloged(let record) = source { return record }
      return nil
    }
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
    /// Row IDs whose whole-book replacement the user explicitly acknowledged
    /// after seeing the loss manifest. A book whose delivery target is
    /// occupied with different content is queued only when listed here.
    var replaceAcknowledgedRowIDs: Set<String> = []
    /// Declared provenance of the delivered ReadAloud ("human" or
    /// "spokenFolioTTS"); recorded as an assertion after delivery.
    var assertNarration: String? = nil
  }

  struct SharedSettings: Sendable {
    var backendID: String
    var modelID: String
    var voiceID: String
    var pacePreset: Int?
    var expressivityPreset: Int?
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

  /// The remote assets a send would replace for one book: only formats that
  /// are being sent AND occupied with content that is not provably
  /// identical. Each is replaced individually through Storyteller's own
  /// replace-asset API after user acknowledgment; nothing else on the book
  /// is touched.
  struct ReplacementImpact: Sendable {
    struct Asset: Sendable {
      let format: String
      let assetID: UUID
      let size: UInt64?
      let sha256: String?
      let fingerprint: String?
      /// True when this is an audiobook/readaloud slot and the remote
      /// narration is asserted human.
      let humanNarration: Bool
    }
    let rowID: String
    let title: String
    let remoteBookID: UUID
    let remoteNarration: NarrationProvenance
    let assets: [Asset]

    /// The confirmation snapshots the durable request carries: each
    /// acknowledged asset re-verifies against its snapshot immediately
    /// before being replaced.
    var expectedRemoteAssets: [BookJobRequest.StorytellerDelivery.ExpectedRemoteAsset] {
      assets.map {
        .init(
          format: $0.format, assetID: $0.assetID, size: $0.size, sha256: $0.sha256,
          fingerprint: $0.fingerprint)
      }
    }

    var replaceFormats: [String] { assets.map(\.format) }

    var losesHumanAudio: Bool { assets.contains(where: \.humanNarration) }
  }

  private static func productKind(_ format: LibraryRemoteFormat) -> BookProductKind {
    switch format {
    case .ebook: .sourceEPUB
    case .audiobook: .m4b
    case .readaloud: .readAloudEPUB
    }
  }

  /// The products a delivery for this book would carry — one authority shared
  /// by `execute` and the occupancy planning so the warning can never diverge
  /// from what is actually sent.
  static func plannedProducts(book: Book, toggles: Toggles) -> Set<BookProductKind> {
    guard toggles.sendToStoryteller else { return [] }
    let wantsReadAloud = (toggles.createMissingReadAlouds && !book.hasReadAloud)
      || (toggles.recreateExistingReadAlouds && book.hasReadAloud)
    var products = Set<BookProductKind>()
    if toggles.sendEPUB { products.insert(.sourceEPUB) }
    if toggles.sendM4B, book.hasAudiobook || wantsReadAloud || toggles.createMissingAudiobooks {
      products.insert(.m4b)
    }
    if toggles.sendReadAloud, book.hasReadAloud || wantsReadAloud {
      products.insert(.readAloudEPUB)
    }
    return products
  }

  /// Computes the loss manifest for one book, or nil when the delivery fits
  /// the plain fill-if-missing path (free slots, or occupied slots whose
  /// content is provably identical via a receipt or the snapshot hash).
  static func replacementImpact(book: Book, toggles: Toggles) -> ReplacementImpact? {
    guard toggles.sendToStoryteller, let connectionID = toggles.deliveryConnectionID,
      let remote = book.remote, remote.connectionID == connectionID
    else { return nil }
    let sent = plannedProducts(book: book, toggles: toggles)
    guard !sent.isEmpty else { return nil }

    let record = book.record
    let link = record?.remoteLinks.first {
      $0.providerID == "storyteller" && $0.connectionID == connectionID
    }
    // Content that is sent unchanged (an existing product this job will not
    // recreate) can be proven identical; anything synthesized fresh cannot.
    var stableLocalSHA: [BookProductKind: String] = [:]
    if let sha = record?.product(.sourceEPUB)?.sha256 { stableLocalSHA[.sourceEPUB] = sha }
    if book.hasAudiobook, !toggles.recreateExistingAudiobooks,
      let sha = record?.product(.m4b)?.sha256
    {
      stableLocalSHA[.m4b] = sha
    }
    if book.hasReadAloud, !toggles.recreateExistingReadAlouds,
      let sha = record?.product(.readAloudEPUB)?.sha256
    {
      stableLocalSHA[.readAloudEPUB] = sha
    }
    // Only an AVAILABLE remote asset occupies a slot — the same predicate
    // the delivery child applies (a broken or still-processing server-side
    // asset is fillable, not replaceable).
    let occupied = remote.assets.filter { $0.state == .ready }
    func provablyIdentical(_ asset: LibraryRemoteAssetSnapshot) -> Bool {
      let kind = productKind(asset.format)
      guard let localSHA = stableLocalSHA[kind] else { return false }
      if let remoteSHA = asset.sha256 { return remoteSHA == localSHA }
      guard let receipt = link?.receipts.first(where: { $0.format == asset.format.rawValue })
      else { return false }
      return receipt.localSHA256 == localSHA
        && receipt.remoteAssetID?.lowercased() == asset.assetID.uuidString.lowercased()
    }
    let assets = occupied.compactMap { asset -> ReplacementImpact.Asset? in
      guard sent.contains(productKind(asset.format)), !provablyIdentical(asset) else {
        return nil
      }
      let receipt = link?.receipts.first {
        $0.format == asset.format.rawValue
          && $0.remoteAssetID?.lowercased() == asset.assetID.uuidString.lowercased()
      }
      return .init(
        format: asset.format.rawValue, assetID: asset.assetID,
        size: asset.fileSize, sha256: asset.sha256 ?? receipt?.remoteSHA256,
        fingerprint: asset.fingerprint,
        humanNarration: asset.format != .ebook && book.remoteNarration == .human)
    }
    guard !assets.isEmpty else { return nil }
    return ReplacementImpact(
      rowID: book.id, title: book.title, remoteBookID: remote.remoteBookID,
      remoteNarration: book.remoteNarration, assets: assets)
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
            remote: row.remote, remoteNarration: row.narration))
      } else if let remote = row.remote, remote.asset(.ebook)?.state == .ready {
        result.books.append(
          Book(
            id: row.id, title: row.title, author: row.author,
            source: .download(remote),
            hasAudiobook: false, hasReadAloud: false,
            audiobookNarration: nil, audiobookAlignsDirectly: false, remote: remote,
            remoteNarration: row.narration))
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
        let needsSynthesis = bookNeedsSynthesis(book, toggles: toggles)
        let settings = try makeSettings(
          for: book, toggles: toggles, shared: shared, voices: voices,
          configuredWorkDirectory: configuredWorkDirectory,
          requiresSelectedVoice: needsSynthesis)
        var delivery: BookProcessSettings.Delivery?
        var workingCatalog = catalog
        if let connection = deliveryConnection {
          let products = plannedProducts(book: book, toggles: toggles)
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

        if var resolved = delivery {
          if let impact = replacementImpact(book: book, toggles: toggles),
            impact.remoteBookID == resolved.remoteBookID
          {
            guard toggles.replaceAcknowledgedRowIDs.contains(book.id) else {
              failures.append(
                (
                  book.title,
                  "Storyteller already has different content for this book; "
                    + "review the loss manifest and acknowledge the replacement first."
                ))
              continue
            }
            resolved.replaceFormats = impact.replaceFormats
            resolved.expectedRemoteAssets = impact.expectedRemoteAssets
          }
          if resolved.products.contains(.readAloudEPUB) {
            resolved.assertNarration = toggles.assertNarration
          }
          delivery = resolved
        }

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
    let backendID: String
    let modelID: String
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

  static func makeSettings(
    for book: Book, toggles: Toggles, shared: SharedSettings,
    voices: [VoiceDescriptorLite], configuredWorkDirectory: String?,
    requiresSelectedVoice: Bool
  ) throws -> BookProcessSettings {
    let selectedVoice = voices.first {
      $0.backendID == shared.backendID && $0.modelID == shared.modelID
        && $0.voiceID == shared.voiceID
    }
    if requiresSelectedVoice, selectedVoice == nil {
      throw BookJobError.invalidRequest("selected TTS voice is unavailable")
    }
    let wantsReadAloud = (toggles.createMissingReadAlouds && !book.hasReadAloud)
      || (toggles.recreateExistingReadAlouds && book.hasReadAloud)
    return BookProcessSettings(
      backendID: shared.backendID, modelID: shared.modelID,
      pacePreset: shared.pacePreset, expressivityPreset: shared.expressivityPreset,
      voiceID: shared.voiceID, voiceModelRevision: selectedVoice?.modelRevision,
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
      // `/files` is a `bookRead` route upstream, not `bookDownload`.
      guard connection.permissions.bookRead else {
        throw BookJobError.invalidRequest(
          "the \(connection.displayName) account cannot read book files")
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

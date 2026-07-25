import AudiobookKit
import BookJobKit
import EPUBKit
import Foundation
import LibraryKit
import StorytellerKit
import Vapor

/// `/api/library` — rows assembled by the same `LibraryRowBuilder` the
/// desktop uses, plus the library mutations. Reads serve the current
/// durable snapshot; `refresh` additionally fetches the selected
/// connection's live inventory.
struct LibraryAPIController: RouteCollection {
  func boot(routes: any RoutesBuilder) throws {
    let api = routes.grouped("api").grouped(WebAPIErrorMiddleware())
    api.get("library", use: list)
    api.post("library", "refresh", use: refresh)
    api.post("library", "narration", use: assertNarration)
    api.post("library", "process", "plan", use: processPlan)
    api.post("library", "process", "queue", use: processQueue)
    api.post("library", "quality-check", use: qualityCheck)
    api.put("library", "editions", ":recordID", "identifier", use: saveIdentifier)
    api.post("library", "match", "find", use: matchFind)
    api.post("library", "match", "link", use: matchLink)
    api.post("library", "match", "confirm-suggested", use: matchConfirmSuggested)
    api.post("library", "match", "decline-suggested", use: matchDeclineSuggested)
    api.delete("library", "match", use: matchForget)
    api.post("library", "remote-readaloud", use: remoteReadAloud)
    api.post("library", "verify-remote", use: verifyRemote)
    api.post("library", "mirror", use: startMirror)
    api.get("library", "mirror", use: mirrorStatus)
    api.on(.POST, "library", "upload", body: .stream, use: uploadBook)
    api.get("library", "asin", "search", use: asinSearch)
    api.get("library", "asin", "resolve", use: asinResolve)
  }

  private func studio(_ req: Request) throws -> StudioServices {
    guard let services = req.application.studioServices else {
      throw WebAPIError.studioUnavailable
    }
    return services
  }

  private func connectionID(_ req: Request) -> UUID? {
    (try? req.query.get(String.self, at: "connection")).flatMap(UUID.init(uuidString:))
  }

  @Sendable func list(req: Request) async throws -> LibraryDTO {
    let services = try studio(req)
    return try await Self.assemble(
      services: services, connectionID: connectionID(req), refreshRemote: false)
  }

  @Sendable func refresh(req: Request) async throws -> LibraryDTO {
    let services = try studio(req)
    return try await Self.assemble(
      services: services, connectionID: connectionID(req), refreshRemote: true)
  }

  @Sendable func assertNarration(req: Request) async throws -> LibraryDTO {
    struct Body: Content {
      let rowIDs: [String]
      let provenance: String
    }
    let services = try studio(req)
    let body = try req.content.decode(Body.self)
    guard let provenance = NarrationProvenance(rawValue: body.provenance) else {
      throw WebAPIError.badRequest("invalid_provenance", "unknown narration provenance")
    }
    let connection = connectionID(req)
    let assembled = try await Self.assemble(
      services: services, connectionID: connection, refreshRemote: false, rowsOnly: true)
    let library = try services.makeLibraryStore()
    // Same precondition as the desktop Narration menu: silently skipping
    // rows would let a bulk assertion claim more than it did.
    let selected = body.rowIDs.compactMap { id in
      assembled.internalRows.first { $0.id == id }
    }
    guard !selected.isEmpty,
      selected.allSatisfy({ $0.remote?.asset(.readaloud)?.state == .ready })
    else {
      throw WebAPIError.badRequest(
        "narration_precondition",
        "Every selected book must have a ready Storyteller ReadAloud.")
    }
    for row in selected {
      guard let remote = row.remote, let readAloud = remote.asset(.readaloud)
      else { continue }
      let existing = try library.provenance(
        connectionID: remote.connectionID, remoteBookID: remote.remoteBookID,
        remoteAssetID: readAloud.assetID)
      try library.assertProvenance(
        .init(
          connectionID: remote.connectionID, remoteBookID: remote.remoteBookID,
          remoteAssetID: readAloud.assetID, remoteSHA256: readAloud.sha256,
          provenance: provenance, coherence: existing?.coherence ?? .unknown,
          source: "user:narration"))
    }
    return try await Self.assemble(
      services: services, connectionID: connection, refreshRemote: false)
  }

  /// On-demand recheck of what is really on Storyteller for the selected
  /// books: live hash probes rewrite the delivery receipts, then the
  /// refreshed rows re-derive the per-slot server state from that evidence.
  @Sendable func verifyRemote(req: Request) async throws -> LibraryDTO {
    struct Body: Content {
      let rowIDs: [String]
    }
    let services = try studio(req)
    let body = try req.content.decode(Body.self)
    guard let connectionID = connectionID(req) else {
      throw WebAPIError.badRequest("no_connection", "select a Storyteller connection")
    }
    let connections = try await StorytellerConnectionStore.shared.connections()
    guard let connection = connections.first(where: { $0.id == connectionID }) else {
      throw WebAPIError.notFound("no Storyteller connection with that id")
    }
    let assembled = try await Self.assemble(
      services: services, connectionID: connectionID, refreshRemote: false, rowsOnly: true)
    let rows = assembled.internalRows.filter { body.rowIDs.contains($0.id) }
    let outcome = await LibraryRemoteVerificationService.verify(
      rows: rows, connection: connection,
      catalogStore: BookCatalogStore(root: AppPaths.bookCatalogRoot))
    if let failure = outcome.failures.first, outcome.checkedBooks == 0 {
      throw WebAPIError.badRequest(
        "verify_failed", "\(failure.title): \(failure.reason)")
    }
    return try await Self.assemble(
      services: services, connectionID: connectionID, refreshRemote: true)
  }

  // MARK: - Quality checks from the library

  @Sendable func qualityCheck(req: Request) async throws -> QualityQueueDTO {
    struct Body: Content {
      let rowIDs: [String]
      let scope: String
    }
    let services = try studio(req)
    let body = try req.content.decode(Body.self)
    let assembled = try await Self.assemble(
      services: services, connectionID: connectionID(req), refreshRemote: false,
      rowsOnly: true)
    var targets: [LibraryReadAloudAuditTarget] = []
    for row in assembled.internalRows where body.rowIDs.contains(row.id) {
      if body.scope != "storyteller", row.localReadAloudReady,
        let productID = row.localReadAloudProductID
      {
        let target = LibraryReadAloudAuditTarget.localProduct(productID)
        if !targets.contains(target) { targets.append(target) }
      }
      if body.scope != "local", let remote = row.remote,
        let asset = remote.asset(.readaloud), asset.state == .ready
      {
        let target = LibraryReadAloudAuditTarget.remote(
          connectionID: remote.connectionID, bookID: remote.remoteBookID,
          assetID: asset.assetID)
        if !targets.contains(target) { targets.append(target) }
      }
    }
    _ = services.quality.enqueue(targets, mode: .standard)
    return QualityAPIController.queueDTO(services.quality.currentSnapshot)
  }

  // MARK: - Edition identity

  @Sendable func saveIdentifier(req: Request) async throws -> LibraryDTO {
    struct Body: Content {
      let kind: String?
      let isbn: String?
      let value: String?
      let pushToStoryteller: Bool
    }
    let services = try studio(req)
    guard let recordID = req.parameters.get("recordID", as: UUID.self) else {
      throw WebAPIError.badRequest("invalid_id", "the record id is not a UUID")
    }
    let body = try req.content.decode(Body.self)
    let kind = body.kind ?? "isbn"
    let rawValue = body.value ?? body.isbn ?? ""
    if kind == "asin" {
      // Validation and persistence live in LibraryIdentifierEditor, shared
      // with the desktop inspector so the rules cannot diverge.
      guard let canonical = LibraryIdentifierEditor.canonicalASIN(rawValue) else {
        throw WebAPIError.badRequest(
          "invalid_asin", "Enter a valid 10-character ASIN (letters and digits).")
      }
      let connection = connectionID(req)
      let catalogStore = BookCatalogStore(root: AppPaths.bookCatalogRoot)
      let record = try await loadRecord(recordID, catalogStore: catalogStore)
      _ = record
      try LibraryIdentifierEditor.saveASIN(
        canonical, editionID: recordID, library: services.makeLibraryStore())
      return try await Self.assemble(
        services: services, connectionID: connection, refreshRemote: false)
    }
    guard let canonical = CanonicalPublicationIdentifier(kind: "isbn", value: rawValue),
      canonical.kind == .isbn13
    else {
      throw WebAPIError.badRequest(
        "invalid_isbn", "Enter a valid ISBN-10 or ISBN-13, including its check digit.")
    }
    let connection = connectionID(req)
    let catalogStore = BookCatalogStore(root: AppPaths.bookCatalogRoot)
    let records = try await catalogStore.scan().records
    guard let record = records.first(where: { $0.id == recordID }) else {
      throw WebAPIError.notFound("no catalog record with that id")
    }
    let library = try services.makeLibraryStore()
    try library.setEditionIdentifier(
      editionID: record.id, kind: "isbn-13", value: canonical.value,
      note: "Corrected in Library")
    if body.pushToStoryteller, let connectionID = connection {
      let connections = try await StorytellerConnectionStore.shared.connections()
      guard let storyteller = connections.first(where: { $0.id == connectionID }) else {
        throw WebAPIError.notFound("no Storyteller connection with that id")
      }
      guard storyteller.permissions.bookUpdate else {
        throw WebAPIError.badRequest(
          "missing_permission", "the Storyteller account cannot update books")
      }
      guard
        let remoteID = record.remoteLinks.first(where: {
          $0.connectionID == connectionID && $0.providerID == "storyteller"
        }).flatMap({ UUID(uuidString: $0.remoteBookID) })
      else {
        throw WebAPIError.badRequest(
          "not_linked", "this edition is not linked on the selected connection")
      }
      let token = try await StorytellerConnectionStore.shared.token(connectionID)
      let client = try StorytellerClient(
        origin: storyteller.origin, tokenProvider: { token })
      // Stock Storyteller identifier PUT is last-write-wins; read, edit,
      // write back as a best effort.
      let current = try await client.bookIdentifiers(remoteID)
      guard
        let type = try await client.identifierTypes().first(where: { $0.kind == "isbn-13" })
      else {
        throw WebAPIError.badRequest("unsupported", "Storyteller has no ISBN-13 type")
      }
      var values = current.filter {
        !($0.identifierTypeUuid == type.uuid && $0.ebookUuid == nil
          && $0.audiobookUuid == nil && $0.readaloudUuid == nil)
      }
      values.append(.init(identifierTypeUuid: type.uuid, value: canonical.value))
      try await client.replaceBookIdentifiers(remoteID, identifiers: values)
    }
    return try await Self.assemble(
      services: services, connectionID: connection, refreshRemote: false)
  }

  // MARK: - Match and link

  private func loadRecord(
    _ recordID: UUID, catalogStore: BookCatalogStore
  ) async throws -> BookCatalogRecord {
    guard
      let record = try await catalogStore.scan().records.first(where: { $0.id == recordID })
    else {
      throw WebAPIError.notFound("no catalog record with that id")
    }
    return record
  }

  @Sendable func matchFind(req: Request) async throws -> MatchFindResultDTO {
    struct Body: Content {
      let recordID: UUID
    }
    let services = try studio(req)
    _ = services
    let body = try req.content.decode(Body.self)
    guard let connectionID = connectionID(req) else {
      throw WebAPIError.badRequest("no_connection", "select a Storyteller connection")
    }
    let connections = try await StorytellerConnectionStore.shared.connections()
    guard let connection = connections.first(where: { $0.id == connectionID }) else {
      throw WebAPIError.notFound("no Storyteller connection with that id")
    }
    let catalogStore = BookCatalogStore(root: AppPaths.bookCatalogRoot)
    let record = try await loadRecord(body.recordID, catalogStore: catalogStore)
    let token = try await StorytellerConnectionStore.shared.token(connectionID)
    let client = try StorytellerClient(origin: connection.origin, tokenProvider: { token })
    let link = record.remoteLinks.first {
      $0.providerID == "storyteller" && $0.connectionID == connectionID
    }
    let localProducts = record.products.map { product in
      StorytellerLocalProductIdentity(
        format: Self.remoteFormat(product.kind), size: product.size, sha256: product.sha256)
    }
    let resolution = try await StorytellerIdentityResolver(client: client).resolve(
      local: .init(
        title: record.metadata.title, author: record.metadata.author,
        identifiers: record.metadata.identifiers, products: localProducts,
        excludedBookIDs: Set(
          link?.excludedRemoteBookIDs.compactMap(UUID.init(uuidString:)) ?? [])),
      linkedBookID: link.flatMap { UUID(uuidString: $0.remoteBookID) })
    switch resolution {
    case .linked(let id):
      _ = try await Self.persistLink(
        record, remoteID: id, connectionID: connectionID,
        evidence: link?.evidence, catalogStore: catalogStore)
      return MatchFindResultDTO(outcome: "linked", candidates: [])
    case .automatic(let id, let evidence):
      _ = try await Self.persistLink(
        record, remoteID: id, connectionID: connectionID,
        evidence: evidence == .exactAssetHash ? .exactAssetHash : .validatedIdentifier,
        catalogStore: catalogStore)
      return MatchFindResultDTO(outcome: "linked", candidates: [])
    case .create:
      let books = try await client.books()
      return MatchFindResultDTO(
        outcome: books.isEmpty ? "empty" : "review",
        candidates: books.map {
          .init(remoteBookID: $0.uuid, title: $0.title,
                authors: $0.authors.map(\.name), reason: "")
        })
    case .review(let values):
      let rankedIDs = Set(values.map(\.id))
      let remaining = try await client.books().filter { !rankedIDs.contains($0.uuid) }
      let ranked = values.map { candidate in
        MatchFindResultDTO.Candidate(
          remoteBookID: candidate.book.uuid, title: candidate.book.title,
          authors: candidate.book.authors.map(\.name),
          reason: candidate.reasons.map(\.rawValue).sorted().joined(separator: ", "))
      }
      return MatchFindResultDTO(
        outcome: "review",
        candidates: ranked + remaining.map {
          .init(remoteBookID: $0.uuid, title: $0.title,
                authors: $0.authors.map(\.name), reason: "")
        })
    }
  }

  @Sendable func matchLink(req: Request) async throws -> LibraryDTO {
    struct Body: Content {
      let recordID: UUID
      let remoteBookID: UUID
    }
    let services = try studio(req)
    let body = try req.content.decode(Body.self)
    guard let connectionID = connectionID(req) else {
      throw WebAPIError.badRequest("no_connection", "select a Storyteller connection")
    }
    let catalogStore = BookCatalogStore(root: AppPaths.bookCatalogRoot)
    let record = try await loadRecord(body.recordID, catalogStore: catalogStore)
    _ = try await Self.persistLink(
      record, remoteID: body.remoteBookID, connectionID: connectionID,
      evidence: .userConfirmed, catalogStore: catalogStore)
    return try await Self.assemble(
      services: services, connectionID: connectionID, refreshRemote: false)
  }

  @Sendable func matchConfirmSuggested(req: Request) async throws -> LibraryDTO {
    struct Body: Content {
      let rowID: String
    }
    let services = try studio(req)
    let body = try req.content.decode(Body.self)
    let connection = connectionID(req)
    let assembled = try await Self.assemble(
      services: services, connectionID: connection, refreshRemote: false, rowsOnly: true)
    guard let row = assembled.internalRows.first(where: { $0.id == body.rowID }),
      let record = row.record, let suggested = row.suggestedRemote
    else {
      throw WebAPIError.notFound("no suggested match on that row")
    }
    let catalogStore = BookCatalogStore(root: AppPaths.bookCatalogRoot)
    _ = try await Self.persistLink(
      record, remoteID: suggested.remoteBookID, connectionID: suggested.connectionID,
      evidence: .userConfirmed, catalogStore: catalogStore)
    return try await Self.assemble(
      services: services, connectionID: connection, refreshRemote: false)
  }

  @Sendable func matchDeclineSuggested(req: Request) async throws -> LibraryDTO {
    struct Body: Content {
      let rowID: String
    }
    let services = try studio(req)
    let body = try req.content.decode(Body.self)
    let connection = connectionID(req)
    let assembled = try await Self.assemble(
      services: services, connectionID: connection, refreshRemote: false, rowsOnly: true)
    guard let row = assembled.internalRows.first(where: { $0.id == body.rowID }),
      let record = row.record, let suggested = row.suggestedRemote
    else {
      throw WebAPIError.notFound("no suggested match on that row")
    }
    let catalogStore = BookCatalogStore(root: AppPaths.bookCatalogRoot)
    var updated = record
    let previous = updated.remoteLinks.first {
      $0.providerID == "storyteller" && $0.connectionID == suggested.connectionID
    }
    var exclusions = previous?.excludedRemoteBookIDs ?? []
    let excludedID = suggested.remoteBookID.uuidString.lowercased()
    if !exclusions.contains(excludedID) { exclusions.append(excludedID) }
    updated.upsertRemoteLink(
      .init(
        providerID: "storyteller", connectionID: suggested.connectionID,
        remoteBookID: previous?.remoteBookID
          ?? DeterministicBookID.make(catalogID: record.id).uuidString.lowercased(),
        evidence: previous?.evidence ?? .uploadCreated,
        linkedAt: previous?.linkedAt ?? Date(),
        lastObservedAt: previous?.lastObservedAt,
        remoteTitle: previous?.remoteTitle,
        remoteAuthors: previous?.remoteAuthors ?? [],
        receipts: previous?.receipts ?? [],
        excludedRemoteBookIDs: exclusions))
    try await catalogStore.update(updated, expectedRevision: record.revision)
    return try await Self.assemble(
      services: services, connectionID: connection, refreshRemote: false)
  }

  @Sendable func matchForget(req: Request) async throws -> LibraryDTO {
    struct Body: Content {
      let recordID: UUID
    }
    let services = try studio(req)
    let body = try req.content.decode(Body.self)
    guard let connectionID = connectionID(req) else {
      throw WebAPIError.badRequest("no_connection", "select a Storyteller connection")
    }
    let catalogStore = BookCatalogStore(root: AppPaths.bookCatalogRoot)
    let record = try await loadRecord(body.recordID, catalogStore: catalogStore)
    var updated = record
    updated.remoteLinks.removeAll {
      $0.providerID == "storyteller" && $0.connectionID == connectionID
    }
    updated.touch()
    try await catalogStore.update(updated, expectedRevision: record.revision)
    return try await Self.assemble(
      services: services, connectionID: connectionID, refreshRemote: false)
  }

  // MARK: - ASIN discovery

  @Sendable func asinSearch(req: Request) async throws -> AsinSearchDTO {
    _ = try studio(req)
    guard let title = try? req.query.get(String.self, at: "title"), !title.isEmpty else {
      throw WebAPIError.badRequest("missing_title", "a title is required to search")
    }
    let author = try? req.query.get(String.self, at: "author")
    let candidates = try await AsinCatalog.search(title: title, author: author)
    return AsinSearchDTO(
      candidates: candidates.map {
        .init(asin: $0.asin, title: $0.title, authors: $0.authors, narrators: $0.narrators)
      })
  }

  @Sendable func asinResolve(req: Request) async throws -> AsinResolveDTO {
    _ = try studio(req)
    guard let asin = try? req.query.get(String.self, at: "asin"), !asin.isEmpty else {
      throw WebAPIError.badRequest("missing_asin", "an asin is required")
    }
    let candidate = try? await AsinCatalog.resolve(asin: asin)
    return AsinResolveDTO(
      asin: asin,
      found: candidate != nil,
      title: candidate?.title,
      authors: candidate?.authors ?? [],
      narrators: candidate?.narrators ?? [])
  }

  // MARK: - Direct upload into the library

  @Sendable func uploadBook(req: Request) async throws -> LibraryDTO {
    let services = try studio(req)
    let filename = (try? req.query.get(String.self, at: "filename")) ?? "book.epub"
    guard filename.lowercased().hasSuffix(".epub") else {
      throw WebAPIError.badRequest("not_epub", "uploads must be .epub files")
    }
    let staging = FileManager.default.temporaryDirectory
      .appendingPathComponent("spokenfolio-import-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: staging, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: staging) }
    let downloaded = staging.appendingPathComponent("source.epub")
    guard
      FileManager.default.createFile(
        atPath: downloaded.path, contents: nil, attributes: [.posixPermissions: 0o600])
    else {
      throw WebAPIError(
        status: .internalServerError, code: "scratch_unwritable",
        message: "the import scratch directory is not writable")
    }
    let handle = try FileHandle(forWritingTo: downloaded)
    var written: UInt64 = 0
    do {
      for try await buffer in req.body {
        written += UInt64(buffer.readableBytes)
        guard written <= DraftImportService.maximumUploadBytes else {
          throw WebAPIError(
            status: .payloadTooLarge, code: "upload_too_large",
            message: "EPUB uploads are limited to 2 GiB")
        }
        try handle.write(contentsOf: Data(buffer.readableBytesView))
      }
      try handle.close()
    } catch {
      try? handle.close()
      throw error
    }
    try await LibraryImportService.importEPUB(at: downloaded)
    return try await Self.assemble(
      services: services, connectionID: connectionID(req), refreshRemote: false)
  }

  // MARK: - Mirroring Storyteller sources

  @Sendable func startMirror(req: Request) async throws -> MirrorStatusDTO {
    struct Body: Content {
      let rowIDs: [String]?
      let all: Bool?
    }
    let services = try studio(req)
    let body = try req.content.decode(Body.self)
    let connection = connectionID(req)
    let assembled = try await Self.assemble(
      services: services, connectionID: connection, refreshRemote: false, rowsOnly: true)
    let candidates = assembled.internalRows.filter { row in
      guard row.record == nil, let remote = row.remote,
        remote.asset(.ebook)?.state == .ready
      else { return false }
      if body.all == true { return true }
      return body.rowIDs?.contains(row.id) ?? false
    }
    let items = candidates.map { row in
      LibraryMirrorService.Item(rowID: row.id, title: row.title, remote: row.remote!)
    }
    _ = await services.mirror.enqueue(items)
    return Self.mirrorDTO(await services.mirror.currentSnapshot)
  }

  @Sendable func mirrorStatus(req: Request) async throws -> MirrorStatusDTO {
    let services = try studio(req)
    return Self.mirrorDTO(await services.mirror.currentSnapshot)
  }

  static func mirrorDTO(_ snapshot: LibraryMirrorService.Snapshot) -> MirrorStatusDTO {
    MirrorStatusDTO(
      isBusy: snapshot.isBusy,
      total: snapshot.total,
      completed: snapshot.completed,
      currentTitle: snapshot.currentTitle,
      failures: snapshot.failures.map { .init(title: $0.title, reason: $0.reason) },
      sequence: snapshot.sequence,
      connectionID: snapshot.connectionID)
  }

  // MARK: - Remote ReadAloud processing

  @Sendable func remoteReadAloud(req: Request) async throws -> LibraryDTO {
    struct Body: Content {
      let rowID: String
    }
    let services = try studio(req)
    let body = try req.content.decode(Body.self)
    let connection = connectionID(req)
    let assembled = try await Self.assemble(
      services: services, connectionID: connection, refreshRemote: false, rowsOnly: true)
    guard let row = assembled.internalRows.first(where: { $0.id == body.rowID }),
      let remote = row.remote
    else {
      throw WebAPIError.notFound("no remote book on that row")
    }
    let connections = try await StorytellerConnectionStore.shared.connections()
    guard let storyteller = connections.first(where: { $0.id == remote.connectionID })
    else {
      throw WebAPIError.notFound("the Storyteller connection for this book is gone")
    }
    guard storyteller.permissions.bookProcess else {
      throw WebAPIError.badRequest(
        "missing_permission",
        "The selected Storyteller account cannot start ReadAloud processing.")
    }
    let library = try services.makeLibraryStore()
    let intent = try library.beginRemoteReadAloudAutoAudit(
      connectionID: storyteller.id, bookID: remote.remoteBookID)
    try library.markRemoteReadAloudAutoAuditWaiting(intent.id)
    let token = try await StorytellerConnectionStore.shared.token(storyteller.id)
    let client = try StorytellerClient(origin: storyteller.origin, tokenProvider: { token })
    try await client.startReadAloudProcessing(bookID: remote.remoteBookID)
    return try await Self.assemble(
      services: services, connectionID: connection, refreshRemote: true)
  }

  static func remoteFormat(_ kind: BookProductKind) -> StorytellerFormat {
    switch kind {
    case .sourceEPUB: .ebook
    case .m4b: .audiobook
    case .readAloudEPUB: .readaloud
    }
  }

  static func persistLink(
    _ record: BookCatalogRecord, remoteID: UUID, connectionID: UUID,
    evidence: BookCatalogRemoteLink.Evidence?, catalogStore: BookCatalogStore,
    addingReceipts: [BookCatalogRemoteReceipt] = []
  ) async throws -> BookCatalogRecord {
    var updated = record
    let previous = updated.remoteLinks.first {
      $0.providerID == "storyteller" && $0.connectionID == connectionID
    }
    var mergedReceipts = Dictionary(
      uniqueKeysWithValues: (previous?.receipts ?? []).map { ($0.format, $0) })
    for receipt in addingReceipts { mergedReceipts[receipt.format] = receipt }
    updated.upsertRemoteLink(
      .init(
        providerID: "storyteller", connectionID: connectionID,
        remoteBookID: remoteID.uuidString.lowercased(),
        evidence: evidence ?? .userConfirmed,
        linkedAt: previous?.linkedAt ?? Date(),
        lastObservedAt: previous?.lastObservedAt,
        remoteTitle: previous?.remoteTitle,
        remoteAuthors: previous?.remoteAuthors ?? [],
        receipts: mergedReceipts.values.sorted { $0.format < $1.format },
        excludedRemoteBookIDs: previous?.excludedRemoteBookIDs ?? []))
    if updated != record {
      try await catalogStore.update(updated, expectedRevision: record.revision)
    }
    return updated
  }

  // MARK: - Process flow

  @Sendable func processPlan(req: Request) async throws -> ProcessPlanDTO {
    struct Body: Content {
      let rowIDs: [String]
      // Optional delivery toggles: when present, the response includes the
      // whole-book replacement loss manifests for the current selection.
      let createMissingAudiobooks: Bool?
      let recreateExistingAudiobooks: Bool?
      let createMissingReadAlouds: Bool?
      let recreateExistingReadAlouds: Bool?
      let sendToStoryteller: Bool?
      let deliveryConnectionID: UUID?
      let sendEPUB: Bool?
      let sendM4B: Bool?
      let sendReadAloud: Bool?
    }
    let services = try studio(req)
    let body = try req.content.decode(Body.self)
    let assembled = try await Self.assemble(
      services: services, connectionID: connectionID(req), refreshRemote: false,
      rowsOnly: true)
    let rows = assembled.internalRows.filter { body.rowIDs.contains($0.id) }
    let plan = LibraryProcessPlanner.plan(rows: rows)
    let appConfig = try AppConfig.load()
    let inventory = try? await SiriVoiceInventory.load(
      configuredVoice: appConfig.audiobook.defaultVoice ?? appConfig.server.defaultVoice)
    let connections = try await StorytellerConnectionStore.shared.authenticatedConnections()
    var replacements: [ProcessPlanDTO.Replacement]? = nil
    if body.sendToStoryteller == true, let deliveryConnectionID = body.deliveryConnectionID {
      let toggles = LibraryProcessPlanner.Toggles(
        createMissingAudiobooks: body.createMissingAudiobooks ?? false,
        recreateExistingAudiobooks: body.recreateExistingAudiobooks ?? false,
        createMissingReadAlouds: body.createMissingReadAlouds ?? false,
        recreateExistingReadAlouds: body.recreateExistingReadAlouds ?? false,
        sendToStoryteller: true, deliveryConnectionID: deliveryConnectionID,
        sendEPUB: body.sendEPUB ?? false, sendM4B: body.sendM4B ?? false,
        sendReadAloud: body.sendReadAloud ?? false, confirmedRemoteBookID: nil)
      replacements = plan.books.compactMap { book in
        LibraryProcessPlanner.replacementImpact(book: book, toggles: toggles).map {
          .init(
            rowID: $0.rowID, title: $0.title,
            remoteNarration: $0.remoteNarration.rawValue,
            losesHumanAudio: $0.losesHumanAudio,
            assets: $0.assets.map {
              .init(format: $0.format, humanNarration: $0.humanNarration, size: $0.size)
            })
        }
      }
    }
    return ProcessPlanDTO(
      books: plan.books.map {
        .init(
          id: $0.id, title: $0.title, author: $0.author,
          source: { if case .download = $0.source { return "download" } else { return "cataloged" } }($0),
          hasAudiobook: $0.hasAudiobook, hasReadAloud: $0.hasReadAloud,
          audiobookAlignsDirectly: $0.audiobookAlignsDirectly)
      },
      skipped: plan.skipped.map { .init(title: $0.title, reason: $0.reason) },
      defaults: .init(
        voiceID: inventory?.defaultVoiceID ?? "",
        bitrateKbps: appConfig.audiobook.defaultBitrateKbps,
        workers: appConfig.audiobook.resolvedMaxWorkers,
        announceTitles: appConfig.audiobook.announceTitles,
        paragraphPauseSeconds: appConfig.audiobook.paragraphPauseSeconds,
        chapterPauseSeconds: appConfig.audiobook.chapterPauseSeconds),
      voices: (inventory?.voices ?? []).map {
        .init(id: $0.key.voiceID, name: $0.name, language: $0.language, quality: $0.quality)
      },
      permissionWarning: inventory?.permissionWarning,
      connections: connections.map { .init(id: $0.id, label: $0.displayName) },
      replacements: replacements)
  }

  @Sendable func processQueue(req: Request) async throws -> Response {
    let services = try studio(req)
    let body = try req.content.decode(ProcessQueueRequestDTO.self)
    let assembled = try await Self.assemble(
      services: services, connectionID: connectionID(req), refreshRemote: false,
      rowsOnly: true)
    let rows = assembled.internalRows.filter { body.rowIDs.contains($0.id) }
    let plan = LibraryProcessPlanner.plan(rows: rows)
    let appConfig = try AppConfig.load()
    let inventory = try await SiriVoiceInventory.load(configuredVoice: nil)
    let connections = try await StorytellerConnectionStore.shared.authenticatedConnections()
    let settingsStore = StudioSettingsStore(url: AppPaths.studioSettingsURL)
    let processedDirectory = (try await settingsStore.load())
      .resolvedProcessedDirectory(home: FileManager.default.homeDirectoryForCurrentUser)
    let outcome = try await LibraryProcessPlanner.execute(
      books: plan.books,
      toggles: .init(
        createMissingAudiobooks: body.createMissingAudiobooks,
        recreateExistingAudiobooks: body.recreateExistingAudiobooks,
        createMissingReadAlouds: body.createMissingReadAlouds,
        recreateExistingReadAlouds: body.recreateExistingReadAlouds,
        sendToStoryteller: body.sendToStoryteller,
        deliveryConnectionID: body.deliveryConnectionID,
        sendEPUB: body.sendEPUB, sendM4B: body.sendM4B,
        sendReadAloud: body.sendReadAloud,
        confirmedRemoteBookID: body.confirmedRemoteBookID,
        replaceAcknowledgedRowIDs: Set(body.replaceAcknowledgedRowIDs ?? []),
        assertNarration: body.assertNarration),
      settings: .init(
        voiceID: body.voiceID, bitrateKbps: body.bitrateKbps, workers: body.workers,
        announceTitles: body.announceTitles,
        paragraphPause: body.paragraphPauseSeconds,
        chapterPause: body.chapterPauseSeconds,
        readAloudBitrateKbps: body.readAloudBitrateKbps,
        readAloudASREngineID: body.readAloudASREngineID,
        readAloudASRModelID: body.readAloudASRModelID ?? "large-v3-turbo"),
      connections: connections,
      catalogStore: BookCatalogStore(root: AppPaths.bookCatalogRoot),
      voices: inventory.voices.map {
        .init(
          voiceID: $0.key.voiceID, modelRevision: $0.modelRevision,
          voiceRevision: $0.voiceRevision)
      },
      processedDirectory: processedDirectory,
      configuredWorkDirectory: appConfig.audiobook.workDirectory,
      scheduler: services.jobs,
      progress: { _ in })
    switch outcome {
    case .queued(let count, let failures):
      let payload = ProcessQueueResultDTO(
        queued: count,
        failures: failures.map { .init(title: $0.title, reason: $0.reason) })
      let response = Response(status: .ok)
      try response.content.encode(payload)
      return response
    case .review(let candidates):
      let payload = ProcessReviewDTO(
        code: "storyteller_match_review",
        candidates: candidates.map {
          .init(
            remoteBookID: $0.book.uuid, title: $0.book.title,
            authors: $0.book.authors.map(\.name),
            reason: $0.reasons.map(\.rawValue).sorted().joined(separator: ", "))
        })
      let response = Response(status: .conflict)
      try response.content.encode(payload)
      response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
      return response
    }
  }

  // MARK: - Assembly

  struct Assembled {
    let dto: LibraryDTO
    let internalRows: [StudioLibraryRow]
  }

  static func assemble(
    services: StudioServices, connectionID: UUID?, refreshRemote: Bool
  ) async throws -> LibraryDTO {
    try await assemble(
      services: services, connectionID: connectionID, refreshRemote: refreshRemote,
      rowsOnly: false
    ).dto
  }

  static func assemble(
    services: StudioServices, connectionID: UUID?, refreshRemote: Bool, rowsOnly: Bool
  ) async throws -> Assembled {
    let catalogStore = BookCatalogStore(root: AppPaths.bookCatalogRoot)
    let scan = try await catalogStore.scan()
    let connections = try await StorytellerConnectionStore.shared.connections()
    let library = try services.makeLibraryStore()
    var snapshotStale = false
    var refreshError: String? = nil
    var authExpired = false
    let selected = connectionID.flatMap { id in connections.first { $0.id == id } }
    let connectionMissing = connectionID != nil && selected == nil
    if refreshRemote, let connection = selected {
      do {
        let token = try await StorytellerConnectionStore.shared.token(connection.id)
        let client = try StorytellerClient(
          origin: connection.origin, tokenProvider: { token })
        let books = try await client.books()
        _ = try library.replaceRemoteInventory(
          connectionID: connection.id,
          books: books.map { LibraryRowBuilder.snapshot($0, connectionID: connection.id) })
      } catch StorytellerAPIError.authenticationRequired {
        snapshotStale = true
        authExpired = true
        refreshError =
          "The \(connection.displayName) session expired; reconnect in Settings."
      } catch {
        snapshotStale = true
        refreshError = "Using the last Storyteller snapshot: \(error.localizedDescription)"
      }
    }
    let output = try LibraryRowBuilder.buildRows(
      library: library, records: scan.records, connectionID: selected?.id,
      snapshotStale: snapshotStale)
    let dto = LibraryDTO(
      rows: output.rows.map(Self.rowDTO),
      issues: scan.issues,
      editionGapCount: output.editionGapCount,
      snapshotStale: snapshotStale,
      error: refreshError,
      authExpired: authExpired ? true : nil,
      connections: connections.map {
        .init(id: $0.id, label: "\($0.displayName) — \($0.username)")
      },
      connectionMissing: connectionMissing ? true : nil)
    return Assembled(dto: rowsOnly ? LibraryDTO.empty : dto, internalRows: output.rows)
  }

  static func rowDTO(_ row: StudioLibraryRow) -> LibraryRowDTO {
    func slot(_ state: StudioLibraryRow.SlotState) -> String {
      switch state {
      case .verified: return "verified"
      case .present: return "present"
      case .pending: return "pending"
      case .missing: return "missing"
      }
    }
    let slots = row.slots
    let serverSlots = row.serverSlots
    func server(_ state: StudioLibraryRow.SlotServerState?) -> String? {
      switch state {
      case .verifiedCurrent: "verified"
      case .present: "present"
      case nil: nil
      }
    }
    func asset(_ format: LibraryRemoteFormat) -> LibraryRowDTO.RemoteAsset? {
      guard let remote = row.remote, let value = remote.asset(format) else { return nil }
      return .init(
        state: value.state.rawValue, sizeBytes: value.fileSize,
        status: value.status, stage: value.currentStage,
        stageProgress: value.stageProgress)
    }
    return LibraryRowDTO(
      id: row.id,
      title: row.title,
      author: row.author,
      level: row.level.rawValue,
      levelLabel: row.level.label,
      presence: row.presence.rawValue,
      narration: row.narration.rawValue,
      slots: .init(
        epub: slot(slots.epub),
        ttsAudiobook: slot(slots.ttsAudiobook),
        ttsReadAloud: slot(slots.ttsReadAloud),
        humanAudiobook: slot(slots.humanAudiobook),
        humanReadAloud: slot(slots.humanReadAloud)),
      storytellerSlots: .init(
        epub: server(serverSlots.epub),
        ttsAudiobook: server(serverSlots.ttsAudiobook),
        ttsReadAloud: server(serverSlots.ttsReadAloud),
        humanAudiobook: server(serverSlots.humanAudiobook),
        humanReadAloud: server(serverSlots.humanReadAloud)),
      ttsProvenance: row.ttsProvenance,
      localQualityVerdict: row.localQualityVerdict,
      remoteQualityVerdict: row.remoteQualityVerdict,
      updatedAt: row.updatedAt,
      inLibrary: row.record != nil,
      recordID: row.record?.id,
      localProducts: (row.record?.products ?? []).map {
        .init(kind: $0.kind.rawValue, path: $0.path, sizeBytes: $0.size)
      },
      identifiers: (row.record?.metadata.identifiers ?? []).map {
        .init(kind: $0.kind ?? "identifier", value: $0.value)
      },
      remoteEPUB: asset(.ebook),
      remoteAudiobook: asset(.audiobook),
      remoteReadAloud: asset(.readaloud),
      suggestedRemoteTitle: row.suggestedRemote?.title,
      suggestedRemoteAuthors: row.suggestedRemote?.authors ?? [],
      suggestedRemoteBookID: row.suggestedRemote?.remoteBookID,
      localReadAloudProductID: row.localReadAloudProductID,
      remoteBookID: row.remote?.remoteBookID,
      remoteReadAloudAssetID: row.remote?.asset(.readaloud)?.assetID,
      remoteReadAloudReady: row.remote?.asset(.readaloud)?.state == .ready,
      canStartRemoteReadAloud: row.remote?.asset(.ebook)?.state == .ready
        && row.remote?.asset(.audiobook)?.state == .ready
        && row.remote?.asset(.readaloud)?.state != .ready,
      hasStorytellerLink: row.record.map { record in
        row.remote.map { remote in
          record.remoteLinks.contains {
            $0.providerID == "storyteller" && $0.connectionID == remote.connectionID
          }
        } ?? false
      } ?? false)
  }
}

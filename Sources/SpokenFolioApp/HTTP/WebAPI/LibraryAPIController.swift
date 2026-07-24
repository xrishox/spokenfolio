import BookJobKit
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
    for rowID in body.rowIDs {
      guard let row = assembled.internalRows.first(where: { $0.id == rowID }),
        let remote = row.remote, let readAloud = remote.asset(.readaloud)
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

  // MARK: - Process flow

  @Sendable func processPlan(req: Request) async throws -> ProcessPlanDTO {
    struct Body: Content {
      let rowIDs: [String]
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
      connections: connections.map { .init(id: $0.id, label: $0.displayName) })
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
        confirmedRemoteBookID: body.confirmedRemoteBookID),
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
    let selected = connectionID.flatMap { id in connections.first { $0.id == id } }
    if refreshRemote, let connection = selected {
      do {
        let token = try await StorytellerConnectionStore.shared.token(connection.id)
        let client = try StorytellerClient(
          origin: connection.origin, tokenProvider: { token })
        let books = try await client.books()
        _ = try library.replaceRemoteInventory(
          connectionID: connection.id,
          books: books.map { LibraryRowBuilder.snapshot($0, connectionID: connection.id) })
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
      connections: connections.map {
        .init(id: $0.id, label: "\($0.displayName) — \($0.username)")
      })
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
      suggestedRemoteBookID: row.suggestedRemote?.remoteBookID)
  }
}

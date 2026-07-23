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

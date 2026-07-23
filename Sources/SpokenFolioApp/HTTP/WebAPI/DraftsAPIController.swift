import BookJobKit
import Foundation
import Vapor

/// `/api/drafts` — the web Create screen: streamed EPUB uploads, on-Mac
/// path imports, section toggles, and enqueueing through the exact
/// request-builder path the desktop uses.
struct DraftsAPIController: RouteCollection {
  func boot(routes: any RoutesBuilder) throws {
    let api = routes.grouped("api").grouped(WebAPIErrorMiddleware())
    api.on(.POST, "drafts", "upload", body: .stream, use: upload)
    api.post("drafts", "from-path", use: fromPath)
    api.get("drafts", use: list)
    api.get("drafts", ":id", use: detail)
    api.get("drafts", ":id", "cover", use: cover)
    api.patch("drafts", ":id", use: patch)
    api.delete("drafts", ":id", use: remove)
    api.post("drafts", ":id", "retry", use: retry)
    api.post("drafts", "queue", use: queue)
    api.get("audiobook-voices", use: audiobookVoices)
  }

  private func studio(_ req: Request) throws -> StudioServices {
    guard let services = req.application.studioServices else {
      throw WebAPIError.studioUnavailable
    }
    return services
  }

  private func draftID(_ req: Request) throws -> UUID {
    guard let id = req.parameters.get("id", as: UUID.self) else {
      throw WebAPIError.badRequest("invalid_id", "the draft id is not a UUID")
    }
    return id
  }

  // MARK: - Import

  @Sendable func upload(req: Request) async throws -> WebDraftDTO {
    let services = try studio(req)
    let filename = (try? req.query.get(String.self, at: "filename")) ?? "book.epub"
    guard filename.lowercased().hasSuffix(".epub") else {
      throw WebAPIError.badRequest("not_epub", "uploads must be .epub files")
    }
    let (id, scratchURL) = await services.drafts.allocateUpload(filename: filename)
    guard
      FileManager.default.createFile(
        atPath: scratchURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
    else {
      await services.drafts.abandonUpload(id)
      throw WebAPIError(
        status: .internalServerError, code: "scratch_unwritable",
        message: "the upload scratch directory is not writable")
    }
    let handle = try FileHandle(forWritingTo: scratchURL)
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
      await services.drafts.abandonUpload(id)
      throw error
    }
    await services.drafts.finishUpload(id)
    guard let draft = await services.drafts.draft(id) else {
      throw WebAPIError.notFound("the draft vanished during upload")
    }
    return Self.dto(draft)
  }

  @Sendable func fromPath(req: Request) async throws -> WebDraftDTO {
    struct Body: Content { let path: String }
    let services = try studio(req)
    let body = try req.content.decode(Body.self)
    let draft = try await services.drafts.createFromPath(body.path)
    return Self.dto(draft)
  }

  // MARK: - CRUD

  @Sendable func list(req: Request) async throws -> [WebDraftDTO] {
    let services = try studio(req)
    return await services.drafts.allDrafts.map(Self.dto)
  }

  @Sendable func detail(req: Request) async throws -> WebDraftDTO {
    let services = try studio(req)
    guard let draft = await services.drafts.draft(try draftID(req)) else {
      throw WebAPIError.notFound("no draft with that id")
    }
    return Self.dto(draft)
  }

  @Sendable func cover(req: Request) async throws -> Response {
    let services = try studio(req)
    guard let draft = await services.drafts.draft(try draftID(req)),
      let data = draft.coverData
    else {
      throw WebAPIError.notFound("the draft has no cover")
    }
    let response = Response(status: .ok, body: .init(data: data))
    let isPNG = data.starts(with: [0x89, 0x50, 0x4E, 0x47])
    response.headers.contentType = isPNG ? .png : .jpeg
    response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
    return response
  }

  @Sendable func patch(req: Request) async throws -> WebDraftDTO {
    struct Body: Content {
      struct SectionToggle: Content {
        let id: Int
        let included: Bool
      }
      let sections: [SectionToggle]?
    }
    let services = try studio(req)
    let id = try draftID(req)
    let body = try req.content.decode(Body.self)
    for toggle in body.sections ?? [] {
      await services.drafts.setSectionIncluded(
        id, sectionID: toggle.id, included: toggle.included)
    }
    guard let draft = await services.drafts.draft(id) else {
      throw WebAPIError.notFound("no draft with that id")
    }
    return Self.dto(draft)
  }

  @Sendable func remove(req: Request) async throws -> HTTPStatus {
    let services = try studio(req)
    await services.drafts.remove(try draftID(req))
    return .noContent
  }

  @Sendable func retry(req: Request) async throws -> WebDraftDTO {
    let services = try studio(req)
    let id = try draftID(req)
    await services.drafts.retry(id)
    guard let draft = await services.drafts.draft(id) else {
      throw WebAPIError.notFound("no draft with that id")
    }
    return Self.dto(draft)
  }

  // MARK: - Voices

  @Sendable func audiobookVoices(req: Request) async throws -> AudiobookVoicesDTO {
    _ = try studio(req)
    let configured = try? AppConfig.load().audiobook.defaultVoice
    let inventory = try await SiriVoiceInventory.load(configuredVoice: configured ?? nil)
    return AudiobookVoicesDTO(
      voices: inventory.voices.map {
        .init(
          id: $0.key.voiceID, name: $0.name, language: $0.language, quality: $0.quality)
      },
      defaultVoiceID: inventory.defaultVoiceID,
      permissionWarning: inventory.permissionWarning)
  }

  // MARK: - Queue

  @Sendable func queue(req: Request) async throws -> DraftQueueResultDTO {
    let services = try studio(req)
    let body = try req.content.decode(DraftQueueRequestDTO.self)
    guard !body.drafts.isEmpty else {
      throw WebAPIError.badRequest("empty_batch", "no drafts to queue")
    }
    let catalogStore = BookCatalogStore(root: AppPaths.bookCatalogRoot)
    let settingsStore = StudioSettingsStore(url: AppPaths.studioSettingsURL)
    let processedDirectory = (try await settingsStore.load())
      .resolvedProcessedDirectory(home: FileManager.default.homeDirectoryForCurrentUser)
    let inventory = try await SiriVoiceInventory.load(configuredVoice: nil)
    let connections = try await StorytellerConnectionStore.shared.authenticatedConnections()

    let batchID = UUID()
    var outcomes: [DraftQueueResultDTO.Outcome] = []
    var requests: [BookJobRequest] = []
    var queuedDraftIDs: [UUID] = []
    let count = body.drafts.count
    for (index, entry) in body.drafts.enumerated() {
      guard let draft = await services.drafts.draft(entry.draftID) else {
        outcomes.append(.init(draftID: entry.draftID, status: "failed", message: "unknown draft"))
        continue
      }
      guard case .ready = draft.status, let metadata = draft.metadata else {
        outcomes.append(
          .init(draftID: entry.draftID, status: "failed", message: "the draft is not ready"))
        continue
      }
      do {
        let catalog = try await BookProcessRequestBuilder.resolveCatalog(
          store: catalogStore, sourceURL: draft.sourceURL,
          sourceSHA256: draft.sourceSHA256, sourceSize: draft.sourceSize,
          title: metadata.title, author: metadata.author,
          language: metadata.language, publisher: metadata.publisher,
          publicationDate: metadata.date, identifiers: metadata.identifiers,
          outputDirectory: entry.outputDirectory.map {
            URL(fileURLWithPath: $0, isDirectory: true)
          } ?? processedDirectory)
        guard
          let voice = inventory.voices.first(where: { $0.key.voiceID == entry.voiceID })
        else {
          throw BookJobError.invalidRequest("selected Siri voice is unavailable")
        }
        let included = Set(entry.includedSections)
        let settings = BookProcessSettings(
          voiceID: entry.voiceID,
          voiceModelRevision: voice.modelRevision,
          voiceRevision: voice.voiceRevision,
          bitrateKbps: entry.bitrateKbps, workers: entry.workers,
          announceTitles: entry.createReadAloud ? false : entry.announceTitles,
          paragraphPauseSeconds: entry.paragraphPauseSeconds,
          chapterPauseSeconds: entry.chapterPauseSeconds,
          includedSectionIDs: draft.sections
            .filter { included.contains($0.id) && !$0.initiallyIncluded }
            .map { String($0.id) },
          excludedSectionIDs: draft.sections
            .filter { !included.contains($0.id) && $0.initiallyIncluded }
            .map { String($0.id) },
          createReadAloud: entry.createReadAloud,
          reprocessAudiobook: entry.reprocessAudiobook,
          readAloudBitrateKbps: entry.readAloudBitrateKbps,
          readAloudASREngineID: entry.readAloudASREngineID,
          readAloudASRModelID: entry.readAloudASRModelID ?? "large-v3-turbo",
          language: metadata.language ?? "en-US", workDirectory: nil)
        var delivery: BookProcessSettings.Delivery? = nil
        var warning: String? = nil
        var products = Set<BookProductKind>()
        if entry.sendSourceEPUB { products.insert(.sourceEPUB) }
        if entry.sendM4B { products.insert(.m4b) }
        if entry.sendReadAloud, entry.createReadAloud { products.insert(.readAloudEPUB) }
        if !products.isEmpty, let connectionID = entry.storytellerConnectionID,
          let connection = connections.first(where: { $0.id == connectionID })
        {
          switch try await BookProcessRequestBuilder.resolveDelivery(
            catalog: catalog, catalogStore: catalogStore, connection: connection,
            products: products)
          {
          case .resolved(let resolved, _):
            delivery = resolved
          case .review(let candidates):
            warning =
              "Storyteller found \(candidates.count) possible matches. Local products "
              + "will be created; send this book from Library after reviewing the match."
          }
        }
        do {
          let request = try BookProcessRequestBuilder.request(
            catalog: catalog, settings: settings, delivery: delivery,
            batchID: batchID, batchOrdinal: index + 1, batchCount: count)
          requests.append(request)
          queuedDraftIDs.append(entry.draftID)
          outcomes.append(
            .init(draftID: entry.draftID, status: "queued", message: warning))
        } catch BookProcessRequestBuilder.PlanError.nothingToDo {
          outcomes.append(
            .init(
              draftID: entry.draftID, status: "skipped",
              message: "Requested local products already exist"))
        }
      } catch {
        outcomes.append(
          .init(
            draftID: entry.draftID, status: "failed",
            message: error.localizedDescription))
      }
    }
    let failures = await services.jobs.enqueue(requests)
    if !failures.isEmpty {
      let failedRequestIDs = Set(failures.keys)
      let failedDraftIndexes = requests.enumerated()
        .filter { failedRequestIDs.contains($0.element.id) }
        .map(\.offset)
      for index in failedDraftIndexes {
        let draftID = queuedDraftIDs[index]
        if let outcomeIndex = outcomes.firstIndex(where: {
          $0.draftID == draftID && $0.status == "queued"
        }) {
          outcomes[outcomeIndex] = .init(
            draftID: draftID, status: "failed",
            message: failures[requests[index].id])
        }
      }
    }
    let succeeded = outcomes.filter { $0.status == "queued" }.map(\.draftID)
    await services.drafts.markQueued(succeeded)
    return DraftQueueResultDTO(outcomes: outcomes)
  }

  // MARK: - DTO

  static func dto(_ draft: WebDraft) -> WebDraftDTO {
    let status: (String, String?)
    switch draft.status {
    case .uploading: status = ("uploading", nil)
    case .loading: status = ("loading", nil)
    case .ready: status = ("ready", nil)
    case .invalid(let message): status = ("invalid", message)
    case .skipped(let message): status = ("skipped", message)
    case .queued: status = ("queued", nil)
    }
    return WebDraftDTO(
      id: draft.id,
      displayName: draft.displayName,
      status: status.0,
      statusMessage: status.1,
      title: draft.metadata?.title,
      author: draft.metadata?.author,
      language: draft.metadata?.language,
      chapterCount: draft.chapterCount,
      sourceSize: draft.sourceSize,
      sourceSHA256: draft.sourceSHA256.isEmpty ? nil : draft.sourceSHA256,
      hasCover: draft.coverData != nil,
      inLibrary: draft.catalogRecord != nil,
      sections: draft.sections.map {
        .init(
          id: $0.id, title: $0.title, role: $0.role,
          characterCount: $0.characterCount,
          initiallyIncluded: $0.initiallyIncluded, included: $0.included)
      })
  }
}

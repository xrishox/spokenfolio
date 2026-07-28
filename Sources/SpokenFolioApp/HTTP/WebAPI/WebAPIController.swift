import BookJobKit
import Foundation
import Vapor

/// `/api` — the WebUI's JSON surface. Registered in every mode; routes that
/// require Studio services return `studio_unavailable` when the process
/// hosts none (plain `serve`). Status and read routes never gate on engine
/// readiness so the UI stays useful in degraded startup.
struct WebAPIController: RouteCollection {
  struct TTSCatalogDTO: Content {
    let models: [TTSModelInfo]
    let voices: [VoiceInfo]
    let defaultModelID: String
    let defaultBackendID: String
    let defaultInternalModelID: String
    let defaultVoiceID: String
    let defaultPacePreset: Int?
    let defaultExpressivityPreset: Int?
  }

  func boot(routes: any RoutesBuilder) throws {
    let api = routes.grouped("api").grouped(WebAPIErrorMiddleware())
    api.get("server", use: serverStatus)
    api.get("voices", use: voices)
    api.get("tts", "catalog", use: ttsCatalog)
    api.get("queue", use: queue)
    api.get("jobs", use: jobs)
    api.get("jobs", ":id", use: jobDetail)
    api.post("jobs", "pause", use: pauseJobs)
    api.post("jobs", "resume", use: resumeJobs)
    api.post("jobs", "cancel", use: cancelJobs)
    api.post("queue", "pause", use: pauseQueue)
    api.post("queue", "resume", use: resumeQueue)
    api.post("queue", "cancel-waiting", use: cancelWaiting)
    api.post("queue", "reorder", use: reorderQueue)
    api.post("queue", "run-next", use: runNextJob)
    api.get("settings", use: settings)
    api.get("events", use: events)
  }

  private func studio(_ req: Request) throws -> StudioServices {
    guard let services = req.application.studioServices else {
      throw WebAPIError.studioUnavailable
    }
    return services
  }

  @Sendable func serverStatus(req: Request) async throws -> ServerStatusDTO {
    let health = req.application.serverHealth.state
    let config = req.application.webServerConfig
    let voiceCatalog = req.ttsService.allVoiceCatalog
    let schedulerState: String
    if let services = req.application.studioServices {
      let snapshot = await services.jobs.currentSnapshot
      schedulerState =
        snapshot.error == "Another Studio scheduler is already active."
        ? "lockedByOtherProcess" : "hosted"
    } else {
      schedulerState = "notHosted"
    }
    return ServerStatusDTO(
      health: health.rawValue,
      endpoint: "http://\(config?.host ?? "127.0.0.1"):\(config?.port ?? 8787)/v1",
      host: config?.host ?? "127.0.0.1",
      port: config?.port ?? 8787,
      voiceCount: voiceCatalog.count,
      defaultVoice: req.ttsService.defaultVoice,
      studioHosted: req.application.studioServices != nil,
      schedulerState: schedulerState,
      fullDiskAccessInstructions: health == .permissionRequired
        ? "On the Mac: System Settings → Privacy & Security → Full Disk Access → "
          + "enable SpokenFolio, then restart the server."
        : nil)
  }

  @Sendable func voices(req: Request) -> VoicesDTO {
    let catalog = req.ttsService.voiceCatalog
    return VoicesDTO(
      voices: catalog.map { .init(id: $0.id, name: $0.name, language: $0.lang) },
      defaultVoiceID: req.ttsService.defaultVoice)
  }

  @Sendable func ttsCatalog(req: Request) -> TTSCatalogDTO {
    let selection = req.ttsService.defaultSelection
    return TTSCatalogDTO(
      models: req.ttsService.modelCatalog,
      voices: req.ttsService.allVoiceCatalog,
      defaultModelID: req.ttsService.defaultModelID,
      defaultBackendID: selection.voice.backendID.rawValue,
      defaultInternalModelID: selection.voice.modelID,
      defaultVoiceID: selection.voice.voiceID,
      defaultPacePreset: selection.controls.pace?.rawValue,
      defaultExpressivityPreset: selection.controls.expressivity?.rawValue)
  }

  @Sendable func queue(req: Request) async throws -> QueueStatusDTO {
    let snapshot = try await studio(req).jobs.currentSnapshot
    return Self.queueDTO(snapshot)
  }

  @Sendable func jobs(req: Request) async throws -> [JobSummaryDTO] {
    let snapshot = try await studio(req).jobs.currentSnapshot
    let scope = (try? req.query.get(String.self, at: "scope")) ?? "all"
    return Self.jobDTOs(snapshot, scope: scope)
  }

  @Sendable func jobDetail(req: Request) async throws -> JobDetailDTO {
    let services = try studio(req)
    guard let id = req.parameters.get("id", as: UUID.self) else {
      throw WebAPIError.badRequest("invalid_id", "the job id is not a UUID")
    }
    let snapshot = await services.jobs.currentSnapshot
    guard let row = snapshot.rows.first(where: { $0.id == id }) else {
      throw WebAPIError.notFound("no job with that id")
    }
    return Self.jobDetailDTO(row, position: Self.jobDTOs(snapshot, scope: "all")
      .first(where: { $0.id == id })?.queuePosition)
  }

  @Sendable func pauseJobs(req: Request) async throws -> QueueStatusDTO {
    let services = try studio(req)
    let body = try req.content.decode(JobControlRequestDTO.self)
    await services.jobs.pauseJobs(Set(body.ids))
    return Self.queueDTO(await services.jobs.currentSnapshot)
  }

  /// Preempts the queue for one book: it moves to the front, a running
  /// heavyweight job is safely paused, and the paused job re-queues directly
  /// behind it.
  @Sendable func runNextJob(req: Request) async throws -> QueueStatusDTO {
    struct Body: Content { let id: UUID }
    let services = try studio(req)
    let body = try req.content.decode(Body.self)
    if let failure = await services.jobs.runNext(body.id) {
      throw WebAPIError(status: .conflict, code: "run_next_failed", message: failure)
    }
    return Self.queueDTO(await services.jobs.currentSnapshot)
  }

  /// Applies a new waiting-queue order. The body carries the COMPLETE set of
  /// non-running, non-terminal job ids in the desired order; a stale set is
  /// a 409 so a racing queue change is never silently misapplied.
  @Sendable func reorderQueue(req: Request) async throws -> QueueStatusDTO {
    let services = try studio(req)
    let body = try req.content.decode(JobControlRequestDTO.self)
    if let failure = await services.jobs.reorder(body.ids) {
      throw WebAPIError(status: .conflict, code: "queue_changed", message: failure)
    }
    return Self.queueDTO(await services.jobs.currentSnapshot)
  }

  @Sendable func resumeJobs(req: Request) async throws -> QueueStatusDTO {
    let services = try studio(req)
    let body = try req.content.decode(JobControlRequestDTO.self)
    await services.jobs.resumeJobs(Set(body.ids))
    return Self.queueDTO(await services.jobs.currentSnapshot)
  }

  @Sendable func cancelJobs(req: Request) async throws -> QueueStatusDTO {
    let services = try studio(req)
    let body = try req.content.decode(JobControlRequestDTO.self)
    await services.jobs.cancelJobs(Set(body.ids))
    return Self.queueDTO(await services.jobs.currentSnapshot)
  }

  @Sendable func pauseQueue(req: Request) async throws -> QueueStatusDTO {
    let services = try studio(req)
    let body = try? req.content.decode(QueuePauseRequestDTO.self)
    await services.jobs.pauseQueue(interruptActive: body?.interruptActive ?? false)
    return Self.queueDTO(await services.jobs.currentSnapshot)
  }

  @Sendable func resumeQueue(req: Request) async throws -> QueueStatusDTO {
    let services = try studio(req)
    await services.jobs.resumeQueue()
    return Self.queueDTO(await services.jobs.currentSnapshot)
  }

  @Sendable func cancelWaiting(req: Request) async throws -> QueueStatusDTO {
    let services = try studio(req)
    let body = try? req.content.decode(CancelWaitingRequestDTO.self)
    await services.jobs.cancelWaitingJobs(includeActive: body?.includeActive ?? false)
    return Self.queueDTO(await services.jobs.currentSnapshot)
  }

  @Sendable func settings(req: Request) async throws -> SettingsDTO {
    let services = try studio(req)
    return try await SettingsDTO.current(services: services)
  }

  // MARK: - SSE

  @Sendable func events(req: Request) async throws -> Response {
    let services = try studio(req)
    guard let stream = await services.events.subscribe() else {
      throw WebAPIError(
        status: .tooManyRequests, code: "too_many_streams",
        message: "The event stream limit is reached; close another WebUI tab.")
    }
    let response = Response(status: .ok)
    response.headers.replaceOrAdd(name: .contentType, value: "text/event-stream")
    response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
    response.headers.replaceOrAdd(name: .connection, value: "keep-alive")
    response.body = .init(asyncStream: { writer in
      let merged = AsyncStream<Data?> { continuation in
        let forward = Task {
          for await event in stream {
            var frame = Data("event: \(event.topic.rawValue)\ndata: ".utf8)
            frame.append(event.payload)
            frame.append(Data("\n\n".utf8))
            continuation.yield(frame)
          }
          continuation.finish()
        }
        let heartbeat = Task {
          while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(15))
            continuation.yield(Data(": heartbeat\n\n".utf8))
          }
        }
        continuation.onTermination = { _ in
          forward.cancel()
          heartbeat.cancel()
        }
      }
      do {
        for await frame in merged {
          if let frame {
            try await writer.write(.buffer(ByteBuffer(data: frame)))
          }
        }
      } catch {
        // The client went away; the stream's onTermination cancels the tasks.
      }
      try? await writer.write(.end)
    })
    return response
  }

  // MARK: - DTO assembly (shared with the event pump)

  static func queueDTO(_ snapshot: JobSchedulerSnapshot) -> QueueStatusDTO {
    QueueStatusDTO(
      isSuspended: snapshot.isSuspended,
      activeJobID: snapshot.activeJobID,
      deliveryActiveJobID: snapshot.deliveryActiveJobID,
      queuedCount: snapshot.queuedCount,
      runningCount: snapshot.runningCount,
      error: snapshot.error,
      scanIssueCount: snapshot.scanIssues.count,
      sequence: snapshot.sequence)
  }

  static func jobDTOs(_ snapshot: JobSchedulerSnapshot, scope: String) -> [JobSummaryDTO] {
    let rows: [JobSchedulerSnapshot.Row]
    switch scope {
    case "queue":
      rows = snapshot.rows.filter {
        ![.completed, .cancelled].contains($0.state.lifecycle)
      }
    case "history":
      rows = snapshot.rows.filter {
        [.completed, .cancelled].contains($0.state.lifecycle)
      }
    default:
      rows = snapshot.rows
    }
    var position = 0
    return rows.map { row in
      let waiting = ![.completed, .cancelled].contains(row.state.lifecycle)
      if waiting { position += 1 }
      return JobSummaryDTO(
        id: row.id,
        title: row.request.title,
        author: row.request.author,
        kindTitle: ProductionJobPresentation.kindTitle(row),
        statusTitle: ProductionJobPresentation.statusTitle(row),
        lifecycle: row.state.lifecycle.rawValue,
        queueDisposition: row.control.queueDisposition?.rawValue ?? "none",
        queuePosition: waiting ? position : nil,
        progress: ProductionJobPresentation.progress(row),
        createdAt: row.request.createdAt,
        updatedAt: row.state.updatedAt)
    }
  }

  static func jobDetailDTO(_ row: JobSchedulerSnapshot.Row, position: Int?) -> JobDetailDTO {
    let request = row.request
    let state = row.state
    let stages = state.stages.filter { stage in
      if stage.status != .pending { return true }
      switch stage.stage {
      case .preparation, .m4bSynthesis, .m4bAssembly, .m4bVerification:
        return request.resolvedOperation == .production
      case .readAloudAudioProcessing, .readAloudTranscription, .readAloudMarkup,
        .readAloudAlignment, .readAloudVerification:
        return request.readAloud != nil
      case .storytellerPreflight, .storytellerUpload, .storytellerReconciliation:
        return request.storyteller != nil
      }
    }
    let runtime = state.actualNarration.map { narration in
      JobRuntimeDTO(
        backendID: narration.backendID,
        modelID: narration.modelID,
        voiceID: narration.voiceID,
        voiceRevision: narration.voiceRevision,
        macOSVersion: narration.runtime?.macOSVersion,
        macOSBuild: narration.runtime?.macOSBuild,
        frameworkVersion: narration.runtime?.frameworkVersion)
    }
    var summary = jobDTOs(
      JobSchedulerSnapshot(rows: [row]), scope: "all")[0]
    summary = JobSummaryDTO(
      id: summary.id, title: summary.title, author: summary.author,
      kindTitle: summary.kindTitle, statusTitle: summary.statusTitle,
      lifecycle: summary.lifecycle, queueDisposition: summary.queueDisposition,
      queuePosition: position, progress: summary.progress,
      createdAt: summary.createdAt, updatedAt: summary.updatedAt)
    return JobDetailDTO(
      summary: summary,
      stages: stages.map {
        JobStageDTO(
          stage: $0.stage.rawValue,
          title: ProductionJobPresentation.stageTitle($0.stage),
          status: $0.status.rawValue,
          statusTitle: ProductionJobPresentation.stageStatusTitle($0.status),
          fraction: $0.fraction,
          message: $0.message)
      },
      lastError: state.lastError,
      attempt: state.attempt,
      warnings: state.warnings,
      products: state.products.map {
        JobProductDTO(
          kind: $0.kind.rawValue, path: $0.path, sizeBytes: $0.size,
          sha256: $0.sha256, verifiedAt: $0.verifiedAt)
      },
      settings: JobSettingsDTO(
        backendID: request.narration.backendID,
        modelID: request.narration.modelID,
        voiceID: request.narration.voiceID,
        pacePreset: request.narration.pacePreset,
        expressivityPreset: request.narration.expressivityPreset,
        bitrateKbps: request.narration.bitrateKbps,
        workers: request.narration.workers,
        paragraphPauseSeconds: request.narration.paragraphPauseSeconds,
        chapterPauseSeconds: request.narration.chapterPauseSeconds,
        announceTitles: request.narration.announceTitles,
        readAloudBitrateKbps: request.readAloud?.opusBitrateKbps,
        readAloudEngine: request.readAloud?.resolvedASREngineID,
        readAloudModel: request.readAloud?.resolvedASRModelID,
        storytellerConnectionName: request.storyteller.map { _ in "Storyteller" },
        storytellerProducts: request.storyteller.map {
          $0.products.map(\.rawValue).sorted()
        } ?? []),
      runtime: runtime,
      audiobookProgress: state.audiobookProgress.map {
        JobAudiobookProgressDTO(
          totalChapters: $0.totalChapters,
          totalCharacters: $0.totalCharacters,
          reusedChapters: $0.reusedChapters,
          currentChapterIndex: $0.currentChapterIndex,
          currentChapterTitle: $0.currentChapterTitle)
      },
      batch: request.batchOrdinal.flatMap { ordinal in
        request.batchCount.map { JobBatchDTO(ordinal: ordinal, count: $0) }
      },
      catalogID: request.catalogID)
  }
}

// MARK: - Application storage

struct StudioServicesKey: StorageKey {
  typealias Value = StudioServices
}

struct WebServerConfigKey: StorageKey {
  typealias Value = ServerConfig
}

extension Application {
  var studioServices: StudioServices? {
    get { storage[StudioServicesKey.self] }
    set { storage[StudioServicesKey.self] = newValue }
  }

  var webServerConfig: ServerConfig? {
    get { storage[WebServerConfigKey.self] }
    set { storage[WebServerConfigKey.self] = newValue }
  }
}

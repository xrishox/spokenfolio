import BookJobKit
import Foundation
import Vapor

/// `/api` — the WebUI's JSON surface. Registered in every mode; routes that
/// require Studio services return `studio_unavailable` when the process
/// hosts none (plain `serve`). Status and read routes never gate on engine
/// readiness so the UI stays useful in degraded startup.
struct WebAPIController: RouteCollection {
  func boot(routes: any RoutesBuilder) throws {
    let api = routes.grouped("api").grouped(WebAPIErrorMiddleware())
    api.get("server", use: serverStatus)
    api.get("voices", use: voices)
    api.get("queue", use: queue)
    api.get("jobs", use: jobs)
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
    let voiceCatalog = req.ttsService.voiceCatalog
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
      defaultVoice: config?.defaultVoice,
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
      defaultVoiceID: req.application.webServerConfig?.defaultVoice)
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

  @Sendable func settings(req: Request) async throws -> SettingsDTO {
    _ = try studio(req)
    let store = StudioSettingsStore(url: AppPaths.studioSettingsURL)
    let directory = (try await store.load()).resolvedProcessedDirectory(
      home: FileManager.default.homeDirectoryForCurrentUser)
    return SettingsDTO(
      processedDirectory: directory.path,
      capabilities: .init(
        launchAtLogin: false, revealInFinder: false, restartServer: false))
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

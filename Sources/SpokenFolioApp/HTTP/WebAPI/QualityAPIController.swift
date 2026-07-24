import Foundation
import LibraryKit
import ReadAloudKit
import StorytellerKit
import Vapor

/// `/api/quality` — the ReadAloud quality queue: artifacts with audit
/// histories, enqueueing, and cancellation, all over the process-wide
/// `QualityQueueService`.
struct QualityAPIController: RouteCollection {
  func boot(routes: any RoutesBuilder) throws {
    let api = routes.grouped("api").grouped(WebAPIErrorMiddleware())
    api.get("quality", "artifacts", use: artifacts)
    api.get("quality", "queue", use: queueStatus)
    api.post("quality", "enqueue", use: enqueue)
    api.post("quality", "cancel-current", use: cancelCurrent)
    api.post("quality", "cancel-waiting", use: cancelWaiting)
    api.post("quality", "cancel-all", use: cancelAll)
  }

  private func studio(_ req: Request) throws -> StudioServices {
    guard let services = req.application.studioServices else {
      throw WebAPIError.studioUnavailable
    }
    return services
  }

  @Sendable func artifacts(req: Request) async throws -> [QualityArtifactDTO] {
    let services = try studio(req)
    let connections = try await StorytellerConnectionStore.shared.connections()
    let store = try services.makeLibraryStore()
    let artifacts = try QualityArtifactCatalog.assemble(
      store: store, connections: connections)
    let snapshot = services.quality.currentSnapshot
    return artifacts.map { Self.dto($0, currentRunID: snapshot.currentRunID) }
  }

  @Sendable func queueStatus(req: Request) async throws -> QualityQueueDTO {
    let services = try studio(req)
    return Self.queueDTO(services.quality.currentSnapshot)
  }

  @Sendable func enqueue(req: Request) async throws -> QualityQueueDTO {
    struct Body: Content {
      let targets: [QualityTargetDTO]
      let thorough: Bool?
    }
    let services = try studio(req)
    let body = try req.content.decode(Body.self)
    let targets = try body.targets.map { try $0.domain() }
    _ = services.quality.enqueue(
      targets, mode: body.thorough == true ? .thorough : .standard)
    return Self.queueDTO(services.quality.currentSnapshot)
  }

  @Sendable func cancelCurrent(req: Request) async throws -> QualityQueueDTO {
    let services = try studio(req)
    services.quality.cancelCurrentAudit()
    return Self.queueDTO(services.quality.currentSnapshot)
  }

  @Sendable func cancelWaiting(req: Request) async throws -> QualityQueueDTO {
    struct Body: Content {
      let runIDs: [UUID]?
    }
    let services = try studio(req)
    let body = try? req.content.decode(Body.self)
    _ = services.quality.cancelWaitingAudits(body?.runIDs.map(Set.init))
    return Self.queueDTO(services.quality.currentSnapshot)
  }

  @Sendable func cancelAll(req: Request) async throws -> QualityQueueDTO {
    let services = try studio(req)
    services.quality.cancelAllAudits()
    return Self.queueDTO(services.quality.currentSnapshot)
  }

  // MARK: - DTO assembly

  static func queueDTO(_ snapshot: QualityQueueSnapshot) -> QualityQueueDTO {
    QualityQueueDTO(
      currentRunID: snapshot.currentRunID,
      isBusy: snapshot.isBusy,
      progress: snapshot.progress,
      status: snapshot.status,
      error: snapshot.error,
      revision: snapshot.revision,
      sequence: snapshot.sequence)
  }

  static func dto(
    _ artifact: QualityArtifactCatalog.Artifact, currentRunID: UUID?
  ) -> QualityArtifactDTO {
    QualityArtifactDTO(
      id: artifact.id,
      target: QualityTargetDTO(artifact.target),
      title: artifact.title,
      author: artifact.author,
      source: artifact.source,
      checkedAt: artifact.latestResult?.completedAt ?? artifact.latestResult?.updatedAt,
      history: artifact.history.map { Self.runDTO($0, currentRunID: currentRunID) })
  }

  static func runDTO(
    _ run: LibraryReadAloudAuditRun, currentRunID: UUID?
  ) -> QualityRunDTO {
    var metrics: [String: Double] = [:]
    if let data = run.metricsData,
      let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    {
      for (key, value) in decoded {
        if let number = value as? Double { metrics[key] = number }
        else if let number = value as? Int { metrics[key] = Double(number) }
      }
    }
    return QualityRunDTO(
      id: run.id,
      lifecycle: run.id == currentRunID ? "running" : run.lifecycle.rawValue,
      mode: run.mode,
      verdict: run.verdict,
      evidenceAdequacy: run.evidenceAdequacy,
      progress: run.progress,
      progressMessage: run.progressMessage,
      error: run.error,
      startedAt: run.startedAt,
      updatedAt: run.updatedAt,
      completedAt: run.completedAt,
      metrics: metrics,
      findings: run.findings.map {
        .init(
          dimension: $0.dimension, code: $0.code, verdict: $0.verdict,
          confidence: $0.confidence, summary: $0.summary,
          documentPath: nil)
      })
  }
}

/// Wire form of `LibraryReadAloudAuditTarget`.
struct QualityTargetDTO: Content {
  let kind: String
  let productID: UUID?
  let connectionID: UUID?
  let bookID: UUID?
  let assetID: UUID?
  let path: String?

  init(_ target: LibraryReadAloudAuditTarget) {
    switch target {
    case .localProduct(let id):
      kind = "local"
      productID = id
      connectionID = nil
      bookID = nil
      assetID = nil
      path = nil
    case .remote(let connection, let book, let asset):
      kind = "remote"
      productID = nil
      connectionID = connection
      bookID = book
      assetID = asset
      path = nil
    case .standalone(let value):
      kind = "standalone"
      productID = nil
      connectionID = nil
      bookID = nil
      assetID = nil
      path = value
    }
  }

  func domain() throws -> LibraryReadAloudAuditTarget {
    switch kind {
    case "local":
      guard let productID else {
        throw WebAPIError.badRequest("invalid_target", "local targets need productID")
      }
      return .localProduct(productID)
    case "remote":
      guard let connectionID, let bookID, let assetID else {
        throw WebAPIError.badRequest(
          "invalid_target", "remote targets need connectionID, bookID, assetID")
      }
      return .remote(connectionID: connectionID, bookID: bookID, assetID: assetID)
    case "standalone":
      guard let path else {
        throw WebAPIError.badRequest("invalid_target", "standalone targets need path")
      }
      return .standalone(path: path)
    default:
      throw WebAPIError.badRequest("invalid_target", "unknown target kind \(kind)")
    }
  }
}

struct QualityRunDTO: Content {
  struct Finding: Content {
    let dimension: String
    let code: String
    let verdict: String
    let confidence: String
    let summary: String
    let documentPath: String?
  }
  let id: UUID
  let lifecycle: String
  let mode: String
  let verdict: String?
  let evidenceAdequacy: String?
  let progress: Double
  let progressMessage: String?
  let error: String?
  let startedAt: Date
  let updatedAt: Date
  let completedAt: Date?
  let metrics: [String: Double]
  let findings: [Finding]
}

struct QualityArtifactDTO: Content {
  let id: String
  let target: QualityTargetDTO
  let title: String
  let author: String?
  let source: String
  let checkedAt: Date?
  let history: [QualityRunDTO]
}

struct QualityQueueDTO: Content {
  let currentRunID: UUID?
  let isBusy: Bool
  let progress: Double?
  let status: String
  let error: String?
  let revision: UInt64
  let sequence: UInt64
}

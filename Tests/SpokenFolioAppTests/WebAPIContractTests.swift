import BookJobKit
import Vapor
import XCTVapor
import XCTest

@testable import SpokenFolioApp

/// Contract tests for the `/api` and `/ui` surfaces: error envelope shape,
/// cache headers, degraded-mode servability, and the studio-unavailable
/// behavior of plain `serve`.
final class WebAPIContractTests: XCTestCase {
  private var root: URL!

  override func setUp() async throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("webapi-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDown() async throws {
    if let root { try? FileManager.default.removeItem(at: root) }
  }

  private func makeApp(studio: StudioServices? = nil) async throws -> Application {
    let app = try await Application.make(.testing)
    app.serverHealth = ServerHealth()
    app.serverHealth.setFailure(.engineUnavailable)
    app.ttsService = UnavailableTTSService(failure: .engineUnavailable)
    app.webServerConfig = ServerConfig()
    if let studio { app.studioServices = studio }
    app.middleware = Middlewares()
    app.middleware.use(OpenAIErrorMiddleware())
    try app.register(collection: WebAPIController())
    try app.register(collection: WebUIController())
    return app
  }

  private func makeStudio() -> StudioServices {
    StudioServices(
      jobs: JobSchedulerService(
        store: BookJobStore(root: root.appendingPathComponent("jobs")),
        schedulerStore: BookSchedulerStore(
          url: root.appendingPathComponent("scheduler.json")),
        schedulerLockURL: root.appendingPathComponent("scheduler.lock")),
      quality: QualityQueueService(
        databaseURL: root.appendingPathComponent("library.sqlite")),
      drafts: DraftImportService(
        catalogStore: BookCatalogStore(root: root.appendingPathComponent("catalog")),
        scratchRoot: root.appendingPathComponent("web-uploads")),
      libraryDatabaseURL: root.appendingPathComponent("library.sqlite"))
  }

  /// Studio-backed routes on a plain `serve` process return the structured
  /// 503, not a crash or an OpenAI envelope.
  func testStudioRoutesReportUnavailableWithoutServices() async throws {
    let app = try await makeApp()
    defer { Task { try? await app.asyncShutdown() } }
    try await app.test(.GET, "/api/queue") { response async in
      XCTAssertEqual(response.status, .serviceUnavailable)
      XCTAssertEqual(response.headers.first(name: .cacheControl), "no-store")
      let body = response.body.string
      XCTAssertTrue(body.contains("\"studio_unavailable\""), body)
      XCTAssertTrue(body.contains("\"error\""), body)
    }
  }

  /// Server status and voices stay servable in degraded startup — the UI
  /// must be able to show what is wrong.
  func testStatusRoutesServeInDegradedMode() async throws {
    let app = try await makeApp(studio: makeStudio())
    defer { Task { try? await app.asyncShutdown() } }
    try await app.test(.GET, "/api/server") { response async in
      XCTAssertEqual(response.status, .ok)
      XCTAssertTrue(response.body.string.contains("\"health\""), response.body.string)
    }
    try await app.test(.GET, "/api/voices") { response async in
      XCTAssertEqual(response.status, .ok)
    }
  }

  func testQueueReflectsDurableState() async throws {
    let studio = makeStudio()
    let app = try await makeApp(studio: studio)
    defer { Task { try? await app.asyncShutdown() } }
    _ = await studio.jobs.reload()
    try await app.test(.GET, "/api/queue") { response async in
      XCTAssertEqual(response.status, .ok)
      let body = response.body.string
      XCTAssertTrue(body.contains("\"isSuspended\""), body)
    }
    try await app.test(.GET, "/api/jobs?scope=queue") { response async in
      XCTAssertEqual(response.status, .ok)
      XCTAssertTrue(response.body.string.hasPrefix("["), response.body.string)
    }
  }

  /// `/` redirects to the UI; unknown assets 404 as HTML, not as the
  /// OpenAI JSON envelope; extensionless routes fall back to the shell.
  func testWebUIServing() async throws {
    let dist = root.appendingPathComponent("dist", isDirectory: true)
    try FileManager.default.createDirectory(
      at: dist.appendingPathComponent("assets"), withIntermediateDirectories: true)
    try Data("<!doctype html><title>shell</title>".utf8)
      .write(to: dist.appendingPathComponent("index.html"))
    try Data("body{}".utf8)
      .write(to: dist.appendingPathComponent("assets/app-abc123.css"))

    let app = try await Application.make(.testing)
    defer { Task { try? await app.asyncShutdown() } }
    app.middleware = Middlewares()
    app.middleware.use(OpenAIErrorMiddleware())
    try app.register(collection: WebUIController(root: dist))

    try await app.test(.GET, "/") { response async in
      XCTAssertEqual(response.status, .seeOther)
      XCTAssertEqual(response.headers.first(name: .location), "/ui/")
    }
    try await app.test(.GET, "/ui/") { response async in
      XCTAssertEqual(response.status, .ok)
      XCTAssertTrue(response.body.string.contains("shell"))
      XCTAssertEqual(response.headers.first(name: .cacheControl), "no-cache")
    }
    try await app.test(.GET, "/ui/production/queue") { response async in
      XCTAssertEqual(response.status, .ok)
      XCTAssertTrue(response.body.string.contains("shell"), "SPA fallback")
    }
    try await app.test(.GET, "/ui/assets/app-abc123.css") { response async in
      XCTAssertEqual(response.status, .ok)
      XCTAssertEqual(
        response.headers.first(name: .cacheControl),
        "public, max-age=31536000, immutable")
    }
    try await app.test(.GET, "/ui/assets/missing.js") { response async in
      XCTAssertEqual(response.status, .notFound)
      XCTAssertEqual(
        response.headers.contentType, .html, "HTML 404, not the OpenAI envelope")
    }
    try await app.test(.GET, "/ui/../secret") { response async in
      XCTAssertNotEqual(response.status, .ok)
    }
  }
}

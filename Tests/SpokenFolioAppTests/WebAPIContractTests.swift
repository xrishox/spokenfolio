import AudiobookKit
import BookJobKit
import ReadAloudKit
import TTSKit
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

  private static func inventory(recommendedWorkers: Int?) -> TTSInventoryProvider.Inventory {
    let key = VoiceKey(
      backendID: TTSBackendID(rawValue: "siri-fm"), modelID: "siri-expressive",
      voiceID: "en-US-F")
    return TTSInventoryProvider.Inventory(
      models: [
        TTSModelInfo(
          id: "siri-expressive", backendID: key.backendID.rawValue, modelID: key.modelID,
          name: "Siri Expressive", defaultVoiceID: key.voiceID,
          supportsPace: true, supportsExpressivity: true,
          recommendedAudiobookWorkers: recommendedWorkers,
          maximumAudiobookWorkers: 1)
      ],
      voices: [
        VoiceDescriptor(key: key, name: "Female", language: "en-US", quality: "premium")
      ],
      defaultModelID: "siri-expressive",
      defaultSelection: TTSVoiceSelection(
        voice: key, controls: TTSSynthesisControls(pace: .neutral, expressivity: .neutral)),
      permissionWarning: nil)
  }

  /// Every production form starts from one server-owned DTO, so the worker
  /// count and its provenance cannot differ between Create and Library
  /// Process, and ReadAloud defaults come from `ReadAloudDefaults` rather
  /// than a literal repeated per interface.
  func testProductionDefaultsCarryWorkerProvenanceAndSharedReadAloudDefaults() throws {
    var config = AudiobookConfig()
    config.maxWorkers = 0

    let recommended = ProductionDefaults(
      config: config, inventory: Self.inventory(recommendedWorkers: 1))
    XCTAssertEqual(recommended.workers, 1)
    XCTAssertEqual(recommended.workerSource, .recommended)
    XCTAssertEqual(recommended.readAloudBitrateKbps, ReadAloudDefaults.opusBitrateKbps)
    XCTAssertEqual(recommended.readAloudASREngineID, ReadAloudDefaults.asr.engine.rawValue)
    XCTAssertNil(recommended.readAloudASRModelID)
    XCTAssertEqual(recommended.backendID, "siri-fm")
    XCTAssertEqual(recommended.modelID, "siri-expressive")
    XCTAssertEqual(recommended.voiceID, "en-US-F")

    // The wire projection restates the same values; the web forms and the
    // desktop forms cannot start from different defaults.
    let dto = ProductionDefaultsDTO(defaults: recommended, connections: [])
    XCTAssertEqual(dto.workers, recommended.workers)
    XCTAssertEqual(dto.workerSource, recommended.workerSource)
    XCTAssertEqual(dto.voiceID, recommended.voiceID)
    XCTAssertEqual(dto.readAloudASREngineID, recommended.readAloudASREngineID)

    let hardware = ProductionDefaults(
      config: config, inventory: Self.inventory(recommendedWorkers: nil))
    XCTAssertEqual(
      hardware.workers, 1,
      "the hardware-derived count is still bounded by the model maximum")
    XCTAssertEqual(hardware.workerSource, .hardware)

    config.maxWorkers = 6
    let explicit = ProductionDefaults(
      config: config, inventory: Self.inventory(recommendedWorkers: 1))
    XCTAssertEqual(explicit.workers, 1, "the model maximum outranks configured workers")
    XCTAssertEqual(explicit.workerSource, .explicit)
    XCTAssertTrue(explicit.workerWarning?.contains("requested 6-worker") == true)
  }

  /// Settings the user queued with come back next time, and anything no
  /// longer valid falls back to the configured default instead of being
  /// offered again.
  func testRememberedProductionSettingsSurviveAndAreRevalidated() async throws {
    var config = AudiobookConfig()
    config.maxWorkers = 0
    let base = ProductionDefaults(
      config: config, inventory: Self.inventory(recommendedWorkers: 1))
    XCTAssertEqual(base.workers, 1)
    XCTAssertFalse(base.createReadAloud)

    let remembered = RememberedProductionSettings(
      backendID: "siri-fm", modelID: "siri-expressive", voiceID: "en-US-F",
      pacePreset: 2, expressivityPreset: 4,
      bitrateKbps: 128, workers: 6, announceTitles: false,
      paragraphPauseSeconds: 0.25, chapterPauseSeconds: 3,
      createReadAloud: true, readAloudBitrateKbps: 64,
      readAloudASREngineID: "whisper", readAloudASRModelID: "large-v3",
      storytellerConnectionID: UUID(), sendSourceEPUB: true, sendM4B: true,
      sendReadAloud: false)
    let restored = await base.applying(remembered)

    XCTAssertEqual(restored.bitrateKbps, 128)
    XCTAssertEqual(restored.workers, 1, "remembered Expressive workers are clamped")
    XCTAssertEqual(restored.workerSource, .remembered)
    XCTAssertTrue(restored.workerWarning?.contains("requested 6-worker") == true)
    XCTAssertFalse(restored.announceTitles)
    XCTAssertEqual(restored.paragraphPauseSeconds, 0.25)
    XCTAssertEqual(restored.chapterPauseSeconds, 3)
    XCTAssertTrue(restored.createReadAloud)
    XCTAssertEqual(restored.readAloudBitrateKbps, 64)
    XCTAssertEqual(restored.readAloudASREngineID, "whisper")
    XCTAssertEqual(restored.readAloudASRModelID, "large-v3")
    XCTAssertTrue(restored.sendSourceEPUB)
    XCTAssertTrue(restored.sendM4B)
    XCTAssertFalse(restored.sendReadAloud)

    // Values outside current limits are ignored rather than restored.
    var invalid = remembered
    invalid.bitrateKbps = 999
    invalid.workers = AudiobookConfig.maximumWorkers + 1
    invalid.readAloudBitrateKbps = 7
    invalid.readAloudASREngineID = "not-an-engine"
    let guarded = await base.applying(invalid)
    XCTAssertEqual(guarded.bitrateKbps, base.bitrateKbps)
    XCTAssertEqual(guarded.workers, base.workers)
    XCTAssertEqual(guarded.workerSource, base.workerSource)
    XCTAssertEqual(guarded.readAloudBitrateKbps, base.readAloudBitrateKbps)
    XCTAssertEqual(guarded.readAloudASREngineID, base.readAloudASREngineID)
  }

  /// The settings file keeps what was queued, and reading it back is what
  /// makes the next form open in the same place.
  func testRememberedSettingsRoundTripThroughTheSettingsFile() async throws {
    let url = root.appendingPathComponent("studio-settings.json")
    let store = StudioSettingsStore(url: url)
    try await store.save(StudioSettings(processedDirectory: "/tmp/books"))

    await ProductionDefaults.remember(
      backendID: "siri", modelID: "siri-private", voiceID: "voice-x",
      pacePreset: nil, expressivityPreset: nil, bitrateKbps: 64, workers: 40,
      announceTitles: true, paragraphPauseSeconds: 0.6, chapterPauseSeconds: 1.75,
      createReadAloud: true, readAloudBitrateKbps: 32,
      readAloudASREngineID: "synthesis", readAloudASRModelID: nil,
      storytellerConnectionID: nil, sendSourceEPUB: true, sendM4B: false,
      sendReadAloud: true, settingsStore: store)

    let reloaded = try await store.load()
    XCTAssertEqual(
      reloaded.processedDirectory, "/tmp/books",
      "remembering must not disturb unrelated settings")
    let last = try XCTUnwrap(reloaded.lastProduction)
    XCTAssertEqual(last.voiceID, "voice-x")
    XCTAssertEqual(last.workers, 40)
    XCTAssertTrue(last.createReadAloud)
    XCTAssertTrue(last.sendSourceEPUB)
    XCTAssertFalse(last.sendM4B)
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
    try await app.test(.GET, "/api/tts/catalog") { response async in
      XCTAssertEqual(response.status, .ok)
      let body = response.body.string
      XCTAssertTrue(body.contains("\"defaultModelID\":\"\""), body)
      XCTAssertTrue(body.contains("\"defaultBackendID\":\"unavailable\""), body)
      XCTAssertTrue(body.contains("\"defaultInternalModelID\":\"\""), body)
      XCTAssertTrue(body.contains("\"models\":[]"), body)
      XCTAssertTrue(body.contains("\"voices\":[]"), body)
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

  /// The delete routes are registered and reject malformed selections before
  /// touching any catalog state.
  func testDeleteRoutesValidateSelection() async throws {
    let studio = makeStudio()
    let app = try await makeApp(studio: studio)
    defer { Task { try? await app.asyncShutdown() } }
    try app.register(collection: LibraryAPIController())

    try await app.test(
      .POST, "/api/library/delete/plan",
      beforeRequest: { req in
        try req.content.encode(
          LibraryDeletePlanRequestDTO(rowIDs: [], slots: ["m4b"], scope: "bogus"))
      }
    ) { response async in
      XCTAssertEqual(response.status, .badRequest)
      XCTAssertTrue(response.body.string.contains("invalid_scope"), response.body.string)
    }

    try await app.test(
      .POST, "/api/library/delete/plan",
      beforeRequest: { req in
        try req.content.encode(
          LibraryDeletePlanRequestDTO(rowIDs: [], slots: [], scope: "local"))
      }
    ) { response async in
      XCTAssertEqual(response.status, .badRequest)
      XCTAssertTrue(response.body.string.contains("no_slots"), response.body.string)
    }

    // An unknown slot on the execute route is likewise rejected up front.
    try await app.test(
      .POST, "/api/library/delete",
      beforeRequest: { req in
        try req.content.encode(
          LibraryDeleteRequestDTO(
            rowIDs: [], slots: ["not_a_slot"], scope: "local", acknowledgedRowIDs: []))
      }
    ) { response async in
      XCTAssertEqual(response.status, .badRequest)
      XCTAssertTrue(response.body.string.contains("invalid_slot"), response.body.string)
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

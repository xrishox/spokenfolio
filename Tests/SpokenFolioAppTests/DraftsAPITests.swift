import BookJobKit
import EPUBKit
import Vapor
import XCTVapor
import XCTest

@testable import SpokenFolioApp

/// Contract tests for the web Create drafts: streamed upload through the
/// real import pipeline, section data, and removal.
final class DraftsAPITests: XCTestCase {
  private var root: URL!

  override func setUp() async throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("drafts-api-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDown() async throws {
    if let root { try? FileManager.default.removeItem(at: root) }
  }

  private func makeApp() async throws -> (Application, StudioServices) {
    let services = StudioServices(
      jobs: JobSchedulerService(
        store: BookJobStore(root: root.appendingPathComponent("jobs")),
        schedulerStore: BookSchedulerStore(url: root.appendingPathComponent("scheduler.json")),
        schedulerLockURL: root.appendingPathComponent("scheduler.lock")),
      quality: QualityQueueService(databaseURL: root.appendingPathComponent("library.sqlite")),
      drafts: DraftImportService(
        catalogStore: BookCatalogStore(root: root.appendingPathComponent("catalog")),
        scratchRoot: root.appendingPathComponent("web-uploads"),
        complianceToolchain: .init(epubcheck: try epubcheckStub())),
      libraryDatabaseURL: root.appendingPathComponent("library.sqlite"))
    let app = try await Application.make(.testing)
    app.serverHealth = ServerHealth()
    app.ttsService = UnavailableTTSService(failure: .engineUnavailable)
    app.webServerConfig = ServerConfig()
    app.studioServices = services
    app.middleware = Middlewares()
    try app.register(collection: DraftsAPIController())
    return (app, services)
  }

  private func epubcheckStub() throws -> URL {
    let script = root.appendingPathComponent("epubcheck")
    let body = """
      #!/bin/sh
      report=""
      while [ "$#" -gt 0 ]; do
        if [ "$1" = "--json" ]; then shift; report="$1"; fi
        shift
      done
      : > '\(root.appendingPathComponent("epubcheck-invoked").path)'
      printf '%s' '{"checker":{"checkerVersion":"test","nFatal":0,"nError":0,"nWarning":0,"nUsage":0},"publication":{"ePubVersion":"3.0"}}' > "$report"
      """
    try Data(body.utf8).write(to: script)
    XCTAssertEqual(chmod(script.path, 0o700), 0)
    return script
  }

  private func fixtureEPUB() throws -> Data {
    let source = root.appendingPathComponent("fixture-src", isDirectory: true)
    try FileManager.default.createDirectory(
      at: source.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
    try Data("application/epub+zip".utf8).write(to: source.appendingPathComponent("mimetype"))
    try Data(
      """
      <?xml version="1.0"?>
      <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
        <rootfiles><rootfile full-path="content.opf" media-type="application/oebps-package+xml"/></rootfiles>
      </container>
      """.utf8
    ).write(to: source.appendingPathComponent("META-INF/container.xml"))
    try Data(
      """
      <?xml version="1.0"?>
      <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
          <dc:identifier id="id">draft-fixture</dc:identifier>
          <dc:title>Draft Fixture</dc:title><dc:language>en</dc:language>
          <dc:creator>Testy Author</dc:creator>
        </metadata>
        <manifest>
          <item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/>
        </manifest>
        <spine><itemref idref="c1"/></spine>
      </package>
      """.utf8
    ).write(to: source.appendingPathComponent("content.opf"))
    let prose = (1...30).map { "<p>Sentence number \($0) keeps the chapter satisfyingly long.</p>" }
      .joined()
    try Data(
      """
      <html xmlns="http://www.w3.org/1999/xhtml"><head><title>One</title></head>
      <body><h1>Chapter One</h1>\(prose)</body></html>
      """.utf8
    ).write(to: source.appendingPathComponent("c1.xhtml"))
    let output = root.appendingPathComponent("fixture.epub")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    process.currentDirectoryURL = source
    process.arguments = ["-q", "-X", "-r", output.path, "."]
    try process.run()
    process.waitUntilExit()
    return try Data(contentsOf: output)
  }

  func testUploadImportsAndExposesSections() async throws {
    let (app, services) = try await makeApp()
    defer { Task { try? await app.asyncShutdown() } }
    let epub = try fixtureEPUB()

    var draftID: UUID?
    try await app.test(
      .POST, "/api/drafts/upload?filename=fixture.epub",
      beforeRequest: { req async in
        req.body = ByteBuffer(data: epub)
      },
      afterResponse: { response async in
        XCTAssertEqual(response.status, .ok, response.body.string)
        struct Partial: Decodable {
          let id: UUID
          let status: String
        }
        let dto = try? JSONDecoder().decode(Partial.self, from: response.body)
        draftID = dto?.id
      })
    let id = try XCTUnwrap(draftID)

    // The import runs asynchronously; poll the service until it settles.
    var ready = false
    for _ in 0..<200 {
      if let draft = await services.drafts.draft(id) {
        if case .ready = draft.status {
          ready = true
          break
        }
        if case .invalid(let message) = draft.status {
          return XCTFail("import failed: \(message)")
        }
      }
      try await Task.sleep(for: .milliseconds(25))
    }
    XCTAssertTrue(ready, "the upload never finished importing")
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: root.appendingPathComponent("epubcheck-invoked").path),
      "draft import must run EPUBCheck before becoming ready")

    try await app.test(.GET, "/api/drafts/\(id.uuidString)") { response async in
      XCTAssertEqual(response.status, .ok)
      let body = response.body.string
      XCTAssertTrue(body.contains("\"Draft Fixture\""), body)
      XCTAssertTrue(body.contains("\"sections\""), body)
      XCTAssertTrue(body.contains("\"ready\""), body)
    }

    try await app.test(.DELETE, "/api/drafts/\(id.uuidString)") { response async in
      XCTAssertEqual(response.status, .noContent)
    }
    let gone = await services.drafts.draft(id)
    XCTAssertNil(gone)
  }

  func testUploadRejectsNonEPUBFilename() async throws {
    let (app, _) = try await makeApp()
    defer { Task { try? await app.asyncShutdown() } }
    try await app.test(
      .POST, "/api/drafts/upload?filename=notes.txt",
      afterResponse: { response async in
        XCTAssertEqual(response.status, .badRequest)
        XCTAssertTrue(response.body.string.contains("not_epub"))
      })
  }

  func testQueueRejectsUnknownDraft() async throws {
    let (app, _) = try await makeApp()
    defer { Task { try? await app.asyncShutdown() } }
    let body = """
      {"drafts":[{"draftID":"\(UUID().uuidString)","backendID":"siri","modelID":"siri-private",
      "voiceID":"missing","pacePreset":null,"expressivityPreset":null,"bitrateKbps":256,
      "workers":4,"announceTitles":true,"paragraphPauseSeconds":0.6,
      "chapterPauseSeconds":1.75,"includedSections":[],"createReadAloud":false,
      "reprocessAudiobook":false,"readAloudBitrateKbps":32,
      "readAloudASREngineID":"synthesis","readAloudASRModelID":null,
      "storytellerConnectionID":null,"sendSourceEPUB":false,"sendM4B":false,
      "sendReadAloud":false,"outputDirectory":null}]}
      """
    try await app.test(
      .POST, "/api/drafts/queue",
      beforeRequest: { req async in
        req.headers.contentType = .json
        req.body = ByteBuffer(string: body)
      },
      afterResponse: { response async in
        XCTAssertEqual(response.status, .ok)
        XCTAssertTrue(response.body.string.contains("unknown draft"), response.body.string)
      })
  }
}

import Foundation
import XCTest

@testable import StorytellerKit

private final class StorytellerStubProtocol: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    do {
      let (response, data) = try Self.handler!(request)
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch { client?.urlProtocol(self, didFailWithError: error) }
  }
  override func stopLoading() {}
}

final class StorytellerTests: XCTestCase {
  private func book(
    id: UUID = UUID(), title: String = "Book", isbn: String? = nil,
    formats: Set<StorytellerFormat> = []
  ) -> StorytellerBook {
    func asset() -> StorytellerAsset {
      .init(uuid: UUID(), filepath: "fixture.bin", fileSize: 10)
    }
    return StorytellerBook(
      uuid: id, title: title, authors: [.init(name: "Author")],
      identifiers: isbn.map { [.init(kind: "isbn-13", value: $0)] } ?? [],
      ebook: formats.contains(.ebook) ? asset() : nil,
      audiobook: formats.contains(.audiobook) ? asset() : nil,
      readaloud: formats.contains(.readaloud) ? asset() : nil)
  }

  func testAssetAvailabilityRequiresARealDownloadableFile() {
    XCTAssertFalse(StorytellerAsset(uuid: UUID()).isAvailable)
    XCTAssertFalse(StorytellerAsset(uuid: UUID(), filepath: "book.epub").isAvailable)
    XCTAssertFalse(StorytellerAsset(uuid: UUID(), fileSize: 10).isAvailable)
    XCTAssertTrue(
      StorytellerAsset(uuid: UUID(), filepath: "book.epub", fileSize: 10).isAvailable)
  }

  func testConflictPlannerNeverTreatsIdentifierAsIdempotency() {
    let target = UUID()
    let duplicate = book(isbn: "978-1-23")
    XCTAssertEqual(
      StorytellerConflictPlanner.decide(
        targetID: target, requested: [.readaloud], books: [duplicate], expectedSnapshot: nil,
        normalizedIdentifiers: [StorytellerConflictPlanner.normalize("978-1-23")],
        normalizedTitle: "different", normalizedAuthor: nil),
      .conflict([duplicate.uuid], "an existing book has a matching identifier"))
  }

  func testEmptyNormalizedIdentifierDoesNotConflict() {
    let existing = book(isbn: "---")
    let target = UUID()
    XCTAssertEqual(
      StorytellerConflictPlanner.decide(
        targetID: target, requested: [.ebook], books: [existing], expectedSnapshot: nil,
        normalizedIdentifiers: [""], normalizedTitle: "different", normalizedAuthor: nil),
      .create(target))
  }

  func testPlannerFillsOnlyMissingFormatsAndDetectsMutation() {
    let id = UUID()
    let existing = book(id: id, formats: [.ebook])
    XCTAssertEqual(
      StorytellerConflictPlanner.decide(
        targetID: id, requested: [.ebook, .audiobook], books: [existing],
        expectedSnapshot: nil, normalizedIdentifiers: [], normalizedTitle: "book",
        normalizedAuthor: "author"),
      .fillMissing(id, [.audiobook]))
    var changed = existing
    changed.ebook?.fingerprint = "changed"
    XCTAssertEqual(
      StorytellerConflictPlanner.decide(
        targetID: id, requested: [.ebook], books: [changed],
        expectedSnapshot: .init(book: existing), normalizedIdentifiers: [],
        normalizedTitle: "book", normalizedAuthor: "author"),
      .conflict([id], "the mapped remote book changed since the last successful delivery"))
  }

  func testServerURLMustBeOrigin() async {
    XCTAssertThrowsError(
      try StorytellerClient(origin: URL(string: "http://example.com/path")!, tokenProvider: { "x" })
    )
    XCTAssertNoThrow(
      try StorytellerClient(origin: URL(string: "http://example.com:8002")!, tokenProvider: { "x" })
    )
  }

  func testDeviceAuthorizationUsesConfiguredOriginAndRetainsApprovalPath() throws {
    let authorization = StorytellerDeviceAuthorization(
      deviceCode: "device-code", userCode: "ABCD-EFGH",
      verificationURI: URL(string: "http://127.0.0.1:8001/device")!,
      verificationURIComplete: URL(
        string: "http://127.0.0.1:8001/device?device_code=device-code")!,
      expiresIn: 900, interval: 5,
      qrSVGURL: URL(string: "http://127.0.0.1:8001/api/v2/device/qr/device-code")!)

    let rebased = try authorization.rebased(to: URL(string: "http://mas:8002")!)

    XCTAssertEqual(rebased.verificationURI.absoluteString, "http://mas:8002/device")
    XCTAssertEqual(
      rebased.verificationURIComplete.absoluteString,
      "http://mas:8002/device?device_code=device-code")
    XCTAssertEqual(
      rebased.qrSVGURL.absoluteString,
      "http://mas:8002/api/v2/device/qr/device-code")
  }

  func testResumedUploadRejectsCrossOriginLocationBeforeSendingToken() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file) }
    try Data([1]).write(to: file)
    let values = try file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
    let client = try StorytellerClient(
      origin: URL(string: "https://safe.example")!, tokenProvider: { "secret" })
    let uploader = StorytellerTUSUploader(client: client)
    let state = TUSUploadState(
      uploadURL: URL(string: "https://evil.example/upload")!, offset: 0, length: 1,
      sourceSize: UInt64(values.fileSize ?? 0),
      sourceModificationDate: values.contentModificationDate)
    do {
      _ = try await uploader.upload(
        file: file, endpoint: "/upload", metadata: [:], state: state,
        onState: { _ in })
      XCTFail("cross-origin resumed URL should fail")
    } catch let error as StorytellerAPIError {
      guard case .crossOriginLocation = error else { return XCTFail("unexpected error \(error)") }
    }
  }

  func testInvalidResumedUploadBoundsFailBeforeNetwork() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file) }
    try Data([1]).write(to: file)
    let values = try file.resourceValues(forKeys: [.contentModificationDateKey])
    let client = try StorytellerClient(
      origin: URL(string: "https://safe.example")!, tokenProvider: { "secret" })
    let uploader = StorytellerTUSUploader(client: client)
    let state = TUSUploadState(
      offset: 2, length: 2, sourceSize: 1,
      sourceModificationDate: values.contentModificationDate)
    do {
      _ = try await uploader.upload(
        file: file, endpoint: "/upload", metadata: [:], state: state,
        onState: { _ in })
      XCTFail("invalid state should fail")
    } catch let error as StorytellerAPIError {
      XCTAssertEqual(error, .fileChanged)
    }
  }

  func testTUS409WithoutOffsetIsAStorytellerConflictNotOffsetDrift() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file) }
    try Data([1]).write(to: file)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StorytellerStubProtocol.self]
    let session = URLSession(configuration: configuration)
    StorytellerStubProtocol.handler = { request in
      if request.httpMethod == "POST" {
        return (
          HTTPURLResponse(
            url: request.url!, statusCode: 201, httpVersion: nil,
            headerFields: ["Location": "/upload/one"])!, Data())
      }
      return (
        HTTPURLResponse(url: request.url!, statusCode: 409, httpVersion: nil, headerFields: nil)!,
        Data("{\"message\":\"asset already exists\"}".utf8))
    }
    let client = try StorytellerClient(
      origin: URL(string: "https://safe.example")!, session: session,
      tokenProvider: { "secret" })
    let uploader = StorytellerTUSUploader(client: client, session: session)
    do {
      _ = try await uploader.upload(
        file: file, endpoint: "/upload", metadata: [:], onState: { _ in })
      XCTFail("semantic conflict should fail")
    } catch let error as StorytellerAPIError {
      guard case .rejected(409, _) = error else { return XCTFail("unexpected error \(error)") }
    }
  }

  func testTUSRechecksSourceAfterCreatingUpload() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file) }
    try Data([1]).write(to: file)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StorytellerStubProtocol.self]
    let session = URLSession(configuration: configuration)
    StorytellerStubProtocol.handler = { request in
      XCTAssertEqual(request.httpMethod, "POST")
      return (
        HTTPURLResponse(
          url: request.url!, statusCode: 201, httpVersion: nil,
          headerFields: ["Location": "/upload/one"])!, Data())
    }
    let client = try StorytellerClient(
      origin: URL(string: "https://safe.example")!, session: session,
      tokenProvider: { "secret" })
    let uploader = StorytellerTUSUploader(client: client, session: session)
    do {
      _ = try await uploader.upload(
        file: file, endpoint: "/upload", metadata: [:], onState: { _ in
          try Data([1, 2]).write(to: file)
        })
      XCTFail("changed source should fail")
    } catch let error as StorytellerAPIError {
      XCTAssertEqual(error, .fileChanged)
    }
  }

  func testDeleteAssetTargetsPerAssetEndpointAndReturnsUpdatedBook() async throws {
    let id = UUID()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StorytellerStubProtocol.self]
    let session = URLSession(configuration: configuration)
    let remaining = book(id: id, formats: [.ebook, .audiobook])  // readaloud already gone
    let encoded = try JSONEncoder().encode(remaining)
    nonisolated(unsafe) var seenMethod: String?
    nonisolated(unsafe) var seenURL: URL?
    StorytellerStubProtocol.handler = { request in
      seenMethod = request.httpMethod
      seenURL = request.url
      return (
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
        encoded)
    }
    let client = try StorytellerClient(
      origin: URL(string: "https://safe.example")!, session: session,
      tokenProvider: { "secret" })
    let updated = try await client.deleteAsset(bookID: id, format: .readaloud)

    XCTAssertEqual(seenMethod, "DELETE")
    XCTAssertEqual(
      seenURL?.path, "/api/v2/books/\(id.uuidString.lowercased())/replace-asset")
    XCTAssertEqual(seenURL?.query, "format=readaloud")
    // The updated book proves the slot is gone and the book still exists.
    XCTAssertNil(updated.asset(.readaloud))
    XCTAssertNotNil(updated.asset(.ebook))
    XCTAssertNotNil(updated.asset(.audiobook))
  }

  func testDeleteAssetSurfacesServerRejection() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StorytellerStubProtocol.self]
    let session = URLSession(configuration: configuration)
    StorytellerStubProtocol.handler = { request in
      (
        HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!,
        Data("{\"message\":\"forbidden\"}".utf8))
    }
    let client = try StorytellerClient(
      origin: URL(string: "https://safe.example")!, session: session,
      tokenProvider: { "secret" })
    do {
      _ = try await client.deleteAsset(bookID: UUID(), format: .audiobook)
      XCTFail("a rejected delete must throw")
    } catch let error as StorytellerAPIError {
      guard case .rejected(403, _) = error else { return XCTFail("unexpected error \(error)") }
    }
  }

  func testAuthenticatedRequestRejectsCrossOriginPathBeforeReadingToken() async throws {
    let client = try StorytellerClient(
      origin: URL(string: "https://safe.example")!,
      tokenProvider: { throw StorytellerAPIError.conflict("token provider was called") })
    do {
      _ = try await client.authenticatedRequest(path: "https://evil.example/steal")
      XCTFail("cross-origin path should fail")
    } catch let error as StorytellerAPIError {
      guard case .crossOriginLocation = error else { return XCTFail("unexpected error \(error)") }
    }
  }

  func testAlignmentEvidenceRoutesAreBoundedAndAuthenticated() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StorytellerStubProtocol.self]
    let session = URLSession(configuration: configuration)
    let id = UUID()
    StorytellerStubProtocol.handler = { request in
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
      if request.url?.path.hasSuffix("/transcriptions/chapter.json") == true {
        return (
          HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
          Data("{\"transcript\":\"words\",\"timeline\":[]}".utf8)
        )
      }
      XCTAssertEqual(request.url?.path, "/api/v2/reports/\(id.uuidString.lowercased())")
      return (
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
        Data("{\"transcriptions\":[\"chapter.json\"]}".utf8)
      )
    }
    let client = try StorytellerClient(
      origin: URL(string: "http://storyteller.example:8001")!, session: session,
      tokenProvider: { "token" })
    let report = try await client.alignmentReport(bookID: id)
    let transcript = try await client.retainedTranscription(
      bookID: id, filename: "chapter.json")
    XCTAssertNotNil(report)
    XCTAssertNotNil(transcript)
    do {
      _ = try await client.retainedTranscription(bookID: id, filename: "../secret")
      XCTFail("unsafe transcript path should fail")
    } catch let error as StorytellerAPIError {
      guard case .invalidResponse = error else { return XCTFail("unexpected error \(error)") }
    }
  }

  func testAudiobookDownloadIsPermitted() async throws {
    // Human audiobooks are now downloadable into the Book Library, so the
    // request proceeds far enough to consult credentials (no early reject).
    let client = try StorytellerClient(
      origin: URL(string: "http://storyteller.example:8001")!,
      tokenProvider: { throw StorytellerAPIError.conflict("token provider called") })
    do {
      _ = try await client.downloadAsset(
        bookID: UUID(), format: .audiobook,
        to: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
      XCTFail("the throwing token provider should surface")
    } catch let error as StorytellerAPIError {
      guard case .conflict(let message) = error, message == "token provider called"
      else { return XCTFail("unexpected error \(error)") }
    }
  }

  /// Stock Storyteller guards `/api/v2/books/:id/files` and
  /// `GET /api/v2/books/:id` with `bookRead`; `bookDownload` guards its own
  /// reading/sync routes. Every mutation this app performs reconciles
  /// afterward, so a missing read permission must refuse before mutating.
  func testPermissionPreflightRequiresBookReadNotBookDownload() async throws {
    func client(_ permissions: StorytellerPermissions) throws -> StorytellerClient {
      let configuration = URLSessionConfiguration.ephemeral
      configuration.protocolClasses = [StorytellerStubProtocol.self]
      let session = URLSession(configuration: configuration)
      let user = StorytellerUser(
        id: UUID(), name: nil, username: "u", email: nil, permissions: permissions)
      let encoded = try JSONEncoder().encode(user)
      StorytellerStubProtocol.handler = { request in
        (
          HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
          encoded)
      }
      return try StorytellerClient(
        origin: URL(string: "https://safe.example")!, session: session,
        tokenProvider: { "secret" })
    }

    let readable = StorytellerPermissions(
      bookCreate: false, bookDelete: false, bookDownload: false, bookList: true,
      bookProcess: false, bookRead: true, bookUpdate: true)
    _ = try await client(readable).requirePermissions(create: false, update: true)

    var withoutRead = readable
    withoutRead.bookRead = false
    withoutRead.bookDownload = true
    do {
      _ = try await client(withoutRead).requirePermissions(create: false, update: true)
      XCTFail("a mutation that reconciles afterward must refuse without bookRead")
    } catch StorytellerAPIError.missingPermission(let name) {
      XCTAssertEqual(name, "bookRead", "bookDownload must never stand in for bookRead")
    }
  }

  /// A multi-file audiobook is served as a ZIP Storyteller generates per
  /// request, so the probe's total size is the ZIP's, not the source
  /// directory's. That is not a protocol violation: the hash is simply not
  /// comparable with the source asset.
  func testGeneratedRepresentationProbeReportsUnknownRatherThanFailing() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StorytellerStubProtocol.self]
    let session = URLSession(configuration: configuration)
    let hash = String(repeating: "a", count: 64)
    StorytellerStubProtocol.handler = { request in
      (
        HTTPURLResponse(
          url: request.url!, statusCode: 206, httpVersion: nil,
          headerFields: [
            "Content-Length": "1",
            // The generated ZIP is a different size than the source directory.
            "Content-Range": "bytes 0-0/987654",
            "X-Storyteller-Hash": hash,
          ])!,
        Data([0]))
    }
    let client = try StorytellerClient(
      origin: URL(string: "https://safe.example")!, session: session,
      tokenProvider: { "secret" })

    let value = try await client.assetHash(
      bookID: UUID(), format: .audiobook, expectedSize: 12345)
    XCTAssertNil(value, "a generated representation has no comparable source hash")
  }

  /// A server that ignores Range entirely would turn identity discovery into
  /// a full audiobook download; that must still fail loudly.
  func testProbeStillRejectsAServerThatIgnoresRange() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StorytellerStubProtocol.self]
    let session = URLSession(configuration: configuration)
    StorytellerStubProtocol.handler = { request in
      (
        HTTPURLResponse(
          url: request.url!, statusCode: 200, httpVersion: nil,
          headerFields: ["Content-Length": "12345"])!,
        Data(repeating: 0, count: 32))
    }
    let client = try StorytellerClient(
      origin: URL(string: "https://safe.example")!, session: session,
      tokenProvider: { "secret" })

    do {
      _ = try await client.assetHash(
        bookID: UUID(), format: .audiobook, expectedSize: 12345)
      XCTFail("a full-body response to a one-byte probe must fail")
    } catch StorytellerAPIError.invalidResponse {}
  }

  /// Stock Storyteller zips a multi-file audiobook per request and serves
  /// `application/zip` with a `.zip` filename. Those bytes are a generated
  /// representation, not the source asset, and must be recognizable as such
  /// so nothing stores them under an audio extension.
  func testServedRepresentationIsDistinguishedFromTheSourceAsset() {
    let zip = StorytellerDownloadedAsset(
      url: URL(fileURLWithPath: "/tmp/book.zip"), byteCount: 10, sha256: "a",
      contentType: "application/zip", suggestedFilename: "The Book.zip")
    XCTAssertTrue(zip.isGeneratedArchive)
    XCTAssertEqual(zip.storedExtension(fallback: "m4b"), "zip")

    let single = StorytellerDownloadedAsset(
      url: URL(fileURLWithPath: "/tmp/book.m4b"), byteCount: 10, sha256: "a",
      contentType: "audio/mp4", suggestedFilename: "The Book.m4b")
    XCTAssertFalse(single.isGeneratedArchive)
    XCTAssertEqual(single.storedExtension(fallback: "bin"), "m4b")

    // No usable filename: the MIME type decides, then the caller's fallback.
    let typed = StorytellerDownloadedAsset(
      url: URL(fileURLWithPath: "/tmp/x"), byteCount: 10, sha256: "a",
      contentType: "application/epub+zip", suggestedFilename: nil)
    XCTAssertEqual(typed.storedExtension(fallback: "bin"), "epub")
    XCTAssertFalse(typed.isGeneratedArchive, "an EPUB is a stored file, not a generated archive")

    let unknown = StorytellerDownloadedAsset(
      url: URL(fileURLWithPath: "/tmp/x"), byteCount: 10, sha256: "a",
      contentType: "application/octet-stream", suggestedFilename: nil)
    XCTAssertEqual(unknown.storedExtension(fallback: "m4b"), "m4b")
  }

  /// The served filename is built from the book title upstream, so it is
  /// untrusted: a path separator or parent reference is discarded outright
  /// rather than sanitized into something that looks safe.
  func testContentDispositionFilenameRejectsPathEscapes() {
    XCTAssertEqual(
      StorytellerClient.filename(fromContentDisposition: "attachment; filename=\"Book.zip\""),
      "Book.zip")
    XCTAssertEqual(
      StorytellerClient.filename(
        fromContentDisposition: "attachment; filename=\"x\"; filename*=UTF-8''Caf%C3%A9.m4b"),
      "Café.m4b")
    XCTAssertNil(
      StorytellerClient.filename(fromContentDisposition: "attachment; filename=\"../../etc/x\""))
    XCTAssertNil(
      StorytellerClient.filename(fromContentDisposition: "attachment; filename=\"/abs/x.m4b\""))
    XCTAssertNil(
      StorytellerClient.filename(fromContentDisposition: "attachment; filename=\".hidden\""))
    XCTAssertNil(StorytellerClient.filename(fromContentDisposition: "attachment"))
  }

  /// A download commits under the extension the server actually served, so a
  /// generated ZIP never lands at the `.m4b` path the caller guessed.
  func testDownloadCommitsUnderTheServedExtension() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StorytellerStubProtocol.self]
    let session = URLSession(configuration: configuration)
    let payload = Data("zipped audiobook".utf8)
    StorytellerStubProtocol.handler = { request in
      (
        HTTPURLResponse(
          url: request.url!, statusCode: 200, httpVersion: nil,
          headerFields: [
            "Content-Length": "\(payload.count)",
            "Content-Type": "application/zip",
            "Content-Disposition": "attachment; filename=\"The Book.zip\"",
          ])!,
        payload)
    }
    let client = try StorytellerClient(
      origin: URL(string: "https://safe.example")!, session: session,
      tokenProvider: { "secret" })
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("mirror-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let asset = try await client.downloadAsset(
      bookID: UUID(), format: .audiobook,
      to: root.appendingPathComponent("Human Audiobook.m4b"),
      useServedExtension: true)

    XCTAssertEqual(asset.url.pathExtension, "zip")
    XCTAssertTrue(asset.isGeneratedArchive)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("Human Audiobook.m4b").path),
      "a generated ZIP must never be committed under an audio extension")
    XCTAssertEqual(asset.byteCount, UInt64(payload.count))
    XCTAssertEqual(asset.sha256.count, 64)
  }

  func testDeterministicBookIDIsStableAndVersionFive() {
    let first = DeterministicBookID.make(sourceSHA256: String(repeating: "a", count: 64))
    XCTAssertEqual(first, DeterministicBookID.make(sourceSHA256: String(repeating: "A", count: 64)))
    XCTAssertNotEqual(
      first, DeterministicBookID.make(sourceSHA256: String(repeating: "b", count: 64)))
    XCTAssertEqual(first.uuidString.split(separator: "-")[2].first, "5")
  }

  func testCanonicalIdentifiersAcceptOnlyValidatedStrongIdentifiers() {
    XCTAssertEqual(
      CanonicalPublicationIdentifier(kind: "isbn", value: "0-306-40615-2")?.value,
      "9780306406157")
    XCTAssertEqual(
      CanonicalPublicationIdentifier(kind: "doi", value: "https://doi.org/10.1000/ABC")?.value,
      "10.1000/abc")
    XCTAssertEqual(
      CanonicalPublicationIdentifier(kind: "asin", value: "B012345678")?.value,
      "B012345678")
    XCTAssertNil(CanonicalPublicationIdentifier(kind: "isbn", value: "978-1-23"))
    XCTAssertNil(CanonicalPublicationIdentifier(kind: nil, value: "some publisher id"))
  }

  func testBookDecodingRetainsNarratorsNestedIdentifiersAndMissingAssets() throws {
    let bookID = UUID()
    let assetID = UUID()
    let typeID = UUID()
    let data = try JSONSerialization.data(withJSONObject: [
      "uuid": bookID.uuidString,
      "title": "Fixture",
      "authors": [["name": "Author"]],
      "narrators": [["name": "Narrator"]],
      "identifiers": [],
      "ebook": [
        "uuid": assetID.uuidString,
        "missing": true,
        "fileSize": 123,
        "identifiers": [
          ["uuid": typeID.uuidString, "kind": "isbn-13", "value": "9780306406157"]
        ],
      ],
    ])
    let value = try JSONDecoder().decode(StorytellerBook.self, from: data)
    XCTAssertEqual(value.narrators.map(\.name), ["Narrator"])
    XCTAssertEqual(value.ebook?.identifiers.first?.effectiveValue, "9780306406157")
    XCTAssertNil(value.asset(.ebook), "assets marked missing are not usable products")
  }

  func testLiveServerWhenConfigured() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let rawURL = environment["STORYTELLER_TEST_URL"],
      let url = URL(string: rawURL),
      let token = environment["STORYTELLER_TEST_TOKEN"]
    else { throw XCTSkip("set STORYTELLER_TEST_URL and STORYTELLER_TEST_TOKEN") }
    let client = try StorytellerClient(origin: url, tokenProvider: { token })
    let user = try await client.currentUser()
    XCTAssertTrue(user.permissions.bookList)
    _ = try await client.books()
    _ = try await client.maxUploadChunkSize()
    let authorization = try await StorytellerDeviceAuth.start(origin: url)
    XCTAssertFalse(authorization.userCode.isEmpty)
    let pending = try await StorytellerDeviceAuth.pollToken(
      origin: url, deviceCode: authorization.deviceCode)
    XCTAssertNil(pending)
  }

  func testLiveReadAloudUploadWhenConfigured() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let rawURL = environment["STORYTELLER_TEST_URL"], let url = URL(string: rawURL),
      let token = environment["STORYTELLER_TEST_TOKEN"],
      let path = environment["STORYTELLER_TEST_READALOUD"]
    else {
      throw XCTSkip("set the Storyteller live-test variables including STORYTELLER_TEST_READALOUD")
    }
    let source = URL(fileURLWithPath: path)
    let bookID = UUID()
    let client = try StorytellerClient(origin: url, tokenProvider: { token })
    let baseline = try await client.books()
    let baselineIDs = Set(baseline.map(\.uuid))
    let uploader = StorytellerTUSUploader(client: client)
    do {
      _ = try await uploader.upload(
        file: source, endpoint: "/api/v2/books/upload",
        metadata: [
          "bookUuid": bookID.uuidString.lowercased(), "filename": source.lastPathComponent,
          "filetype": "application/epub+zip",
        ], onState: { _ in })
      var remote: StorytellerBook?
      for _ in 0..<30 {
        remote = try await client.books().first {
          !baselineIDs.contains($0.uuid) && $0.readaloud != nil
        }
        if remote?.readaloud != nil { break }
        try await Task.sleep(for: .milliseconds(200))
      }
      XCTAssertNotNil(
        remote?.readaloud, "an aligned EPUB uploaded alone must become a ReadAloud asset")
      XCTAssertNil(remote?.ebook)
      if let remote { try await client.deleteBooks([remote.uuid]) }
    } catch {
      let created = (try? await client.books().filter { !baselineIDs.contains($0.uuid) }) ?? []
      if !created.isEmpty { try? await client.deleteBooks(created.map(\.uuid)) }
      throw error
    }
    let remaining = try await client.books()
    XCTAssertTrue(Set(remaining.map(\.uuid)).isSubset(of: baselineIDs))
  }
}

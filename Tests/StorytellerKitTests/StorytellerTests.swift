import Foundation
import XCTest

@testable import StorytellerKit

final class StorytellerTests: XCTestCase {
  private func book(
    id: UUID = UUID(), title: String = "Book", isbn: String? = nil,
    formats: Set<StorytellerFormat> = []
  ) -> StorytellerBook {
    func asset() -> StorytellerAsset { .init(uuid: UUID(), fileSize: 10) }
    return StorytellerBook(
      uuid: id, title: title, authors: [.init(name: "Author")],
      identifiers: isbn.map { [.init(kind: "isbn-13", value: $0)] } ?? [],
      ebook: formats.contains(.ebook) ? asset() : nil,
      audiobook: formats.contains(.audiobook) ? asset() : nil,
      readaloud: formats.contains(.readaloud) ? asset() : nil)
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

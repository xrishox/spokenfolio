import BookJobKit
import Foundation
import StorytellerKit
import XCTest

@testable import SpokenFolioApp

/// Live whole-book replacement E2E against the configured Storyteller server.
/// Gated by STORYTELLER_REPLACE_E2E=1 because it mutates the remote library —
/// but only ever a disposable book this test creates (marker-titled, absent
/// from the baseline), which it deletes again in teardown. It never touches
/// an existing remote book.
final class StorytellerReplaceLiveE2ETests: XCTestCase {
  func testDisposableBookWholeReplace() async throws {
    guard ProcessInfo.processInfo.environment["STORYTELLER_REPLACE_E2E"] == "1" else {
      throw XCTSkip("set STORYTELLER_REPLACE_E2E=1 to run against the configured server")
    }
    let connections = try await StorytellerConnectionStore.shared.authenticatedConnections()
    guard !connections.isEmpty else { throw XCTSkip("no authenticated Storyteller connection") }
    // Use the first connection whose server advertises the safe-mutation
    // contract and whose account can create/update/delete.
    var candidate: (StorytellerConnection, StorytellerClient)? = nil
    var reasons: [String] = []
    for connection in connections {
      let probe = try StorytellerClient(origin: connection.origin) {
        try await StorytellerConnectionStore.shared.token(connection.id)
      }
      do {
        _ = try await probe.requirePermissions(create: true, update: true, delete: true)
        try await probe.requireSafeMutationSupport(create: true, replace: false)
        candidate = (connection, probe)
        break
      } catch {
        reasons.append("\(connection.displayName): \(error)")
      }
    }
    guard let (connection, client) = candidate else {
      throw XCTSkip("no mutation-capable connection: \(reasons.joined(separator: "; "))")
    }
    _ = connection

    let marker = String(UUID().uuidString.lowercased().prefix(8))
    let title = "SpokenFolio Replace E2E \(marker)"
    let epub = try Self.makeEPUB(title: title)
    defer { try? FileManager.default.removeItem(at: epub) }
    let localSHA = try BookFileDigest.sha256(epub)

    let baseline = Set(try await client.books().map(\.uuid))
    let cleanup = CreatedBook()
    addTeardownBlock { [cleanup] in
      // Only ever delete the marker-titled book this test created.
      if let id = await cleanup.id {
        try? await client.deleteBooks([id], preventReImport: false)
      }
    }

    // 1. Create the disposable book through the ordinary conditional-create
    // TUS path.
    try await Self.upload(epub, bookID: UUID(), client: client)
    let created = try await Self.findMarkerBook(
      client: client, marker: marker, baseline: baseline)
    await cleanup.set(created.uuid)
    let liveEbook = try XCTUnwrap(created.asset(.ebook), "ebook asset never became available")

    // 2. The confirmed snapshot passes drift verification against live state,
    // including the full content-hash probe.
    let expected = [
      BookJobRequest.StorytellerDelivery.ExpectedRemoteAsset(
        format: "ebook", assetID: liveEbook.uuid, size: liveEbook.fileSize,
        sha256: localSHA)
    ]
    try await BookJobExecutor.verifyReplacementSnapshot(target: created, expected: expected) {
      format, size in
      try await client.assetHash(bookID: created.uuid, format: format, expectedSize: size)
    }

    // 3. Any drift aborts before the destructive step: wrong asset identity…
    let driftedID = [
      BookJobRequest.StorytellerDelivery.ExpectedRemoteAsset(
        format: "ebook", assetID: UUID(), size: liveEbook.fileSize, sha256: nil)
    ]
    do {
      try await BookJobExecutor.verifyReplacementSnapshot(target: created, expected: driftedID) {
        _, _ in nil
      }
      XCTFail("expected a conflict for the drifted asset identity")
    } catch is StorytellerAPIError {}
    // …and wrong content.
    let driftedContent = [
      BookJobRequest.StorytellerDelivery.ExpectedRemoteAsset(
        format: "ebook", assetID: liveEbook.uuid, size: liveEbook.fileSize,
        sha256: String(repeating: "0", count: 64))
    ]
    do {
      try await BookJobExecutor.verifyReplacementSnapshot(
        target: created, expected: driftedContent
      ) { format, size in
        try await client.assetHash(bookID: created.uuid, format: format, expectedSize: size)
      }
      XCTFail("expected a conflict for the drifted content")
    } catch is StorytellerAPIError {}

    // 4. The replacement sequence: delete (preventReImport: false), confirm
    // absent, re-create with the same content, confirm it comes back.
    try await client.deleteBooks([created.uuid], preventReImport: false)
    await cleanup.set(nil)
    let afterDelete = try await client.books()
    XCTAssertFalse(afterDelete.contains { $0.uuid == created.uuid })
    XCTAssertEqual(
      Set(afterDelete.map(\.uuid)), baseline, "delete touched something beyond the test book")

    try await Self.upload(epub, bookID: created.uuid, client: client)
    let recreated = try await Self.findMarkerBook(
      client: client, marker: marker, baseline: baseline)
    await cleanup.set(recreated.uuid)
    XCTAssertNotNil(recreated.asset(.ebook))

    try await client.deleteBooks([recreated.uuid], preventReImport: false)
    await cleanup.set(nil)
    let final = Set(try await client.books().map(\.uuid))
    XCTAssertEqual(final, baseline, "cleanup left the library different from the baseline")
  }

  private actor CreatedBook {
    var id: UUID?
    func set(_ value: UUID?) { id = value }
  }

  private static func upload(_ epub: URL, bookID: UUID, client: StorytellerClient) async throws {
    let uploader = StorytellerTUSUploader(client: client)
    _ = try await uploader.upload(
      file: epub, endpoint: "/api/v2/books/upload",
      metadata: [
        "bookUuid": bookID.uuidString.lowercased(),
        "filename": epub.lastPathComponent,
        "filetype": "application/epub+zip",
        "ifBookMissing": "true",
      ],
      state: nil, chunkSize: 1 << 20, onState: { _ in }, onProgress: { _ in })
  }

  /// Finds the marker-titled book with an available ebook asset, polling
  /// briefly because Storyteller finalizes uploads asynchronously.
  private static func findMarkerBook(
    client: StorytellerClient, marker: String, baseline: Set<UUID>
  ) async throws -> StorytellerBook {
    for _ in 0..<30 {
      let books = try await client.books()
      if let book = books.first(where: {
        !baseline.contains($0.uuid) && $0.title.contains(marker) && $0.asset(.ebook) != nil
      }) {
        return book
      }
      try await Task.sleep(nanoseconds: 1_000_000_000)
    }
    throw StorytellerAPIError.conflict("the test book never appeared with a ready ebook asset")
  }

  /// A minimal valid EPUB via /usr/bin/zip (mimetype stored first).
  private static func makeEPUB(title: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("replace-e2e-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("OEBPS"), withIntermediateDirectories: true)
    try "application/epub+zip".write(
      to: root.appendingPathComponent("mimetype"), atomically: true, encoding: .utf8)
    try """
    <?xml version="1.0" encoding="UTF-8"?>
    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
      <rootfiles>
        <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
      </rootfiles>
    </container>
    """.write(
      to: root.appendingPathComponent("META-INF/container.xml"), atomically: true,
      encoding: .utf8)
    try """
    <?xml version="1.0" encoding="UTF-8"?>
    <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
      <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:identifier id="uid">urn:uuid:\(UUID().uuidString.lowercased())</dc:identifier>
        <dc:title>\(title)</dc:title>
        <dc:language>en</dc:language>
        <meta property="dcterms:modified">2026-01-01T00:00:00Z</meta>
      </metadata>
      <manifest>
        <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
        <item id="c1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
      </manifest>
      <spine><itemref idref="c1"/></spine>
    </package>
    """.write(
      to: root.appendingPathComponent("OEBPS/content.opf"), atomically: true, encoding: .utf8)
    try """
    <?xml version="1.0" encoding="UTF-8"?>
    <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
      <head><title>\(title)</title></head>
      <body><nav epub:type="toc"><ol><li><a href="chapter1.xhtml">One</a></li></ol></nav></body>
    </html>
    """.write(
      to: root.appendingPathComponent("OEBPS/nav.xhtml"), atomically: true, encoding: .utf8)
    try """
    <?xml version="1.0" encoding="UTF-8"?>
    <html xmlns="http://www.w3.org/1999/xhtml">
      <head><title>One</title></head>
      <body><h1>One</h1><p>A disposable paragraph for the replacement test.</p></body>
    </html>
    """.write(
      to: root.appendingPathComponent("OEBPS/chapter1.xhtml"), atomically: true, encoding: .utf8)

    let epub = root.appendingPathComponent("book.epub")
    func zip(_ arguments: [String]) throws {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
      process.currentDirectoryURL = root
      process.arguments = arguments
      process.standardOutput = FileHandle.nullDevice
      try process.run()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else {
        throw StorytellerAPIError.conflict("zip failed while building the fixture")
      }
    }
    try zip(["-X", "-0", epub.path, "mimetype"])
    try zip(["-X", "-9", "-r", epub.path, "META-INF", "OEBPS"])
    return epub
  }
}

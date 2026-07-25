import BookJobKit
import Foundation
import StorytellerKit
import XCTest

@testable import SpokenFolioApp

/// Live stock-Storyteller E2E against the configured server. Gated by
/// STORYTELLER_REPLACE_E2E=1 because it mutates the remote library — but
/// only ever a disposable book this test creates (marker-titled, absent from
/// the baseline), which it deletes again in teardown. It never touches an
/// existing remote book, and it exercises only real upstream endpoints:
/// plain TUS create, the one-byte hash probe, per-asset replace-asset
/// upload, and delete.
final class StorytellerReplaceLiveE2ETests: XCTestCase {
  func testDisposableBookPerAssetReplace() async throws {
    guard ProcessInfo.processInfo.environment["STORYTELLER_REPLACE_E2E"] == "1" else {
      throw XCTSkip("set STORYTELLER_REPLACE_E2E=1 to run against the configured server")
    }
    // The installed app's Keychain token is ACL-bound to the app binary, so
    // the test runner prefers explicit credentials and only falls back to
    // the connection store when they are absent.
    let environment = ProcessInfo.processInfo.environment
    let client: StorytellerClient
    if let rawURL = environment["STORYTELLER_TEST_URL"], let url = URL(string: rawURL),
      let token = environment["STORYTELLER_TEST_TOKEN"]
    {
      client = try StorytellerClient(origin: url, tokenProvider: { token })
    } else {
      let connections = try await StorytellerConnectionStore.shared.authenticatedConnections()
      guard let connection = connections.first else {
        throw XCTSkip(
          "no reachable credentials: set STORYTELLER_TEST_URL and STORYTELLER_TEST_TOKEN")
      }
      client = try StorytellerClient(origin: connection.origin) {
        try await StorytellerConnectionStore.shared.token(connection.id)
      }
    }
    _ = try await client.requirePermissions(create: true, update: true, delete: true)

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
        try? await client.deleteBooks([id], preventReImport: true)
      }
    }

    // 1. Create the disposable book through the ordinary TUS create path.
    try await Self.upload(
      epub, endpoint: "/api/v2/books/upload",
      metadata: [
        "bookUuid": UUID().uuidString.lowercased(),
        "filename": epub.lastPathComponent,
        "filetype": "application/epub+zip",
      ], client: client)
    let created = try await Self.findMarkerBook(
      client: client, marker: marker, baseline: baseline)
    await cleanup.set(created.uuid)
    let liveEbook = try XCTUnwrap(created.asset(.ebook), "ebook asset never became available")

    // 2. The real one-byte probe returns the full-asset sha256.
    let probed = try await client.assetHash(
      bookID: created.uuid, format: .ebook, expectedSize: liveEbook.fileSize ?? 0)
    XCTAssertEqual(probed, localSHA, "one-byte probe hash mismatch")

    // 3. Per-asset ceiling verification against the live asset.
    try BookJobExecutor.verifyAcknowledgedAsset(
      format: .ebook, asset: liveEbook, hash: probed,
      expected: [
        .init(
          format: "ebook", assetID: liveEbook.uuid, size: liveEbook.fileSize,
          sha256: localSHA)
      ])

    // 4. Replace the ebook per-asset through the real replace-asset flow
    // (different content: the same EPUB re-zipped with a new identifier).
    let replacement = try Self.makeEPUB(title: title)
    defer { try? FileManager.default.removeItem(at: replacement) }
    let replacementSHA = try BookFileDigest.sha256(replacement)
    XCTAssertNotEqual(replacementSHA, localSHA)
    try await Self.upload(
      replacement,
      endpoint: "/api/v2/books/\(created.uuid.uuidString.lowercased())/replace-asset/upload",
      metadata: [
        "bookUuid": created.uuid.uuidString.lowercased(),
        "filename": replacement.lastPathComponent,
        "filetype": "application/epub+zip",
        "format": "ebook",
        "batchId": UUID().uuidString.lowercased(),
      ], client: client)
    // The replacement is imported asynchronously; poll for the new hash.
    var replacedHash: String?
    for _ in 0..<30 {
      let book = try await client.book(created.uuid)
      if let asset = book?.asset(.ebook), let size = asset.fileSize {
        replacedHash = try await client.assetHash(
          bookID: created.uuid, format: .ebook, expectedSize: size)
        if replacedHash == replacementSHA { break }
      }
      try await Task.sleep(nanoseconds: 1_000_000_000)
    }
    XCTAssertEqual(replacedHash, replacementSHA, "replace-asset upload did not take effect")

    // 5. Cleanup: delete the disposable book; the library returns to baseline.
    try await client.deleteBooks([created.uuid], preventReImport: true)
    await cleanup.set(nil)
    let final = Set(try await client.books().map(\.uuid))
    XCTAssertEqual(final, baseline, "cleanup left the library different from the baseline")
  }

  private actor CreatedBook {
    var id: UUID?
    func set(_ value: UUID?) { id = value }
  }

  private static func upload(
    _ file: URL, endpoint: String, metadata: [String: String], client: StorytellerClient
  ) async throws {
    let uploader = StorytellerTUSUploader(client: client)
    _ = try await uploader.upload(
      file: file, endpoint: endpoint, metadata: metadata,
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

  /// A minimal valid EPUB via /usr/bin/zip (mimetype stored first). Each
  /// call embeds a fresh identifier so two builds never hash identically.
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

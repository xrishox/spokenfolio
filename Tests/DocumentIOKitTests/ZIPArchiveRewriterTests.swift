import XCTest

@testable import DocumentIOKit

/// The rewriter must preserve untouched entries bit-for-bit (raw compressed
/// payload, method, CRC), substitute replaced payloads verifiably, keep the
/// EPUB `mimetype` entry stored, and refuse replacement paths the archive
/// does not contain.
final class ZIPArchiveRewriterTests: XCTestCase {
  private func fixtureArchive() throws -> (url: URL, archive: ZIPArchive) {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    try Data("application/epub+zip".utf8).write(to: root.appendingPathComponent("mimetype"))
    try Data(String(repeating: "compressible prose. ", count: 200).utf8)
      .write(to: root.appendingPathComponent("chapter.xhtml"))
    try Data((0..<256).map { UInt8($0) })
      .write(to: root.appendingPathComponent("audio.bin"))
    let url = root.appendingPathComponent("fixture.zip")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    process.currentDirectoryURL = root
    process.arguments = ["-q", "-X", url.path, "mimetype", "chapter.xhtml", "audio.bin"]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
    return (url, try ZIPArchive(url: url))
  }

  func testRewritePreservesUntouchedEntriesAndSubstitutesReplacement() throws {
    let (url, archive) = try fixtureArchive()
    let replacement = Data(String(repeating: "replaced sentence. ", count: 100).utf8)
    let destination = url.deletingLastPathComponent().appendingPathComponent("out.zip")
    try ZIPArchiveRewriter.rewrite(
      archive, replacing: ["chapter.xhtml": replacement], to: destination)

    let rewritten = try ZIPArchive(url: destination)
    XCTAssertEqual(rewritten.entries.map(\.path), archive.entries.map(\.path))
    XCTAssertEqual(
      try rewritten.data(for: rewritten.entry(at: "chapter.xhtml")!), replacement)
    // Untouched entries keep their exact compressed bytes and metadata.
    for path in ["mimetype", "audio.bin"] {
      let original = archive.entry(at: path)!
      let copied = rewritten.entry(at: path)!
      XCTAssertEqual(copied.compressionMethod, original.compressionMethod, path)
      XCTAssertEqual(copied.crc32, original.crc32, path)
      XCTAssertEqual(
        try rewritten.rawPayload(for: copied), try archive.rawPayload(for: original), path)
    }
    // The compressible replacement actually deflated.
    let replaced = rewritten.entry(at: "chapter.xhtml")!
    XCTAssertEqual(replaced.compressionMethod, 8)
    XCTAssertLessThan(replaced.compressedSize, replacement.count)
  }

  func testMimetypeReplacementStaysStored() throws {
    let (url, archive) = try fixtureArchive()
    let destination = url.deletingLastPathComponent().appendingPathComponent("mt.zip")
    let payload = Data(String(repeating: "application/epub+zip", count: 40).utf8)
    try ZIPArchiveRewriter.rewrite(
      archive, replacing: ["mimetype": payload], to: destination)
    let rewritten = try ZIPArchive(url: destination)
    let mimetype = rewritten.entry(at: "mimetype")!
    XCTAssertEqual(mimetype.compressionMethod, 0)
    XCTAssertEqual(try rewritten.data(for: mimetype), payload)
  }

  func testUnknownReplacementPathThrows() throws {
    let (url, archive) = try fixtureArchive()
    let destination = url.deletingLastPathComponent().appendingPathComponent("bad.zip")
    XCTAssertThrowsError(
      try ZIPArchiveRewriter.rewrite(
        archive, replacing: ["missing.xhtml": Data("x".utf8)], to: destination))
  }
}

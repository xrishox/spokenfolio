import Foundation
import XCTest

@testable import AudiobookKit

final class ZIPReaderTests: XCTestCase {
  private let mimetypeBody = Data("application/epub+zip".utf8)
  private let chapterBody = Data(
    String(repeating: "All happy chapters compress alike; each unhappy chapter... ", count: 200)
      .utf8)

  private func epubLikeFixture() -> ZIPFixtureWriter {
    var writer = ZIPFixtureWriter()
    writer.addEntry(path: "mimetype", data: mimetypeBody, compress: false)
    writer.addEntry(path: "OEBPS/chapter1.xhtml", data: chapterBody, compress: true)
    return writer
  }

  // MARK: - Round trips

  func testStoredAndDeflateEntriesRoundTrip() throws {
    let archive = try ZIPArchive(data: epubLikeFixture().finish())

    XCTAssertEqual(archive.entries.map(\.path), ["mimetype", "OEBPS/chapter1.xhtml"])

    let stored = try XCTUnwrap(archive.entry(at: "mimetype"))
    XCTAssertEqual(stored.compressionMethod, 0)
    XCTAssertEqual(stored.compressedSize, mimetypeBody.count)
    XCTAssertEqual(stored.uncompressedSize, mimetypeBody.count)
    XCTAssertEqual(try archive.data(for: stored), mimetypeBody)

    let deflated = try XCTUnwrap(archive.entry(at: "OEBPS/chapter1.xhtml"))
    XCTAssertEqual(deflated.compressionMethod, 8)
    XCTAssertEqual(deflated.uncompressedSize, chapterBody.count)
    XCTAssertLessThan(deflated.compressedSize, chapterBody.count, "fixture must really deflate")
    XCTAssertEqual(try archive.data(for: deflated), chapterBody)
  }

  func testUTF8EntryNames() throws {
    let path = "OEBPS/章節/naïve résumé.xhtml"
    var writer = ZIPFixtureWriter()
    writer.addEntry(path: path, data: chapterBody, compress: true)

    let archive = try ZIPArchive(data: writer.finish())
    let entry = try XCTUnwrap(archive.entry(at: path))
    XCTAssertEqual(entry.path, path)
    XCTAssertEqual(try archive.data(for: entry), chapterBody)
  }

  func testDataDescriptorEntryReadsViaCentralDirectorySizes() throws {
    var writer = epubLikeFixture()
    writer.useDataDescriptors = true

    let archive = try ZIPArchive(data: writer.finish())
    let entry = try XCTUnwrap(archive.entry(at: "OEBPS/chapter1.xhtml"))
    XCTAssertGreaterThan(entry.compressedSize, 0, "sizes must come from the central directory")
    XCTAssertEqual(entry.uncompressedSize, chapterBody.count)
    XCTAssertEqual(try archive.data(for: entry), chapterBody)
    XCTAssertEqual(try archive.data(for: try XCTUnwrap(archive.entry(at: "mimetype"))), mimetypeBody)
  }

  // MARK: - End of central directory discovery

  func testEndOfCentralDirectoryFoundBehindCommentWithDecoyRecord() throws {
    var writer = epubLikeFixture()
    // A hostile comment ending in a fully self-consistent decoy EOCD record
    // (zero entries, zero comment length). Picking the decoy would parse an
    // empty archive; the reader must keep the true, earlier record.
    var comment = Data("archive comment hiding a decoy record: ".utf8)
    comment.append(contentsOf: [0x50, 0x4B, 0x05, 0x06])
    comment.append(Data(repeating: 0, count: 18))
    writer.archiveComment = comment

    let archive = try ZIPArchive(data: writer.finish())
    XCTAssertEqual(archive.entries.count, 2)
    XCTAssertEqual(try archive.data(for: XCTUnwrap(archive.entry(at: "mimetype"))), mimetypeBody)
  }

  // MARK: - Corruption and hostile metadata

  func testCorruptedPayloadFailsChecksum() throws {
    var writer = ZIPFixtureWriter()
    writer.addEntry(path: "mimetype", data: mimetypeBody, compress: false)
    var fixture = writer.finish()
    // Stored payload begins after the 30-byte local header and 8-byte name.
    fixture[38] ^= 0x01

    let archive = try ZIPArchive(data: fixture)
    let entry = try XCTUnwrap(archive.entry(at: "mimetype"))
    XCTAssertThrowsError(try archive.data(for: entry)) { error in
      guard case ZIPError.checksumMismatch = error else {
        return XCTFail("expected checksumMismatch, got \(error)")
      }
    }
  }

  func testEncryptedEntryIsRejected() {
    var writer = epubLikeFixture()
    writer.generalPurposeFlagOverride = 0x0001  // bit 0: encrypted

    XCTAssertThrowsError(try ZIPArchive(data: writer.finish())) { error in
      guard case ZIPError.encryptedEntryUnsupported = error else {
        return XCTFail("expected encryptedEntryUnsupported, got \(error)")
      }
    }
  }

  func testZIP64SentinelIsRejected() {
    var writer = epubLikeFixture()
    writer.centralLocalHeaderOffsetOverride = 0xFFFF_FFFF

    XCTAssertThrowsError(try ZIPArchive(data: writer.finish())) { error in
      guard case ZIPError.zip64ArchiveUnsupported = error else {
        return XCTFail("expected zip64ArchiveUnsupported, got \(error)")
      }
    }
  }

  func testZIP64LocatorIsRejected() {
    var fixture = epubLikeFixture().finish()
    // Insert an EOCD64 locator (signature + 16 payload bytes) directly
    // before the end-of-central-directory record.
    var locator = Data([0x50, 0x4B, 0x06, 0x07])
    locator.append(Data(repeating: 0, count: 16))
    fixture.insert(contentsOf: locator, at: fixture.count - 22)

    XCTAssertThrowsError(try ZIPArchive(data: fixture)) { error in
      guard case ZIPError.zip64ArchiveUnsupported = error else {
        return XCTFail("expected zip64ArchiveUnsupported, got \(error)")
      }
    }
  }

  func testEntryCountBoundIsEnforced() {
    var writer = epubLikeFixture()
    writer.entryCountOverride = 10_001

    XCTAssertThrowsError(try ZIPArchive(data: writer.finish())) { error in
      guard case ZIPError.tooManyEntries(let count) = error else {
        return XCTFail("expected tooManyEntries, got \(error)")
      }
      XCTAssertEqual(count, 10_001)
    }
  }

  func testPerEntrySizeBoundIsEnforced() {
    var writer = epubLikeFixture()
    writer.centralUncompressedSizeOverride = UInt32(64 << 20) + 1

    XCTAssertThrowsError(try ZIPArchive(data: writer.finish())) { error in
      guard case ZIPError.entryTooLarge = error else {
        return XCTFail("expected entryTooLarge, got \(error)")
      }
    }
  }

  func testTotalUncompressedSizeBoundIsEnforced() {
    var writer = ZIPFixtureWriter()
    for index in 0..<9 {
      writer.addEntry(path: "big/\(index).bin", data: Data("tiny".utf8), compress: false)
    }
    // Each claimed size passes the per-entry bound; nine together exceed
    // the 512 MiB archive-wide bound.
    writer.centralUncompressedSizeOverride = UInt32(60 << 20)

    XCTAssertThrowsError(try ZIPArchive(data: writer.finish())) { error in
      guard case ZIPError.archiveContentsTooLarge = error else {
        return XCTFail("expected archiveContentsTooLarge, got \(error)")
      }
    }
  }

  func testTruncatedArchiveThrowsInsteadOfCrashing() {
    let fixture = epubLikeFixture().finish()
    for length in [0, 10, 21, fixture.count / 2, fixture.count - 1] {
      XCTAssertThrowsError(
        try ZIPArchive(data: Data(fixture.prefix(length))),
        "truncation to \(length) bytes must throw"
      ) { error in
        XCTAssertTrue(error is ZIPError, "truncation to \(length) bytes threw \(error)")
      }
    }
  }

  // MARK: - Lookup and checksum primitives

  func testEntryLookupRequiresExactPathMatch() throws {
    let archive = try ZIPArchive(data: epubLikeFixture().finish())
    XCTAssertNotNil(archive.entry(at: "OEBPS/chapter1.xhtml"))
    XCTAssertNil(archive.entry(at: "OEBPS/Chapter1.xhtml"))
    XCTAssertNil(archive.entry(at: "/mimetype"))
    XCTAssertNil(archive.entry(at: "mimetype "))
    XCTAssertNil(archive.entry(at: ""))
  }

  func testChecksumMatchesKnownVector() {
    // Standard CRC-32 check value for the ASCII digits "123456789".
    XCTAssertEqual(ZIPCRC32.checksum(Data("123456789".utf8)), 0xCBF4_3926)
    XCTAssertEqual(ZIPCRC32.checksum(Data()), 0)
  }

  // MARK: - Optional real-EPUB integration

  func testRealEPUBWhenProvided() throws {
    guard let path = ProcessInfo.processInfo.environment["AUDIOBOOK_TEST_EPUB"] else {
      throw XCTSkip("Set AUDIOBOOK_TEST_EPUB to a real .epub path to run this test.")
    }
    let archive = try ZIPArchive(url: URL(fileURLWithPath: path))
    XCTAssertGreaterThan(archive.entries.count, 10)
    let mimetype = try XCTUnwrap(archive.entry(at: "mimetype"))
    XCTAssertEqual(String(data: try archive.data(for: mimetype), encoding: .utf8),
      "application/epub+zip")
  }
}

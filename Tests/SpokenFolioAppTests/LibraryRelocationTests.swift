import BookJobKit
import Foundation
import XCTest

@testable import SpokenFolioApp

/// The library-move primitive: a book folder either arrives verified at the
/// destination or the source is left untouched.
final class LibraryRelocationTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("relocation-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  private func makeBook(named name: String) throws -> (folder: URL, record: BookCatalogRecord) {
    let folder = root.appendingPathComponent("old/\(name)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let epub = folder.appendingPathComponent("\(name).epub")
    try Data("epub bytes".utf8).write(to: epub)
    let sha = try BookFileDigest.sha256(epub)
    let record = BookCatalogRecord(
      source: .init(format: "epub", importerVersion: 1, sha256: sha, size: 10),
      metadata: .init(title: name, author: nil),
      outputDirectory: folder.path, outputBaseName: name,
      products: [
        .init(kind: .sourceEPUB, path: epub.path, size: 10, sha256: sha, verifiedAt: Date())
      ])
    return (folder, record)
  }

  func testMoveRenamesFolderIntoDestination() throws {
    let (folder, record) = try makeBook(named: "Fixture Book")
    let target = root.appendingPathComponent("new/Fixture Book", isDirectory: true)
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("new"), withIntermediateDirectories: true)
    try LibraryRelocationService.performMove(record: record, source: folder, target: target)
    XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: target.appendingPathComponent("Fixture Book.epub").path))
  }

  func testMoveRefusesExistingTarget() throws {
    let (folder, record) = try makeBook(named: "Fixture Book")
    let target = root.appendingPathComponent("new/Fixture Book", isDirectory: true)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    XCTAssertThrowsError(
      try LibraryRelocationService.performMove(record: record, source: folder, target: target)
    ) { error in
      XCTAssertTrue("\(error)".contains("already exists"), "\(error)")
    }
    // The source is untouched.
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: folder.appendingPathComponent("Fixture Book.epub").path))
  }

  func testCopyVerifyRemoveMovesVerifiedContent() throws {
    let (folder, record) = try makeBook(named: "Fixture Book")
    let target = root.appendingPathComponent("copyDest/Fixture Book", isDirectory: true)
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("copyDest"), withIntermediateDirectories: true)
    try LibraryRelocationService.copyVerifyRemove(record: record, source: folder, target: target)
    XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    let moved = target.appendingPathComponent("Fixture Book.epub")
    XCTAssertEqual(try BookFileDigest.sha256(moved), record.products[0].sha256)
  }

  func testCopyVerifyRemoveAbortsOnDigestMismatchAndKeepsSource() throws {
    let (folder, record) = try makeBook(named: "Fixture Book")
    // Corrupt the record's expectation so verification must fail.
    var corrupted = record
    corrupted.products[0].sha256 = String(repeating: "0", count: 64)
    let target = root.appendingPathComponent("copyDest/Fixture Book", isDirectory: true)
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("copyDest"), withIntermediateDirectories: true)
    XCTAssertThrowsError(
      try LibraryRelocationService.copyVerifyRemove(
        record: corrupted, source: folder, target: target))
    // The half-copied target is removed; the source is untouched.
    XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: folder.appendingPathComponent("Fixture Book.epub").path))
  }
}

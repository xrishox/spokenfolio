import Foundation
import XCTest

@testable import BookJobKit

final class SynthesisTimelineStoreTests: XCTestCase {
  private let digest = String(repeating: "ab", count: 32)

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("timeline-store-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }

  func testAdoptURLExistsRoundTrip() throws {
    let base = try temporaryDirectory()
    let store = SynthesisTimelineStore(
      root: base.appendingPathComponent("store", isDirectory: true))
    let sidecar = base.appendingPathComponent("book.synthesis-timeline.json")
    try Data("{\"schemaVersion\":1}".utf8).write(to: sidecar)

    XCTAssertFalse(store.exists(forAudiobookSHA256: digest))
    try store.adopt(sidecarAt: sidecar, forAudiobookSHA256: digest)

    XCTAssertTrue(store.exists(forAudiobookSHA256: digest))
    XCTAssertEqual(
      store.url(forAudiobookSHA256: digest),
      store.root.appendingPathComponent("\(digest).json"))
    XCTAssertEqual(
      try Data(contentsOf: store.url(forAudiobookSHA256: digest)),
      Data("{\"schemaVersion\":1}".utf8))
    // Adoption moves the sidecar: nothing non-product remains at the source.
    XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path))
  }

  func testAdoptReplacesPreviousEntry() throws {
    let base = try temporaryDirectory()
    let store = SynthesisTimelineStore(
      root: base.appendingPathComponent("store", isDirectory: true))
    let first = base.appendingPathComponent("first.json")
    let second = base.appendingPathComponent("second.json")
    try Data("first".utf8).write(to: first)
    try Data("second".utf8).write(to: second)

    try store.adopt(sidecarAt: first, forAudiobookSHA256: digest)
    try store.adopt(sidecarAt: second, forAudiobookSHA256: digest)

    XCTAssertEqual(
      try Data(contentsOf: store.url(forAudiobookSHA256: digest)), Data("second".utf8))
  }

  func testAdoptRejectsNonDigestKeysAndMissingSidecars() throws {
    let base = try temporaryDirectory()
    let store = SynthesisTimelineStore(
      root: base.appendingPathComponent("store", isDirectory: true))
    let sidecar = base.appendingPathComponent("book.json")
    try Data("{}".utf8).write(to: sidecar)

    XCTAssertThrowsError(
      try store.adopt(sidecarAt: sidecar, forAudiobookSHA256: "../escape"))
    XCTAssertThrowsError(
      try store.adopt(sidecarAt: sidecar, forAudiobookSHA256: digest.uppercased()))
    XCTAssertThrowsError(
      try store.adopt(
        sidecarAt: base.appendingPathComponent("missing.json"), forAudiobookSHA256: digest))
    // Failed adoptions never create partial store entries.
    XCTAssertFalse(store.exists(forAudiobookSHA256: digest))
  }
}

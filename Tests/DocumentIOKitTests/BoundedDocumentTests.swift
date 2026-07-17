import Foundation
import XCTest
@testable import DocumentIOKit

final class BoundedDocumentTests: XCTestCase {
  func testExternalEntityIsNeverExpanded() throws {
    let secret = FileManager.default.temporaryDirectory
      .appendingPathComponent("xml-secret-\(UUID().uuidString)")
    try Data("do-not-expand".utf8).write(to: secret)
    defer { try? FileManager.default.removeItem(at: secret) }
    let xml = """
      <?xml version="1.0"?>
      <!DOCTYPE root [<!ENTITY leaked SYSTEM "\(secret.absoluteString)">]>
      <root>&leaked;</root>
      """
    XCTAssertThrowsError(try BoundedXMLDocument.parse(Data(xml.utf8))) { error in
      XCTAssertEqual(error as? BoundedXMLError, .entityDeclaration)
    }
  }

  func testExternalEPUBDoctypeIsAllowedButNotLoaded() throws {
    let xml = """
      <?xml version="1.0"?>
      <!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://example.invalid/xhtml11.dtd">
      <html><body><p>Safe prose.</p></body></html>
      """
    let document = try BoundedXMLDocument.parse(Data(xml.utf8))
    XCTAssertEqual(document.rootElement()?.stringValue, "Safe prose.")
  }

  func testUTF16InternalEntityIsRejectedBeforeExpansion() throws {
    let xml = """
      <?xml version="1.0" encoding="UTF-16"?>
      <!DOCTYPE root [<!ENTITY expanded "EXPANDED">]>
      <root>&expanded;</root>
      """
    let data = try XCTUnwrap(xml.data(using: .utf16LittleEndian))
    XCTAssertThrowsError(try BoundedXMLDocument.parse(data)) { error in
      XCTAssertEqual(error as? BoundedXMLError, .entityDeclaration)
    }
  }

  func testUTF32InternalEntityIsRejectedBeforeExpansion() throws {
    let xml = """
      <?xml version="1.0" encoding="UTF-32"?>
      <!DOCTYPE root [<!ENTITY expanded "EXPANDED">]>
      <root>&expanded;</root>
      """
    let data = try XCTUnwrap(xml.data(using: .utf32BigEndian))
    XCTAssertThrowsError(try BoundedXMLDocument.parse(data)) { error in
      XCTAssertEqual(error as? BoundedXMLError, .entityDeclaration)
    }
  }

  func testInMemoryArchiveHonorsCompressedSizeLimit() throws {
    let limits = ZIPArchive.Limits(
      maximumEntryCount: 1,
      maximumEntryUncompressedSize: 16,
      maximumTotalUncompressedSize: 16,
      maximumArchiveFileSize: 4)
    XCTAssertThrowsError(try ZIPArchive(data: Data(repeating: 0, count: 5), limits: limits)) {
      error in
      guard case ZIPError.archiveFileTooLarge = error else {
        return XCTFail("expected archive-size error, got \(error)")
      }
    }
  }

  func testDepthAndNodeBudgetsAreEnforced() throws {
    let deep = String(repeating: "<n>", count: 12) + "x"
      + String(repeating: "</n>", count: 12)
    let limits = BoundedXMLDocument.Limits(maximumDepth: 8, maximumNodes: 100)
    XCTAssertThrowsError(
      try BoundedXMLDocument.parse(Data(deep.utf8), limits: limits)
    ) { error in
      guard case BoundedXMLError.depth = error else {
        return XCTFail("expected depth error, got \(error)")
      }
    }

    let wide = "<r>" + String(repeating: "<n/>", count: 20) + "</r>"
    let nodeLimits = BoundedXMLDocument.Limits(maximumDepth: 8, maximumNodes: 10)
    XCTAssertThrowsError(
      try BoundedXMLDocument.parse(Data(wide.utf8), limits: nodeLimits)
    ) { error in
      guard case BoundedXMLError.nodeCount = error else {
        return XCTFail("expected node-count error, got \(error)")
      }
    }
  }
}

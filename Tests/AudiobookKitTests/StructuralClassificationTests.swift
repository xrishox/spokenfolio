import XCTest
import PublicationKit

@testable import AudiobookKit
@testable import EPUBKit

/// Structure-corroborated roles for spine files that carry no TOC title
/// (untitled trailing files): printed TOC (extractorVersion 13) alongside
/// the index rule (v10). Both fail open on prose and verse.
final class StructuralClassificationTests: XCTestCase {
  private func roles(_ chapters: [String]) throws -> [SectionRole] {
    var fixture = EPUBFixture()
    fixture.documents = chapters.enumerated().map { index, body in
      EPUBFixture.Document(
        id: "c\(index)", path: "OEBPS/c\(index).xhtml", xhtml: EPUBFixture.xhtml(body: body))
    }
    let url = try fixture.write()
    defer { try? FileManager.default.removeItem(at: url) }
    return try EPUBImporter().load(url: url).sections.map(\.role)
  }

  func testUntitledPrintedTOCClassifiesByStructure() throws {
    let toc = (1...30).map { "<p>CHAPTER \($0)</p>" }.joined()
      + "<p>BOOK ONE: 1805</p><p>FIRST EPILOGUE</p>"
    let roles = try roles(["<p>Contents</p>\(toc)", "<p>Ordinary prose continues here.</p>"])
    XCTAssertEqual(roles.first, .printedTOC)
    XCTAssertEqual(roles.last, .unknown, "prose fails open")
  }

  func testNoterefTargetFilesClassifyAsNotes() throws {
    let refs = (1...22).map {
      "Claim number \($0) stands.<a href=\"notes.xhtml#n\($0)\" epub:type=\"noteref\">\($0)</a> "
    }.joined()
    let notes = (1...22).map { "<p>\($0). The supporting citation for claim \($0).</p>" }.joined()
    var fixture = EPUBFixture()
    fixture.documents = [
      EPUBFixture.Document(
        id: "c0", path: "OEBPS/c0.xhtml", xhtml: EPUBFixture.xhtml(body: "<p>\(refs)</p>")),
      EPUBFixture.Document(
        id: "notes", path: "OEBPS/notes.xhtml", xhtml: EPUBFixture.xhtml(body: notes)),
    ]
    let url = try fixture.write()
    defer { try? FileManager.default.removeItem(at: url) }
    let roles = try EPUBImporter().load(url: url).sections.map(\.role)
    XCTAssertEqual(roles, [.unknown, .notes], "noteref-target file is notes: \(roles)")
  }

  func testVerseAndAphorismsStayNarratable() throws {
    // Poetry: short lines, but none start with structural labels.
    let poem = (1...30).map { "<p>and the line number \($0) sings on</p>" }.joined()
    // Aphorisms: numeral blocks interleaved with long prose fail the fraction.
    let aphorisms = (1...15).map {
      "<p>XI\($0 % 2 == 0 ? "I" : "")</p>"
        + "<p>Begin the morning by saying to thyself, I shall meet with the busybody, "
        + "the ungrateful, arrogant, deceitful, envious, unsocial man number \($0).</p>"
    }.joined()
    let roles = try roles(["\(poem)", "\(aphorisms)"])
    XCTAssertEqual(roles, [.unknown, .unknown])
  }
}

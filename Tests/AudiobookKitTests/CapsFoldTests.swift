import XCTest
import PublicationKit

@testable import AudiobookKit
@testable import EPUBKit

/// Whole-book evidence gate for presentational all-caps folding
/// (`CapsFoldDetection`, extractorVersion 11). Evidence spans documents, so
/// these tests load real multi-document fixture EPUBs through the importer.
final class CapsFoldTests: XCTestCase {
  private func load(_ chapters: [String]) throws -> [String] {
    var fixture = EPUBFixture()
    fixture.documents = chapters.enumerated().map { index, body in
      EPUBFixture.Document(
        id: "c\(index)", path: "OEBPS/c\(index).xhtml", xhtml: EPUBFixture.xhtml(body: body))
    }
    let url = try fixture.write()
    defer { try? FileManager.default.removeItem(at: url) }
    let publication = try EPUBImporter().load(url: url)
    return publication.sections.flatMap(\.blocks).map(\.text)
  }

  private let prose = """
    <p>Ser Waymar Royce rode ahead, and Arya Stark watched Royce pass.</p>
    <p>Later, Ser Waymar spoke to Arya about Royce, and Arya listened.</p>
    <p>In the yard, Ser Waymar sparred while Arya and Alayaya kept score.</p>
    <p>By nightfall Alayaya slept, and Ser Waymar watched, and Alayaya dreamed while Arya kept watch.</p>
    """

  func testRosterAndTitleCapsFoldToAttestedTwins() throws {
    let appendix = """
      <p>ARYA</p>
      <p>SER WAYMAR ROYCE, called the WANDERER, urged the column forward.</p>
      <p>ALAYAYA, called YAYA, a comely woman,</p>
      """
    let texts = try load([prose, appendix])
    XCTAssertTrue(texts.contains("Arya"), "caps title block folds: \(texts.suffix(3))")
    XCTAssertTrue(
      texts.contains { $0.hasPrefix("Ser Waymar Royce, called the WANDERER") },
      "leading caps run folds; unattested WANDERER stays: \(texts.suffix(3))")
    XCTAssertTrue(
      texts.contains { $0.hasPrefix("Alayaya, called YAYA") },
      "comma-terminated roster name folds, unattested YAYA stays: \(texts.suffix(3))")
  }

  func testAcronymsAndLowercaseEvidenceAreNeverFolded() throws {
    let chapters = [
      // Cia the character is attested mid-sentence; lowercase "cia" never.
      """
      <p>Agent Cia smiled, and later Cia frowned, but Cia never spoke.</p>
      <p>He joined the CIA that spring; the CIA taught him tradecraft.</p>
      <p>CIA OPERATIONS MANUAL</p>
      <p>the LORD spoke, and the lord of the manor listened to the LORD.</p>
      """,
      // FBI has no twin anywhere; HERE LIE THE WOLVES is an inscription of
      // dictionary words with lowercase evidence.
      """
      <p>The FBI files stayed sealed. FBI AND CIA JOINT BRIEFING</p>
      <p>They buried them here, and the wolves lie where the here and lie of it ended.</p>
      <p>HERE LIE THE WOLVES</p>
      """,
    ]
    let texts = try load(chapters)
    XCTAssertTrue(
      texts.contains("CIA OPERATIONS MANUAL"),
      "multi-token caps blocks are whole-block prose and preserved: \(texts)")
    XCTAssertTrue(
      texts.contains { $0.contains("joined the CIA that spring") },
      "mid-prose CIA is acronym-shaped and preserved")
    XCTAssertTrue(
      texts.contains { $0.contains("the LORD spoke") },
      "lowercase evidence blocks LORD: \(texts)")
    XCTAssertTrue(texts.contains("HERE LIE THE WOLVES"), "inscription preserved: \(texts)")
    XCTAssertFalse(texts.contains { $0.contains("Fbi") }, "FBI can never fold")
  }

  /// The first-line caps convention, "CHAPTER ONE", and carved epigraphs
  /// are prose set in caps: a lowercase-attested word inside the unit
  /// vetoes every fold in it, so no mixed-case soup appears.
  func testProseSetInCapsIsVetoed() throws {
    let chapters = [
      """
      <p>Then Vin awoke slowly, and Vin sat up, and Vin stretched in the quiet room.</p>
      <p>It was one chapter of life; that chapter closed, and one more began until it arrived.</p>
      """,
      """
      <p>VIN AWOKE TO A QUIET room, red morning sunlight peeking in.</p>
      <p>CHAPTER ONE</p>
      <p>UNTIL VIN ARRIVED.</p>
      """,
    ]
    let texts = try load(chapters)
    XCTAssertTrue(
      texts.contains { $0.hasPrefix("VIN AWOKE TO A QUIET") },
      "first-line caps convention preserved: \(texts)")
    XCTAssertTrue(texts.contains("CHAPTER ONE"), "chapter label preserved: \(texts)")
    XCTAssertTrue(texts.contains("UNTIL VIN ARRIVED."), "caps epigraph preserved: \(texts)")
  }

  func testTwinBelowEvidenceThresholdDoesNotFold() throws {
    let chapters = [
      "<p>Once, Torgo waved. Torgo left.</p>",  // only 1 mid-sentence use
      "<p>TORGO</p><p>TORGO THE MIGHTY strode in.</p>",
    ]
    let texts = try load(chapters)
    XCTAssertTrue(texts.contains("TORGO"), "insufficient twin evidence preserves caps: \(texts)")
  }
}

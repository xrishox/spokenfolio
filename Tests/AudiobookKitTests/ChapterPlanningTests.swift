import XCTest

@testable import AudiobookKit

final class ChapterPlanningTests: XCTestCase {
  private var fixtureURLs: [URL] = []

  override func tearDown() {
    for url in fixtureURLs { try? FileManager.default.removeItem(at: url) }
    fixtureURLs = []
    super.tearDown()
  }

  private func plan(
    _ fixture: EPUBFixture, options: PlanOptions = PlanOptions()
  ) throws -> AudiobookPlan {
    let url = try fixture.write()
    fixtureURLs.append(url)
    return try AudiobookPlanner.plan(book: try EPUBBook.load(url: url), options: options)
  }

  func testThreeBodyShapePlansBodyChaptersAndSkipsApparatus() throws {
    let plan = try plan(.threeBodyShape())

    let roleBySpineIndex = Dictionary(
      uniqueKeysWithValues: plan.sections.map { ($0.spineIndex, $0.role) })
    XCTAssertEqual(roleBySpineIndex[0], .cover, "landmark cover beats title-page keyword")
    XCTAssertEqual(roleBySpineIndex[1], .copyright)
    XCTAssertEqual(roleBySpineIndex[2], .printedTOC)
    XCTAssertEqual(roleBySpineIndex[3], .part)
    XCTAssertEqual(roleBySpineIndex[4], .chapter)
    XCTAssertEqual(roleBySpineIndex[6], .notes, "linear footnote file classified via tier-3")
    XCTAssertEqual(roleBySpineIndex[7], .notes)
    XCTAssertEqual(roleBySpineIndex[8], .aboutAuthor)

    XCTAssertEqual(
      plan.chapters.map(\.title),
      ["Part I: Silent Spring", "1. The Madness Years", "2. Silent Spring"])

    // Chapter 1's dedupe: body opens with number/title/setting → no announcement.
    let chapter1 = plan.chapters[1]
    XCTAssertNil(chapter1.announcement)
    XCTAssertEqual(chapter1.paragraphs.first?.sentences, ["1"])

    // Footnote text must be gone entirely.
    let allText = plan.chapters
      .flatMap(\.allParagraphs).flatMap(\.sentences).joined(separator: " ")
    XCTAssertFalse(allText.contains("Translator"))
    XCTAssertFalse(allText.contains("cultural reference"))

    // Part separator body suppresses its own announcement (PART I SILENT SPRING).
    XCTAssertNil(plan.chapters[0].announcement)
  }

  func testMistbornShapeAnnouncesTOCOnlyTitles() throws {
    let plan = try plan(.mistbornShape())

    XCTAssertEqual(
      plan.chapters.map(\.title),
      ["Dedication", "Prologue", "Part One: The Survivor of Hathsin", "Chapter 1", "Chapter 2"])

    let chapter1 = try XCTUnwrap(plan.chapters.first(where: { $0.title == "Chapter 1" }))
    XCTAssertEqual(chapter1.announcement?.sentences, ["Chapter 1."])
    XCTAssertEqual(
      chapter1.paragraphs.first?.sentences, ["Vin watched the crew from the shadows."],
      "the bare '1' heading paragraph is absorbed by the announcement")

    let prologue = try XCTUnwrap(plan.chapters.first(where: { $0.title == "Prologue" }))
    XCTAssertNil(prologue.announcement, "body already opens with 'Prologue'")
  }

  func testSectionOverridesFlipDefaults() throws {
    var options = PlanOptions()
    options.includeSections = ["copyright"]
    options.excludeSections = ["2-silent-spring"]
    let plan = try plan(.threeBodyShape(), options: options)

    XCTAssertTrue(plan.chapters.contains(where: { $0.title == "Copyright" }))
    XCTAssertFalse(plan.chapters.contains(where: { $0.title == "2. Silent Spring" }))

    let copyright = try XCTUnwrap(plan.sections.first(where: { $0.role == .copyright }))
    XCTAssertTrue(copyright.included)
    XCTAssertFalse(copyright.includedByDefault)
  }

  func testUnknownOverrideTokenFailsLoudly() throws {
    var options = PlanOptions()
    options.excludeSections = ["no-such-slug"]
    let url = try EPUBFixture.mistbornShape().write()
    fixtureURLs.append(url)
    let book = try EPUBBook.load(url: url)
    XCTAssertThrowsError(try AudiobookPlanner.plan(book: book, options: options)) { error in
      guard case AudiobookPlanError.unknownSection("no-such-slug") = error else {
        return XCTFail("unexpected error: \(error)")
      }
    }
  }

  func testSpineOnlyBookGetsSyntheticUnannouncedChapters() throws {
    let plan = try plan(.spineOnlyShape())

    XCTAssertEqual(plan.chapters.map(\.title), ["First Part", "Section 2"])
    XCTAssertTrue(plan.chapters.allSatisfy { $0.announcement == nil })
  }

  func testEPUB2NotesFileExcludedViaGuideAndHeuristics() throws {
    let plan = try plan(.epub2Shape())

    let notes = try XCTUnwrap(plan.sections.first(where: { $0.role == .notes }))
    XCTAssertFalse(notes.included)
    XCTAssertEqual(
      plan.chapters.map(\.title), ["Chapter One", "Chapter Two"],
      "cover (guide) and notes (guide/tier-3) are excluded by default")

    // The EPUB 2 sup-anchor footnote marker is gone from chapter text.
    let chapterOne = plan.chapters[0]
    let text = chapterOne.allParagraphs.flatMap(\.sentences).joined(separator: " ")
    XCTAssertFalse(text.contains("1"), "marker digit must not be narrated: \(text)")
  }

  /// An excluded chapter drops its whole spine range (excerpt spillover), but
  /// the section listing must reflect that honestly, and an explicit include
  /// override inside the range must rescue that section as its own chapter.
  func testExcludedAnchorRangeIsHonestAndExplicitIncludeRescues() throws {
    var fixture = EPUBFixture()
    fixture.title = "Range Fixture"
    fixture.documents = [
      EPUBFixture.Document(
        id: "ch1", path: "OEBPS/ch1.xhtml",
        xhtml: EPUBFixture.xhtml(body: "<h1>Chapter One</h1><p>Real prose.</p>")),
      EPUBFixture.Document(
        id: "excerpt", path: "OEBPS/excerpt.xhtml",
        xhtml: EPUBFixture.xhtml(body: "<p>Excerpt opening.</p>")),
      EPUBFixture.Document(
        id: "qa", path: "OEBPS/qa.xhtml",
        xhtml: EPUBFixture.xhtml(body: "<h1>Author Interview</h1><p>Q and A text.</p>")),
    ]
    fixture.navXHTML = EPUBFixture.nav(
      tocItems: """
        <li><a href="ch1.xhtml">Chapter One</a></li>
        <li><a href="excerpt.xhtml">Excerpt from Book Two</a></li>
        """,
      landmarks: """
        <li><a epub:type="bodymatter" href="ch1.xhtml">Begin Reading</a></li>
        """)

    let defaultPlan = try plan(fixture)
    XCTAssertEqual(defaultPlan.chapters.map(\.title), ["Chapter One"])
    let interviewSection = try XCTUnwrap(
      defaultPlan.sections.first(where: { $0.spineIndex == 2 }))
    XCTAssertFalse(
      interviewSection.included,
      "a section that is not narrated must not be listed (or fingerprinted) as included")

    var options = PlanOptions()
    options.includeSections = ["2"]
    let rescued = try plan(fixture, options: options)
    XCTAssertEqual(rescued.chapters.map(\.title), ["Chapter One", "Author Interview"])
    XCTAssertTrue(
      try XCTUnwrap(rescued.sections.first(where: { $0.spineIndex == 2 })).included)
  }

  func testMaxChaptersTruncates() throws {
    var options = PlanOptions()
    options.maxChapters = 2
    let plan = try plan(.mistbornShape(), options: options)
    XCTAssertEqual(plan.chapters.count, 2)
  }

  func testAnnouncementsCanBeDisabledGlobally() throws {
    var options = PlanOptions()
    options.announceTitles = false
    let plan = try plan(.mistbornShape(), options: options)
    XCTAssertTrue(plan.chapters.allSatisfy { $0.announcement == nil })
    let chapter1 = try XCTUnwrap(plan.chapters.first(where: { $0.title == "Chapter 1" }))
    XCTAssertEqual(
      chapter1.paragraphs.first?.sentences, ["1"],
      "absorption is disabled with announcements: the body is narrated verbatim")
  }

  func testExcludingEverythingFails() throws {
    var options = PlanOptions()
    options.excludeSections = (0...5).map(String.init)
    let url = try EPUBFixture.mistbornShape().write()
    fixtureURLs.append(url)
    let book = try EPUBBook.load(url: url)
    XCTAssertThrowsError(try AudiobookPlanner.plan(book: book, options: options)) { error in
      guard case AudiobookPlanError.noNarratableContent = error else {
        return XCTFail("unexpected error: \(error)")
      }
    }
  }
}

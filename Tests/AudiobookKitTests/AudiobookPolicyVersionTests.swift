import XCTest

@testable import AudiobookKit

final class AudiobookPolicyVersionTests: XCTestCase {
  func testExtractorVersionIsStable() {
    // Bump this assertion together with deliberate extraction-behavior
    // changes; it exists to catch accidental ones.
    // v9: glued plain-text endnote markers (`word.[12]`) are removed in
    // dense ascending runs, and zero-width formatting (ZWSP/WORD JOINER/
    // ZWNBSP) no longer reaches narration.
    // v10: citation tables (anchor-wrapped ascending number cells) and
    // their labels are note apparatus; untitled index files classify by
    // structure; index title vocabulary extended.
    // v11: presentational all-caps occurrences fold to the book's attested
    // mixed-case twin under the four-condition evidence gate.
    // v12: engine-refused double-bracket sequences degrade to single
    // brackets so bracketed words keep narrating.
    // v13: untitled spine files dominated by structural label lines
    // classify as printed TOC instead of narrating chapter lists.
    XCTAssertEqual(AudiobookPolicyVersions.extractorVersion, 13)
  }

  func testSynthesisPolicyVersionIsStable() {
    // v3: refused speechless units fall back to silence instead of aborting.
    XCTAssertEqual(NarrationUnitPlanner.synthesisPolicyVersion, 3)
  }
}

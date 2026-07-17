import XCTest

@testable import AudiobookKit

final class AudiobookPolicyVersionTests: XCTestCase {
  func testExtractorVersionIsStable() {
    // Bump this assertion together with deliberate extraction-behavior
    // changes; it exists to catch accidental ones.
    XCTAssertEqual(AudiobookPolicyVersions.extractorVersion, 8)
  }

  func testSynthesisPolicyVersionIsStable() {
    XCTAssertEqual(NarrationUnitPlanner.synthesisPolicyVersion, 2)
  }
}

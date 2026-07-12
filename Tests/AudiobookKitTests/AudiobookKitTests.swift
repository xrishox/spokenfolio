import XCTest

@testable import AudiobookKit

final class AudiobookKitTests: XCTestCase {
  func testExtractorVersionIsStable() {
    // Bump this assertion together with deliberate extraction-behavior
    // changes; it exists to catch accidental ones.
    XCTAssertEqual(AudiobookKitInfo.extractorVersion, 3)
  }
}

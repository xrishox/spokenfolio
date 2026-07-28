import XCTest

@testable import AudiobookKit

final class AudiobookConfigTests: XCTestCase {
  func testWorkerResolutionPreservesExplicitPrecedence() {
    XCTAssertEqual(
      AudiobookConfig(maxWorkers: 4).resolvedMaxWorkers(explicit: 7, recommended: 1), 7)
    XCTAssertEqual(
      AudiobookConfig(maxWorkers: 4).resolvedMaxWorkers(explicit: nil, recommended: 1), 4)
    XCTAssertEqual(
      AudiobookConfig(maxWorkers: 0).resolvedMaxWorkers(explicit: nil, recommended: 1), 1)
    XCTAssertEqual(
      AudiobookConfig(maxWorkers: 0).resolvedMaxWorkers(explicit: nil, recommended: nil),
      AudiobookConfig.autoMaxWorkers)
  }
}

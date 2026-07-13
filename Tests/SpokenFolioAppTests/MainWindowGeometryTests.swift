import AppKit
import XCTest

@testable import SpokenFolioApp

final class MainWindowGeometryTests: XCTestCase {
  func testCoordinatorProcessLivenessRejectsMissingPID() {
    XCTAssertTrue(
      StudioJobCoordinator.processIsAlive(ProcessInfo.processInfo.processIdentifier))
    XCTAssertFalse(StudioJobCoordinator.processIsAlive(nil))
    XCTAssertFalse(StudioJobCoordinator.processIsAlive(Int32.max))
  }

  func testOversizedOrOffscreenWindowIsFittedInsideVisibleFrame() {
    let visible = NSRect(x: 0, y: 0, width: 900, height: 600)
    let result = MainWindowGeometry.fittedFrame(
      NSRect(x: -500, y: 500, width: 1_400, height: 1_000), visibleFrame: visible)
    let available = visible.insetBy(
      dx: MainWindowGeometry.margin, dy: MainWindowGeometry.margin)

    XCTAssertTrue(available.contains(result))
    XCTAssertEqual(result.size, available.size)
  }

  func testMinimumContentSizeShrinksForSmallDisplays() {
    let result = MainWindowGeometry.minimumContentSize(
      visibleFrame: NSRect(x: 0, y: 0, width: 700, height: 480))

    XCTAssertEqual(result.width, 660)
    XCTAssertEqual(result.height, 440)
  }
}

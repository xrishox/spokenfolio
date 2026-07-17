import AppKit
import XCTest

@testable import SpokenFolioApp

final class MainWindowGeometryTests: XCTestCase {
  func testDisplayEndpointRespectsConfiguredBindHost() {
    XCTAssertEqual(ApplicationRuntime.endpoint(host: "127.0.0.1", port: 8787), "http://localhost:8787")
    XCTAssertEqual(ApplicationRuntime.endpoint(host: "mas", port: 8002), "http://mas:8002")
    XCTAssertEqual(ApplicationRuntime.endpoint(host: "::1", port: 8787), "http://localhost:8787")
    XCTAssertEqual(ApplicationRuntime.endpoint(host: "fe80::1", port: 8787), "http://[fe80::1]:8787")
    XCTAssertFalse(
      ApplicationRuntime.endpoint(host: "0.0.0.0", port: 8787).contains(" "))
  }

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

    XCTAssertEqual(result.width, 668)
    XCTAssertEqual(result.height, 448)
  }

  func testUndersizedRestoredWindowGrowsToUsableMinimum() {
    let visible = NSRect(x: 0, y: 0, width: 1_440, height: 900)
    let result = MainWindowGeometry.fittedFrame(
      NSRect(x: 200, y: 200, width: 640, height: 420),
      visibleFrame: visible,
      minimumFrameSize: NSSize(width: 932, height: 660))

    XCTAssertEqual(result.width, 932)
    XCTAssertEqual(result.height, 660)
    XCTAssertTrue(visible.insetBy(dx: 16, dy: 16).contains(result))
  }

  func testTinyDisplayWinsOverNominalMinimumWithoutGoingOffscreen() {
    let visible = NSRect(x: 0, y: 0, width: 820, height: 560)
    let result = MainWindowGeometry.fittedFrame(
      NSRect(x: -100, y: 900, width: 600, height: 400),
      visibleFrame: visible,
      minimumFrameSize: NSSize(width: 932, height: 660))
    let available = visible.insetBy(dx: 16, dy: 16)

    XCTAssertEqual(result.size, available.size)
    XCTAssertTrue(available.contains(result))
  }

  func testDegenerateVisibleFrameLeavesWindowFrameUntouched() {
    let frame = NSRect(x: 100, y: 100, width: 1_000, height: 700)
    let result = MainWindowGeometry.fittedFrame(
      frame, visibleFrame: NSRect(x: 0, y: 0, width: 20, height: 20))

    XCTAssertEqual(result, frame)
  }

  func testFrameAlreadyInsideVisibleFrameIsPreservedExactly() {
    let visible = NSRect(x: 0, y: 0, width: 2_560, height: 1_415)
    let frame = NSRect(x: 400, y: 300, width: 1_000, height: 700)
    let result = MainWindowGeometry.fittedFrame(frame, visibleFrame: visible)

    XCTAssertEqual(result, frame)
  }

  func testRestorationPicksScreenSharingMostAreaWithSavedFrame() {
    let laptop = NSRect(x: 0, y: 0, width: 1_512, height: 945)
    let external = NSRect(x: 1_512, y: 0, width: 2_560, height: 1_415)
    // Saved mostly on the external display, spilling onto the laptop.
    let saved = NSRect(x: 1_300, y: 100, width: 1_200, height: 800)

    let result = MainWindowGeometry.restorationVisibleFrame(
      windowFrame: saved,
      screenVisibleFrames: [laptop, external],
      mainVisibleFrame: laptop)

    XCTAssertEqual(result, external)
  }

  func testRestorationFallsBackToMainScreenWhenSavedDisplayIsGone() {
    let laptop = NSRect(x: 0, y: 0, width: 1_512, height: 945)
    // Saved entirely on a display that is no longer attached.
    let saved = NSRect(x: 3_000, y: 100, width: 1_200, height: 800)

    let result = MainWindowGeometry.restorationVisibleFrame(
      windowFrame: saved,
      screenVisibleFrames: [laptop],
      mainVisibleFrame: laptop)

    XCTAssertEqual(result, laptop)
  }
}

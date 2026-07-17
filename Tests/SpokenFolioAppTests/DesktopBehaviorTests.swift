import Foundation
import XCTest

@testable import SpokenFolioApp

@MainActor
final class DesktopBehaviorTests: XCTestCase {
  func testTerminationDecisionCoversTheQuitMatrix() {
    func decide(
      graceful: Bool = false, inProgress: Bool = false,
      running: Int = 0, drafts: Int = 0, system: Bool = false
    ) -> DesktopApplication.TerminationDecision {
      DesktopApplication.terminationDecision(
        gracefulShutdownCompleted: graceful, terminationInProgress: inProgress,
        runningJobs: running, unqueuedDrafts: drafts, systemInitiated: system)
    }

    XCTAssertEqual(decide(graceful: true), .terminateNow)
    // A duplicate Cmd-Q during shutdown changes nothing.
    XCTAssertEqual(decide(inProgress: true, running: 1), .cancelDuplicateRequest)
    XCTAssertEqual(decide(), .shutdown)
    XCTAssertEqual(decide(running: 1), .confirm)
    XCTAssertEqual(decide(drafts: 2), .confirm)
    // Logout, restart, and shutdown terminate immediately with best-effort
    // teardown: durable state tolerates it, and an async pause could hold
    // the whole session hostage.
    XCTAssertEqual(decide(system: true), .terminateImmediately)
    XCTAssertEqual(decide(running: 1, system: true), .terminateImmediately)
    XCTAssertEqual(decide(drafts: 2, system: true), .terminateImmediately)
    XCTAssertEqual(decide(inProgress: true, system: true), .terminateImmediately)
  }

  func testAdditionNoticeReportsSkippedFilesInstadOfSilence() {
    XCTAssertNil(StudioCreateModel.additionNotice(duplicates: 0, unsupported: 0))
    XCTAssertEqual(
      StudioCreateModel.additionNotice(duplicates: 1, unsupported: 0),
      "Skipped 1 already-imported EPUB.")
    XCTAssertEqual(
      StudioCreateModel.additionNotice(duplicates: 0, unsupported: 3),
      "Skipped 3 files without an .epub extension.")
    XCTAssertEqual(
      StudioCreateModel.additionNotice(duplicates: 2, unsupported: 1),
      "Skipped 2 already-imported EPUBs and 1 file without an .epub extension.")
  }

  func testUnqueuedDraftCountCountsEverythingExceptQueuedDrafts() {
    let coordinator = StudioJobCoordinator()
    let model = StudioCreateModel(coordinator: coordinator)
    XCTAssertEqual(model.unqueuedDraftCount, 0)
    XCTAssertFalse(model.hasUnqueuedDrafts)

    model.addBooks([
      URL(fileURLWithPath: "/nonexistent/a.epub"),
      URL(fileURLWithPath: "/nonexistent/b.epub"),
    ])
    XCTAssertEqual(model.unqueuedDraftCount, 2)
    XCTAssertTrue(model.hasUnqueuedDrafts)
  }

  func testAddBooksSkipsDuplicatesWithinOneDropAndReportsThem() {
    let coordinator = StudioJobCoordinator()
    let model = StudioCreateModel(coordinator: coordinator)
    model.addBooks([
      URL(fileURLWithPath: "/nonexistent/a.epub"),
      URL(fileURLWithPath: "/nonexistent/a.epub"),
      URL(fileURLWithPath: "/nonexistent/notes.pdf"),
    ])

    XCTAssertEqual(model.drafts.count, 1)
    XCTAssertEqual(
      model.notice,
      "Skipped 1 already-imported EPUB and 1 file without an .epub extension.")
  }
}

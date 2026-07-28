import Foundation
import XCTest

@testable import SpokenFolioApp

/// Leases, not snapshots, are what keep two operations off the same book: a
/// check that has already returned cannot stop work that starts a moment
/// later.
final class LibraryMutationCoordinatorTests: XCTestCase {
  private let editionID = UUID()
  private let remoteBookID = UUID()

  func testASecondHolderIsRefusedWhileTheFirstStillHoldsTheKey() async {
    let coordinator = LibraryMutationCoordinator()
    let keys: Set<LibraryMutationCoordinator.Key> = [.edition(editionID), .row("row-1")]

    guard case .success(let lease) = await coordinator.acquire(keys, for: .production) else {
      return XCTFail("the first acquire must succeed")
    }
    guard case .failure(let refusal) = await coordinator.acquire(keys, for: .deletion) else {
      return XCTFail("a held book must not be leased twice")
    }
    XCTAssertTrue(refusal.reason.contains("production job"), refusal.reason)

    await coordinator.release(lease)
    guard case .success = await coordinator.acquire(keys, for: .deletion) else {
      return XCTFail("release must free every key it took")
    }
  }

  /// Overlap on any single key is a conflict, and a refused acquire takes
  /// nothing — otherwise a partially-taken set would deadlock the free keys.
  func testPartialOverlapConflictsAndLeavesFreeKeysAvailable() async {
    let coordinator = LibraryMutationCoordinator()
    guard
      case .success = await coordinator.acquire([.remoteBook(remoteBookID)], for: .download)
    else { return XCTFail("acquire failed") }

    guard
      case .failure = await coordinator.acquire(
        [.edition(editionID), .remoteBook(remoteBookID)], for: .deletion)
    else { return XCTFail("an overlapping set must be refused") }

    guard case .success = await coordinator.acquire([.edition(editionID)], for: .quality) else {
      return XCTFail("the refused acquire must not have taken the free key")
    }
  }

  /// A deletion must also refuse when durable queued work names the book: it
  /// holds no in-memory lease but would start against a book that is gone.
  func testDeletionRefusesDurableQueuedWorkAndKeepsNoLease() async {
    let blocked = LibraryMutationCoordinator.Key.edition(editionID)
    let coordinator = LibraryMutationCoordinator { keys in
      keys.contains(blocked) ? "a production job for this book is queued" : nil
    }

    guard
      case .failure(let refusal) = await coordinator.acquireForDeletion([.edition(editionID)])
    else { return XCTFail("queued work must block deletion") }
    XCTAssertTrue(refusal.reason.contains("queued"), refusal.reason)

    // The refused deletion released what it briefly took.
    guard case .success = await coordinator.acquire([.edition(editionID)], for: .production) else {
      return XCTFail("a refused deletion must not keep the key")
    }
  }

  /// Only orphaned production leases may be broken: a recognized production
  /// lease (a lane actually running) and every non-production holder survive.
  func testReclaimBreaksOnlyUnrecognizedProductionLeases() async {
    let coordinator = LibraryMutationCoordinator()
    let key = LibraryMutationCoordinator.Key.edition(editionID)

    guard case .success(let live) = await coordinator.acquire([key], for: .production)
    else { return XCTFail("acquire failed") }
    // Recognized: the scheduler knows this lease — never broken.
    let kept = await coordinator.reclaimOrphanedProductionLeases(
      [key], recognizedLeaseIDs: [live.id])
    XCTAssertFalse(kept)
    let afterKept = await coordinator.currentHolder(of: key)
    XCTAssertEqual(afterKept, .production)

    // Unrecognized: an orphan — broken, and the key is claimable again.
    let broken = await coordinator.reclaimOrphanedProductionLeases(
      [key], recognizedLeaseIDs: [])
    XCTAssertTrue(broken)
    let afterBroken = await coordinator.currentHolder(of: key)
    XCTAssertNil(afterBroken)

    // A non-production holder is never touched, recognized or not.
    guard case .success = await coordinator.acquire([key], for: .download)
    else { return XCTFail("acquire failed") }
    let downloadBroken = await coordinator.reclaimOrphanedProductionLeases(
      [key], recognizedLeaseIDs: [])
    XCTAssertFalse(downloadBroken)
    let downloadHolder = await coordinator.currentHolder(of: key)
    XCTAssertEqual(downloadHolder, .download)
  }

  func testDeletionSucceedsWhenNothingElseOwnsTheBook() async {
    let coordinator = LibraryMutationCoordinator()
    guard case .success = await coordinator.acquireForDeletion([.edition(editionID)]) else {
      return XCTFail("an idle book must be deletable")
    }
    let holder = await coordinator.currentHolder(of: .edition(editionID))
    XCTAssertEqual(holder, .deletion)
  }
}

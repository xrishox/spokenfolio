import Foundation
import LibraryKit
import ReadAloudKit
import StorytellerKit
@testable import SpokenFolioApp
import XCTest

@MainActor
final class ReadAloudQualityQueueTests: XCTestCase {
  func testQueuePlannerDeduplicatesExcludesActiveAndKeepsValidFIFOTime() {
    let active = LibraryReadAloudAuditTarget.standalone(path: "/tmp/active.epub")
    let first = LibraryReadAloudAuditTarget.standalone(path: "/tmp/first.epub")
    let second = LibraryReadAloudAuditTarget.standalone(path: "/tmp/second.epub")
    let now = Date(timeIntervalSince1970: 1_000)

    let runs = ReadAloudQualityModel.queueRuns(
      targets: [active, first, first, second], excluding: [active],
      mode: .thorough, now: now)

    XCTAssertEqual(runs.map(\.target), [first, second])
    XCTAssertTrue(runs.allSatisfy { $0.lifecycle == .queued })
    XCTAssertTrue(runs.allSatisfy { $0.mode == ReadAloudAuditMode.thorough.rawValue })
    XCTAssertTrue(runs.allSatisfy { $0.startedAt == $0.updatedAt })
    XCTAssertEqual(runs[0].startedAt, now)
    XCTAssertGreaterThan(runs[1].startedAt, runs[0].startedAt)
  }

  func testRemoteTargetPlannerSupportsWholeLibrarySelection() {
    let connectionID = UUID()
    let books = (0..<187).map { index in
      StorytellerBook(
        uuid: UUID(), title: "Book \(index)", authors: [], narrators: [], identifiers: [],
        ebook: nil, audiobook: nil,
        readaloud: StorytellerAsset(
          uuid: UUID(), filepath: "book-\(index).epub", fileSize: 1))
    }
    let selected = Set(books.map(\.uuid))
    let targets = ReadAloudQualityModel.remoteTargets(
      connectionID: connectionID, books: books, selectedBookIDs: selected)
    XCTAssertEqual(targets.count, 187)
    XCTAssertEqual(Set(targets).count, 187)
  }

  func testAutomaticAuditWaitsForAlignedAvailableAsset() {
    let connectionID = UUID()
    let bookID = UUID()
    let assetID = UUID()
    func book(status: String, size: UInt64? = 1) -> StorytellerBook {
      StorytellerBook(
        uuid: bookID, title: "Book",
        readaloud: StorytellerAsset(
          uuid: assetID, filepath: "book.epub", fileSize: size, status: status))
    }

    XCTAssertEqual(
      ReadAloudQualityModel.automaticAuditResolution(
        connectionID: connectionID, book: book(status: "PROCESSING")),
      .waiting)
    XCTAssertEqual(
      ReadAloudQualityModel.automaticAuditResolution(
        connectionID: connectionID, book: book(status: "ALIGNED", size: nil)),
      .waiting)
    XCTAssertEqual(
      ReadAloudQualityModel.automaticAuditResolution(
        connectionID: connectionID, book: book(status: "ALIGNED")),
      .ready(.remote(connectionID: connectionID, bookID: bookID, assetID: assetID)))
    guard case .failed = ReadAloudQualityModel.automaticAuditResolution(
      connectionID: connectionID, book: book(status: "ERROR"))
    else { return XCTFail("ERROR processing must terminate the automatic intent") }
  }

  func testQualityWorkspaceDefaultsToAllArtifactsAndKeepsQueueSeparate() {
    let model = ReadAloudQualityModel()
    let queued = LibraryReadAloudAuditRun(
      target: .standalone(path: "/tmp/queued.epub"), mode: "standard")
    model.audits = [queued]

    XCTAssertEqual(model.artifactScope, .all)
    XCTAssertEqual(model.queueAudits.map(\.id), [queued.id])
  }

  func testArtifactSelectionRetainsMultipleRowsAndDropsOnlyUnavailableRows() {
    func artifact(_ id: String) -> ReadAloudQualityModel.Artifact {
      .init(
        id: id, target: .standalone(path: "/tmp/\(id).epub"), title: id,
        author: nil, source: "Local file", artifactSHA256: nil,
        referenceSHA256: nil, history: [])
    }
    let artifacts = [artifact("one"), artifact("two"), artifact("three")]

    XCTAssertEqual(
      ReadAloudQualityModel.validArtifactSelection(
        ["one", "three", "stale"], artifacts: artifacts),
      ["one", "three"])
  }

  func testGracefulApplicationInterruptionReturnsActiveAuditToQueue() {
    let target = LibraryReadAloudAuditTarget.standalone(path: "/tmp/book.epub")
    let date = Date(timeIntervalSince1970: 20_000)
    var run = LibraryReadAloudAuditRun(
      target: target, artifactSHA256: String(repeating: "a", count: 64),
      referenceSHA256: String(repeating: "b", count: 64), mode: "standard",
      lifecycle: .cancelled, progress: 0.7, progressMessage: "Cancelled",
      verdict: "inconclusive", evidenceAdequacy: "sampled",
      metricsData: Data("{}".utf8), reportData: Data("{}".utf8),
      completedAt: date, error: "Audit cancelled",
      findings: [
        .init(
          dimension: "timing", code: "cancelled", verdict: "inconclusive",
          confidence: "weak", summary: "Partial result")
      ])
    run.modelIdentity = "partial-model"

    let queued = ReadAloudQualityModel.requeuedAfterGracefulInterruption(run, at: date)
    XCTAssertEqual(queued.lifecycle, .queued)
    XCTAssertEqual(queued.progress, 0)
    XCTAssertEqual(queued.progressMessage, "Queued after application restart")
    XCTAssertNil(queued.completedAt)
    XCTAssertNil(queued.error)
    XCTAssertNil(queued.reportData)
    XCTAssertTrue(queued.findings.isEmpty)
  }

  func testClearingQueueCancelsOnlyWaitingAudits() {
    let date = Date(timeIntervalSince1970: 30_000)
    let queued = LibraryReadAloudAuditRun(
      target: .standalone(path: "/tmp/queued.epub"), mode: "standard")
    let completed = LibraryReadAloudAuditRun(
      target: .standalone(path: "/tmp/completed.epub"), mode: "standard",
      lifecycle: .completed, progress: 1, verdict: "likelyCorrect",
      completedAt: date)

    let changed = ReadAloudQualityModel.cancelledWaitingRuns([queued, completed], at: date)
    XCTAssertEqual(changed.count, 1)
    XCTAssertEqual(changed.first?.id, queued.id)
    XCTAssertEqual(changed.first?.lifecycle, .cancelled)
    XCTAssertEqual(changed.first?.progressMessage, "Removed from queue")
    // Timestamps clamp to startedAt so a transition can never produce an
    // updatedAt-before-startedAt record the store would reject.
    XCTAssertEqual(changed.first?.completedAt, max(date, queued.startedAt))
    XCTAssertEqual(changed.first?.updatedAt, changed.first?.completedAt)
  }

  func testArtifactKeepsApplicableSemanticResultWhenNewerAttemptFails() {
    let target = LibraryReadAloudAuditTarget.standalone(path: "/tmp/book.epub")
    let hash = String(repeating: "a", count: 64)
    let completed = LibraryReadAloudAuditRun(
      target: target, artifactSHA256: hash,
      policyVersion: ReadAloudQualityAuditor.policyVersion, mode: "standard",
      lifecycle: .completed, progress: 1, verdict: "likelyCorrect")
    let failed = LibraryReadAloudAuditRun(
      target: target, mode: "standard", lifecycle: .failed,
      progressMessage: "Failed", error: "decoder unavailable")
    let artifact = ReadAloudQualityModel.Artifact(
      id: "file:/tmp/book.epub", target: target, title: "Book", author: nil,
      source: "Local file", artifactSHA256: hash, referenceSHA256: nil,
      history: [failed, completed])

    XCTAssertEqual(artifact.latestResult?.id, completed.id)
    XCTAssertEqual(artifact.outcomeLabel, "Likely correct")
  }

  func testArtifactDoesNotPresentACompletedResultForSupersededBytes() {
    let target = LibraryReadAloudAuditTarget.standalone(path: "/tmp/book.epub")
    let old = LibraryReadAloudAuditRun(
      target: target, artifactSHA256: String(repeating: "a", count: 64),
      mode: "standard", lifecycle: .completed, progress: 1,
      verdict: "likelyCorrect")
    let artifact = ReadAloudQualityModel.Artifact(
      id: "file:/tmp/book.epub", target: target, title: "Book", author: nil,
      source: "Local file", artifactSHA256: String(repeating: "b", count: 64),
      referenceSHA256: nil, history: [old])

    XCTAssertNil(artifact.latestResult)
    XCTAssertEqual(artifact.outcomeLabel, "Not checked")
  }
}

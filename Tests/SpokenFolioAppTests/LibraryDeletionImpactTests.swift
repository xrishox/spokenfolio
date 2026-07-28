import BookJobKit
import Foundation
import LibraryKit
import XCTest

@testable import SpokenFolioApp

/// The pure per-book deletion manifest: what each selected slot + scope
/// actually removes, aggregated across a multi-selection, skipping absent
/// slots instead of blocking.
final class LibraryDeletionImpactTests: XCTestCase {
  private let connectionID = UUID()
  private let remoteBookID = UUID()
  private let sourceSHA = String(repeating: "a", count: 64)

  private func remoteAsset(
    _ format: LibraryRemoteFormat, id: UUID = UUID(),
    state: LibraryRemoteAssetState = .ready
  ) -> LibraryRemoteAssetSnapshot {
    .init(format: format, assetID: id, fileSize: 1000, sha256: nil, state: state)
  }

  private func remote(_ assets: [LibraryRemoteAssetSnapshot]) -> LibraryRemoteBookSnapshot {
    .init(connectionID: connectionID, remoteBookID: remoteBookID, title: "Fixture", assets: assets)
  }

  private func product(_ kind: BookProductKind, _ sha: String) -> BookCatalogProduct {
    .init(kind: kind, path: "/tmp/\(kind.rawValue)", size: 1000, sha256: sha, verifiedAt: Date())
  }

  private func record(_ products: [BookCatalogProduct]) -> BookCatalogRecord {
    BookCatalogRecord(
      source: .init(format: "epub", importerVersion: 1, sha256: sourceSHA, size: 10),
      metadata: .init(title: "Fixture", author: nil),
      outputDirectory: "/tmp/book", outputBaseName: "fixture",
      products: [product(.sourceEPUB, sourceSHA)] + products)
  }

  private func book(
    record: BookCatalogRecord?, remote: LibraryRemoteBookSnapshot? = nil,
    narration: NarrationProvenance = .unknown
  ) -> LibraryDeletePlanner.Book {
    .init(id: "row", title: "Fixture", record: record, remote: remote, remoteNarration: narration)
  }

  private func selection(
    _ slots: Set<BookProductKind>, _ scope: LibraryDeletePlanner.Scope
  ) -> LibraryDeletePlanner.Selection {
    .init(slots: slots, scope: scope)
  }

  func testLocalOnlyDeletesPresentSlotsAndDropsAbsentOnes() {
    let m4bSHA = String(repeating: "b", count: 64)
    let impact = LibraryDeletePlanner.deletionImpact(
      book: book(record: record([product(.m4b, m4bSHA)])),
      // ReadAloud is selected but not present → silently skipped, not an error.
      selection: selection([.m4b, .readAloudEPUB], .local))
    let unwrapped = try! XCTUnwrap(impact)
    XCTAssertEqual(unwrapped.localSlots.map(\.kind), [.m4b])
    XCTAssertEqual(unwrapped.localSlots.first?.sha256, m4bSHA)
    XCTAssertFalse(unwrapped.wholeBookLocal)
    XCTAssertTrue(unwrapped.remoteSlots.isEmpty, "local scope must not touch remote")
  }

  func testSourceSlotIsAWholeBookLocalDelete() {
    let impact = try! XCTUnwrap(
      LibraryDeletePlanner.deletionImpact(
        book: book(record: record([product(.m4b, String(repeating: "b", count: 64))])),
        selection: selection([.sourceEPUB, .m4b], .local)))
    XCTAssertTrue(impact.wholeBookLocal)
    XCTAssertEqual(impact.sourceSHA256, sourceSHA)
    XCTAssertEqual(impact.outputDirectory, "/tmp/book")
    // A whole-book delete supersedes individual local slots.
    XCTAssertTrue(impact.localSlots.isEmpty)
  }

  func testStorytellerScopeDeletesReadyAssetsOnlyNeverLocal() {
    let audiobookID = UUID()
    let impact = try! XCTUnwrap(
      LibraryDeletePlanner.deletionImpact(
        book: book(
          record: record([product(.m4b, String(repeating: "b", count: 64))]),
          remote: remote([
            remoteAsset(.audiobook, id: audiobookID),
            remoteAsset(.readaloud, state: .processing),  // not ready → skipped
          ]),
          narration: .human),
        selection: selection([.m4b, .readAloudEPUB], .storyteller)))
    XCTAssertTrue(impact.localSlots.isEmpty, "storyteller scope must not delete local files")
    XCTAssertEqual(impact.remoteSlots.map(\.format), [.audiobook])
    XCTAssertEqual(impact.remoteSlots.first?.assetID, audiobookID)
    XCTAssertTrue(impact.remoteSlots.first?.humanNarration == true)
    XCTAssertTrue(impact.losesHumanContent)
    XCTAssertEqual(impact.connectionID, connectionID)
    XCTAssertEqual(impact.expectedRemoteAssets.map(\.format), ["audiobook"])
  }

  func testBothScopeCombinesLocalAndRemoteForTheSameSlot() {
    let m4bSHA = String(repeating: "b", count: 64)
    let impact = try! XCTUnwrap(
      LibraryDeletePlanner.deletionImpact(
        book: book(
          record: record([product(.m4b, m4bSHA)]),
          remote: remote([remoteAsset(.audiobook)])),
        selection: selection([.m4b], .both)))
    XCTAssertEqual(impact.localSlots.map(\.kind), [.m4b])
    XCTAssertEqual(impact.remoteSlots.map(\.format), [.audiobook])
  }

  func testHumanAndTTSAudiobookSlotsCollapseToOneRemoteAsset() {
    // Selecting both audiobook variants must target the single remote
    // audiobook asset once, never twice.
    let impact = try! XCTUnwrap(
      LibraryDeletePlanner.deletionImpact(
        book: book(record: record([]), remote: remote([remoteAsset(.audiobook)])),
        selection: selection([.m4b, .humanAudiobook], .storyteller)))
    XCTAssertEqual(impact.remoteSlots.count, 1)
    XCTAssertEqual(impact.remoteSlots.first?.format, .audiobook)
  }

  func testNothingToDoYieldsNilAndPlanSkipsIt() {
    // ReadAloud selected but the book has neither a local nor remote readaloud.
    XCTAssertNil(
      LibraryDeletePlanner.deletionImpact(
        book: book(record: record([]), remote: remote([remoteAsset(.audiobook)])),
        selection: selection([.readAloudEPUB], .both)))
  }

  func testMultiSelectAggregatesAndSkipsMixedPresenceWithoutBlocking() {
    let m4bSHA = String(repeating: "b", count: 64)
    let hasM4B = StudioLibraryRow(
      id: "a", title: "Has M4B", author: nil,
      record: record([product(.m4b, m4bSHA)]), remote: nil, level: .readable,
      presence: .local, narration: .unknown, stale: false, localEPUBReady: true,
      localAudiobookReady: true, localReadAloudReady: false, localReadAloudProductID: nil,
      ttsProvenance: nil, localQualityVerdict: nil, remoteQualityVerdict: nil,
      updatedAt: Date(), searchIndex: "has m4b")
    let noM4B = StudioLibraryRow(
      id: "b", title: "No M4B", author: nil, record: record([]), remote: nil,
      level: .readable, presence: .local, narration: .unknown, stale: false,
      localEPUBReady: true, localAudiobookReady: false, localReadAloudReady: false,
      localReadAloudProductID: nil, ttsProvenance: nil, localQualityVerdict: nil,
      remoteQualityVerdict: nil, updatedAt: Date(), searchIndex: "no m4b")

    let plan = LibraryDeletePlanner.plan(
      rows: [hasM4B, noM4B], selection: selection([.m4b], .local))
    XCTAssertEqual(plan.impacts.map(\.rowID), ["a"])
    XCTAssertEqual(plan.skipped.map(\.rowID), ["b"], "the book lacking the slot is skipped, not blocked")
  }
}

import BookJobKit
import Foundation
import LibraryKit
import XCTest

@testable import SpokenFolioApp

/// The plan-time occupancy gate: a delivery into occupied remote slots must
/// produce a loss manifest unless every targeted slot is provably identical.
final class LibraryReplacementImpactTests: XCTestCase {
  private let connectionID = UUID()
  private let remoteBookID = UUID()

  private func remoteAsset(
    _ format: LibraryRemoteFormat, id: UUID = UUID(), size: UInt64 = 1000,
    sha256: String? = nil, state: LibraryRemoteAssetState = .ready
  ) -> LibraryRemoteAssetSnapshot {
    .init(format: format, assetID: id, fileSize: size, sha256: sha256, state: state)
  }

  private func remote(_ assets: [LibraryRemoteAssetSnapshot]) -> LibraryRemoteBookSnapshot {
    .init(
      connectionID: connectionID, remoteBookID: remoteBookID, title: "Fixture",
      assets: assets)
  }

  private func record(
    products: [BookCatalogProduct], receipts: [BookCatalogRemoteReceipt] = []
  ) -> BookCatalogRecord {
    var record = BookCatalogRecord(
      source: .init(
        format: "epub", importerVersion: 1,
        sha256: String(repeating: "a", count: 64), size: 10),
      metadata: .init(title: "Fixture", author: nil),
      outputDirectory: "/tmp", outputBaseName: "fixture", products: products)
    if !receipts.isEmpty {
      record.upsertRemoteLink(
        .init(
          providerID: "storyteller", connectionID: connectionID,
          remoteBookID: remoteBookID.uuidString.lowercased(),
          evidence: .userConfirmed, receipts: receipts))
    }
    return record
  }

  private func product(_ kind: BookProductKind, sha256: String) -> BookCatalogProduct {
    .init(kind: kind, path: "/tmp/p", size: 1000, sha256: sha256, verifiedAt: Date())
  }

  private func book(
    record: BookCatalogRecord, remote: LibraryRemoteBookSnapshot?,
    narration: NarrationProvenance = .unknown
  ) -> LibraryProcessPlanner.Book {
    let audiobook = record.product(.m4b)
    return .init(
      id: "row", title: "Fixture", author: nil, source: .cataloged(record),
      hasAudiobook: audiobook != nil,
      hasReadAloud: record.product(.readAloudEPUB) != nil,
      audiobookNarration: nil, audiobookAlignsDirectly: false,
      remote: remote, remoteNarration: narration)
  }

  private func toggles(
    sendEPUB: Bool = true, sendM4B: Bool = false, sendReadAloud: Bool = false
  ) -> LibraryProcessPlanner.Toggles {
    .init(
      createMissingAudiobooks: false, recreateExistingAudiobooks: false,
      createMissingReadAlouds: false, recreateExistingReadAlouds: false,
      sendToStoryteller: true, deliveryConnectionID: connectionID,
      sendEPUB: sendEPUB, sendM4B: sendM4B, sendReadAloud: sendReadAloud,
      confirmedRemoteBookID: nil)
  }

  func testFreeSlotsNeedNoReplacement() {
    let sha = String(repeating: "b", count: 64)
    let book = book(record: record(products: [product(.sourceEPUB, sha256: sha)]), remote: remote([]))
    XCTAssertNil(LibraryProcessPlanner.replacementImpact(book: book, toggles: toggles()))
  }

  func testIdenticalViaSnapshotHashNeedsNoReplacement() {
    let sha = String(repeating: "b", count: 64)
    let book = book(
      record: record(products: [product(.sourceEPUB, sha256: sha)]),
      remote: remote([remoteAsset(.ebook, sha256: sha)]))
    XCTAssertNil(LibraryProcessPlanner.replacementImpact(book: book, toggles: toggles()))
  }

  func testIdenticalViaReceiptNeedsNoReplacement() {
    let sha = String(repeating: "b", count: 64)
    let assetID = UUID()
    let book = book(
      record: record(
        products: [product(.sourceEPUB, sha256: sha)],
        receipts: [
          .init(
            format: "ebook", localSHA256: sha,
            remoteAssetID: assetID.uuidString.lowercased())
        ]),
      remote: remote([remoteAsset(.ebook, id: assetID)]))
    XCTAssertNil(LibraryProcessPlanner.replacementImpact(book: book, toggles: toggles()))
  }

  func testDifferentContentListsOnlySentFormats() {
    let localSHA = String(repeating: "b", count: 64)
    let remoteSHA = String(repeating: "c", count: 64)
    // Remote has ebook+audiobook+readaloud; only the EPUB is being sent, so
    // only the EPUB appears in the manifest — per-asset replacement touches
    // nothing else on the book.
    let book = book(
      record: record(products: [product(.sourceEPUB, sha256: localSHA)]),
      remote: remote([
        remoteAsset(.ebook, sha256: remoteSHA),
        remoteAsset(.audiobook),
        remoteAsset(.readaloud),
      ]),
      narration: .human)
    let impact = LibraryProcessPlanner.replacementImpact(book: book, toggles: toggles())
    let unwrapped = try! XCTUnwrap(impact)
    XCTAssertEqual(unwrapped.assets.map(\.format), ["ebook"])
    XCTAssertEqual(unwrapped.replaceFormats, ["ebook"])
    XCTAssertFalse(unwrapped.assets[0].humanNarration)
    XCTAssertFalse(unwrapped.losesHumanAudio)
    XCTAssertEqual(unwrapped.expectedRemoteAssets.map(\.format), ["ebook"])
  }

  func testReplacingHumanNarratedSlotFlagsTheWarning() {
    let localSHA = String(repeating: "b", count: 64)
    let remoteSHA = String(repeating: "c", count: 64)
    var record = record(products: [
      product(.sourceEPUB, sha256: localSHA), product(.readAloudEPUB, sha256: localSHA),
    ])
    _ = record
    let book = book(
      record: record,
      remote: remote([remoteAsset(.readaloud, sha256: remoteSHA)]),
      narration: .human)
    let impact = LibraryProcessPlanner.replacementImpact(
      book: book, toggles: toggles(sendEPUB: false, sendReadAloud: true))
    let unwrapped = try! XCTUnwrap(impact)
    XCTAssertEqual(unwrapped.assets.map(\.format), ["readaloud"])
    XCTAssertTrue(unwrapped.losesHumanAudio)
  }

  func testNonReadyRemoteAssetIsFillableNotReplaceable() {
    // A broken/processing server-side asset does not occupy the slot: the
    // send fills it with no acknowledgment required.
    let sha = String(repeating: "b", count: 64)
    let book = book(
      record: record(products: [
        product(.sourceEPUB, sha256: sha), product(.readAloudEPUB, sha256: sha),
      ]),
      remote: remote([remoteAsset(.readaloud, state: .broken)]))
    XCTAssertNil(
      LibraryProcessPlanner.replacementImpact(
        book: book, toggles: toggles(sendEPUB: false, sendReadAloud: true)))
  }

  func testUnknownEqualityIsConservativelyAConflict() {
    // Occupied slot, no snapshot hash, no receipt: cannot prove identity.
    let sha = String(repeating: "b", count: 64)
    let book = book(
      record: record(products: [product(.sourceEPUB, sha256: sha)]),
      remote: remote([remoteAsset(.ebook)]))
    XCTAssertNotNil(LibraryProcessPlanner.replacementImpact(book: book, toggles: toggles()))
  }

  func testRecreatedProductCannotBeProvenIdentical() {
    // The M4B receipt matches today's product, but the job re-synthesizes it,
    // so the sent content is unknown and the occupied slot conflicts.
    let sha = String(repeating: "b", count: 64)
    let assetID = UUID()
    var toggles = toggles(sendEPUB: false, sendM4B: true)
    toggles.recreateExistingAudiobooks = true
    let book = book(
      record: record(
        products: [product(.m4b, sha256: sha)],
        receipts: [
          .init(
            format: "audiobook", localSHA256: sha,
            remoteAssetID: assetID.uuidString.lowercased())
        ]),
      remote: remote([remoteAsset(.audiobook, id: assetID)]))
    XCTAssertNotNil(LibraryProcessPlanner.replacementImpact(book: book, toggles: toggles))
  }

  func testOtherConnectionSnapshotIsIgnored() {
    let sha = String(repeating: "b", count: 64)
    var other = remote([remoteAsset(.ebook)])
    other.connectionID = UUID()
    let book = book(
      record: record(products: [product(.sourceEPUB, sha256: sha)]), remote: other)
    XCTAssertNil(LibraryProcessPlanner.replacementImpact(book: book, toggles: toggles()))
  }
}

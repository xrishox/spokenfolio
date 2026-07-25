import BookJobKit
import Foundation
import LibraryKit
import StorytellerKit
import XCTest

@testable import SpokenFolioApp

/// The known-on-Storyteller truth model: verified only with a receipt that
/// still matches live metadata AND the current local file; present only when
/// slot attribution is certain; nothing displayed when unknown.
final class LibraryServerSlotsTests: XCTestCase {
  private let connectionID = UUID()
  private let remoteBookID = UUID()

  private func snapshot(
    _ format: LibraryRemoteFormat, id: UUID, size: UInt64 = 100,
    fingerprint: String? = "fp", state: LibraryRemoteAssetState = .ready
  ) -> LibraryRemoteAssetSnapshot {
    .init(format: format, assetID: id, fingerprint: fingerprint, fileSize: size, state: state)
  }

  private func remote(_ assets: [LibraryRemoteAssetSnapshot]) -> LibraryRemoteBookSnapshot {
    .init(connectionID: connectionID, remoteBookID: remoteBookID, title: "F", assets: assets)
  }

  private func record(products: [BookCatalogProduct]) -> BookCatalogRecord {
    .init(
      source: .init(
        format: "epub", importerVersion: 1, sha256: String(repeating: "a", count: 64),
        size: 10),
      metadata: .init(title: "F", author: nil),
      outputDirectory: "/tmp", outputBaseName: "f", products: products)
  }

  private func link(receipts: [BookCatalogRemoteReceipt]) -> BookCatalogRemoteLink {
    .init(
      providerID: "storyteller", connectionID: connectionID,
      remoteBookID: remoteBookID.uuidString.lowercased(),
      evidence: .userConfirmed, receipts: receipts)
  }

  func testVerifiedRequiresReceiptMatchingCurrentLocalFile() {
    let sha = String(repeating: "b", count: 64)
    let assetID = UUID()
    let record = record(products: [
      .init(kind: .sourceEPUB, path: "/tmp/e", size: 100, sha256: sha, verifiedAt: Date())
    ])
    let receipt = BookCatalogRemoteReceipt(
      format: "ebook", localSHA256: sha,
      remoteAssetID: assetID.uuidString.lowercased(), remoteSize: 100,
      remoteFingerprint: "fp", remoteSHA256: sha)
    let slots = LibraryRowBuilder.serverSlots(
      record: record, remote: remote([snapshot(.ebook, id: assetID)]),
      link: link(receipts: [receipt]), provenFormats: [.ebook], narration: .unknown)
    XCTAssertEqual(slots.epub, .verifiedCurrent)
  }

  func testStaleReceiptDowngradesToPresent() {
    // The local EPUB was replaced after delivery: the server holds the OLD
    // file, so the slot is present but no longer verified-current.
    let oldSHA = String(repeating: "b", count: 64)
    let newSHA = String(repeating: "c", count: 64)
    let assetID = UUID()
    let record = record(products: [
      .init(kind: .sourceEPUB, path: "/tmp/e", size: 100, sha256: newSHA, verifiedAt: Date())
    ])
    let receipt = BookCatalogRemoteReceipt(
      format: "ebook", localSHA256: oldSHA,
      remoteAssetID: assetID.uuidString.lowercased(), remoteSHA256: oldSHA)
    let slots = LibraryRowBuilder.serverSlots(
      record: record, remote: remote([snapshot(.ebook, id: assetID)]),
      link: link(receipts: [receipt]), provenFormats: [.ebook], narration: .unknown)
    XCTAssertEqual(slots.epub, .present)
  }

  func testChangedFingerprintDowngradesToPresent() {
    let sha = String(repeating: "b", count: 64)
    let assetID = UUID()
    let record = record(products: [
      .init(kind: .sourceEPUB, path: "/tmp/e", size: 100, sha256: sha, verifiedAt: Date())
    ])
    let receipt = BookCatalogRemoteReceipt(
      format: "ebook", localSHA256: sha,
      remoteAssetID: assetID.uuidString.lowercased(),
      remoteFingerprint: "old-fp", remoteSHA256: sha)
    let slots = LibraryRowBuilder.serverSlots(
      record: record, remote: remote([snapshot(.ebook, id: assetID, fingerprint: "new-fp")]),
      link: link(receipts: [receipt]), provenFormats: [.ebook], narration: .unknown)
    XCTAssertEqual(slots.epub, .present)
  }

  func testUnknownNarrationFollowsTheSlotsViewPlacement() {
    // The slots view renders unknown-narration remote audio in the HUMAN
    // slots as a pending question; the border marks those same chips.
    let slots = LibraryRowBuilder.serverSlots(
      record: record(products: []),
      remote: remote([
        snapshot(.audiobook, id: UUID()), snapshot(.readaloud, id: UUID()),
        snapshot(.ebook, id: UUID()),
      ]),
      link: nil, provenFormats: [], narration: .unknown)
    XCTAssertNil(slots.ttsAudiobook)
    XCTAssertNil(slots.ttsReadAloud)
    XCTAssertEqual(slots.humanAudiobook, .present)
    XCTAssertEqual(slots.humanReadAloud, .present)
    XCTAssertEqual(slots.epub, .present)
  }

  func testKnownNarrationAttributesAudioSlots() {
    let assets = [snapshot(.audiobook, id: UUID()), snapshot(.readaloud, id: UUID())]
    let human = LibraryRowBuilder.serverSlots(
      record: nil, remote: remote(assets), link: nil, provenFormats: [], narration: .human)
    XCTAssertEqual(human.humanAudiobook, .present)
    XCTAssertNil(human.ttsAudiobook)
    let tts = LibraryRowBuilder.serverSlots(
      record: nil, remote: remote(assets), link: nil, provenFormats: [],
      narration: .spokenFolioTTS)
    XCTAssertEqual(tts.ttsAudiobook, .present)
    XCTAssertNil(tts.humanAudiobook)
  }

  func testDownloadedHumanAudiobookVerifiesAgainstItsHumanProduct() {
    // A downloaded human audiobook is cataloged as .humanAudiobook and gets
    // an audiobook receipt; its human slot must verify against THAT product,
    // not the (absent) TTS m4b.
    let sha = String(repeating: "e", count: 64)
    let assetID = UUID()
    var rec = record(products: [
      .init(
        kind: .humanAudiobook, path: "/tmp/h.m4b", size: 100, sha256: sha,
        verifiedAt: Date())
    ])
    rec.upsertRemoteLink(
      link(receipts: [
        BookCatalogRemoteReceipt(
          format: "audiobook", localSHA256: sha,
          remoteAssetID: assetID.uuidString.lowercased(), remoteFingerprint: "fp",
          remoteSHA256: sha)
      ]))
    let slots = LibraryRowBuilder.serverSlots(
      record: rec, remote: remote([snapshot(.audiobook, id: assetID)]),
      link: rec.remoteLinks.first, provenFormats: [.audiobook], narration: .human)
    XCTAssertEqual(slots.humanAudiobook, .verifiedCurrent)
  }

  func testNonReadyAssetDisplaysNothing() {
    let slots = LibraryRowBuilder.serverSlots(
      record: nil, remote: remote([snapshot(.ebook, id: UUID(), state: .broken)]),
      link: nil, provenFormats: [], narration: .unknown)
    XCTAssertNil(slots.epub)
  }

  // MARK: - Recheck decision

  private func liveAsset(_ id: UUID, size: UInt64 = 100) -> StorytellerAsset {
    StorytellerAsset(uuid: id, filepath: "/a", fingerprint: "fp", fileSize: size)
  }

  func testDecideWritesReceiptWhenServerHashMatchesAnyLocalProduct() {
    let tts = String(repeating: "b", count: 64)
    let human = String(repeating: "d", count: 64)
    let id = UUID()
    // The server audiobook is the HUMAN download; it matches the human hash.
    let decision = LibraryRemoteVerificationService.decide(
      liveAsset: liveAsset(id), localHashes: [tts, human], probeHash: human,
      format: .audiobook)
    guard case .write(let receipt) = decision else {
      return XCTFail("expected a receipt, got \(decision)")
    }
    XCTAssertEqual(receipt.remoteAssetID, id.uuidString.lowercased())
    XCTAssertEqual(receipt.localSHA256, human)
    XCTAssertEqual(receipt.remoteSHA256, human)
  }

  func testDecideDropsOnMismatchOrAbsence() {
    let sha = String(repeating: "b", count: 64)
    XCTAssertEqual(
      LibraryRemoteVerificationService.decide(
        liveAsset: liveAsset(UUID()), localHashes: [sha], probeHash: "cc", format: .ebook),
      .drop)
    XCTAssertEqual(
      LibraryRemoteVerificationService.decide(
        liveAsset: nil, localHashes: [sha], probeHash: nil, format: .ebook),
      .drop)
    XCTAssertEqual(
      LibraryRemoteVerificationService.decide(
        liveAsset: liveAsset(UUID()), localHashes: [], probeHash: nil, format: .ebook),
      .drop)
    XCTAssertEqual(
      LibraryRemoteVerificationService.decide(
        liveAsset: liveAsset(UUID()), localHashes: [sha], probeHash: nil, format: .ebook),
      .keepIfStillValid)
  }
}

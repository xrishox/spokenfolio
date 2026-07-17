import BookJobKit
import Foundation
import LibraryKit
import XCTest

@testable import SpokenFolioApp

@MainActor
final class LibraryProcessModelTests: XCTestCase {
  private func record(m4b: Bool, readAloud: Bool, announces: Bool = false) -> BookCatalogRecord {
    var products: [BookCatalogProduct] = [
      .init(
        kind: .sourceEPUB, path: "/managed/Book/Book.epub", size: 10,
        sha256: String(repeating: "c", count: 64), verifiedAt: Date())
    ]
    if m4b {
      products.append(
        .init(
          kind: .m4b, path: "/managed/Book/Book.m4b", size: 99,
          sha256: String(repeating: "a", count: 64), verifiedAt: Date(),
          narration: .init(
            backendID: "siri", modelID: "siri-private", voiceID: "voice",
            includedSectionIDs: [], bitrateKbps: 256, workers: 2,
            paragraphPauseSeconds: 0.6, chapterPauseSeconds: 1.75,
            announceTitles: announces)))
    }
    if readAloud {
      products.append(
        .init(
          kind: .readAloudEPUB, path: "/managed/Book/Book.readaloud.epub", size: 55,
          sha256: String(repeating: "b", count: 64), verifiedAt: Date()))
    }
    return BookCatalogRecord(
      source: .init(
        format: "epub", importerVersion: 1,
        sha256: String(repeating: "c", count: 64), size: 10),
      metadata: .init(title: "Book", author: "Author"),
      outputDirectory: "/managed/Book", outputBaseName: "Book",
      products: products)
  }

  private func row(
    id: String, record: BookCatalogRecord? = nil,
    remote: LibraryRemoteBookSnapshot? = nil
  ) -> StudioLibraryRow {
    StudioLibraryRow(
      id: id, title: id, author: nil, record: record, remote: remote,
      level: .readable, presence: record == nil ? .storyteller : .local,
      narration: .unknown, stale: false,
      localEPUBReady: record != nil,
      localAudiobookReady: record?.product(.m4b) != nil,
      localReadAloudReady: record?.product(.readAloudEPUB) != nil,
      localReadAloudProductID: nil, ttsProvenance: nil,
      localQualityVerdict: nil, remoteQualityVerdict: nil,
      updatedAt: .distantPast, searchIndex: id)
  }

  private func remoteSnapshot(ebookReady: Bool) -> LibraryRemoteBookSnapshot {
    LibraryRemoteBookSnapshot(
      connectionID: UUID(), remoteBookID: UUID(), title: "Remote",
      assets: ebookReady
        ? [
          .init(
            format: .ebook, assetID: UUID(), filepath: nil, fingerprint: nil,
            fileSize: 1_000, updatedAt: nil, state: .ready, status: nil,
            currentStage: nil, stageProgress: nil, identifiers: [])
        ]
        : [])
  }

  private func makeModel(
    rows: [StudioLibraryRow], intent: LibraryProcessModel.Intent
  ) -> LibraryProcessModel {
    LibraryProcessModel(
      rows: rows, intent: intent, connections: [], preferredConnectionID: nil,
      coordinator: StudioJobCoordinator(),
      processedDirectory: FileManager.default.temporaryDirectory)
  }

  func testProcessIntentDefaultsToFillingLocalGaps() {
    let model = makeModel(
      rows: [row(id: "bare", record: record(m4b: false, readAloud: false))],
      intent: .process)
    XCTAssertTrue(model.createMissingAudiobooks)
    XCTAssertTrue(model.createMissingReadAlouds)
    XCTAssertFalse(model.recreateExistingAudiobooks)
    XCTAssertFalse(model.sendToStoryteller)
    XCTAssertTrue(model.willSynthesize)
  }

  func testSendOnlyIntentEnablesOnlyDelivery() {
    let model = makeModel(
      rows: [row(id: "done", record: record(m4b: true, readAloud: true))],
      intent: .sendOnly)
    XCTAssertFalse(model.createMissingAudiobooks)
    XCTAssertFalse(model.createMissingReadAlouds)
    XCTAssertTrue(model.sendToStoryteller)
    XCTAssertFalse(model.willSynthesize)
  }

  func testReadAloudIntentPresetsRecreateWhenEveryBookHasOne() {
    let model = makeModel(
      rows: [row(id: "done", record: record(m4b: true, readAloud: true))],
      intent: .readAloud)
    XCTAssertTrue(model.recreateExistingReadAlouds)
    XCTAssertFalse(model.createMissingAudiobooks)
    XCTAssertTrue(model.willCreateReadAlouds)
  }

  func testAlignmentAgainstExistingM4BAvoidsSynthesis() {
    // The M4B was made without announcements → RA creation aligns directly.
    let aligns = makeModel(
      rows: [row(id: "aligned", record: record(m4b: true, readAloud: false))],
      intent: .process)
    XCTAssertTrue(aligns.willCreateReadAlouds)
    XCTAssertFalse(aligns.willSynthesize)

    // Announced titles force temporary resynthesis → synthesis needed.
    let resynth = makeModel(
      rows: [
        row(id: "announced", record: record(m4b: true, readAloud: false, announces: true))
      ],
      intent: .process)
    XCTAssertTrue(resynth.willSynthesize)
  }

  func testRemoteOnlyRowsResolveToDownloadOrSkip() {
    let downloadable = row(id: "remote-ready", remote: remoteSnapshot(ebookReady: true))
    let dead = row(id: "remote-dead", remote: remoteSnapshot(ebookReady: false))
    let model = makeModel(rows: [downloadable, dead], intent: .process)

    XCTAssertEqual(model.books.count, 1)
    XCTAssertEqual(model.downloadCount, 1)
    XCTAssertEqual(model.skipped.count, 1)
    XCTAssertEqual(model.skipped.first?.title, "remote-dead")
  }
}

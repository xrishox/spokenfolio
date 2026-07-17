import BookJobKit
import Foundation
import LibraryKit
import XCTest

@testable import SpokenFolioApp

final class LibraryMatchSuggestionTests: XCTestCase {
  private func record(
    title: String, author: String? = nil, identifiers: [String] = []
  ) -> BookCatalogRecord {
    BookCatalogRecord(
      source: .init(
        format: "epub", importerVersion: 1,
        sha256: String(repeating: "c", count: 64), size: 10),
      metadata: .init(
        title: title, author: author,
        identifiers: identifiers.map { .init(kind: "isbn", value: $0) }),
      outputDirectory: "/managed/Book", outputBaseName: "Book",
      products: [])
  }

  private func remote(
    title: String, authors: [String] = [], identifiers: [String] = []
  ) -> LibraryRemoteBookSnapshot {
    LibraryRemoteBookSnapshot(
      connectionID: UUID(), remoteBookID: UUID(), title: title, authors: authors,
      identifiers: identifiers.map {
        .init(id: UUID(), kind: "isbn", name: nil, value: $0)
      })
  }

  func testNormalizedTitleAndAuthorMatchIgnoringPunctuationAndCase() {
    XCTAssertTrue(
      LibraryMatchSuggestion.matches(
        record: record(title: "'Salem's Lot", author: "Stephen King"),
        remote: remote(title: "Salems Lot", authors: ["stephen king"])))
    XCTAssertTrue(
      LibraryMatchSuggestion.matches(
        record: record(title: "Éxile — Part One", author: "A. B."),
        remote: remote(title: "exile part one", authors: ["a b"])))
  }

  func testDifferentAuthorOrTitleDoesNotSuggest() {
    XCTAssertFalse(
      LibraryMatchSuggestion.matches(
        record: record(title: "'Salem's Lot", author: "Stephen King"),
        remote: remote(title: "Salems Lot", authors: ["Somebody Else"])))
    XCTAssertFalse(
      LibraryMatchSuggestion.matches(
        record: record(title: "The Final Empire", author: "Brandon Sanderson"),
        remote: remote(title: "The Well of Ascension", authors: ["Brandon Sanderson"])))
  }

  func testSharedIdentifierOutweighsMetadataDifferences() {
    XCTAssertTrue(
      LibraryMatchSuggestion.matches(
        record: record(title: "Completely Different", author: "X", identifiers: ["9780307474728"]),
        remote: remote(title: "Salems Lot", authors: ["Stephen King"], identifiers: ["9780307474728"])))
  }

  func testMissingAuthorsFallBackToTitleEquality() {
    XCTAssertTrue(
      LibraryMatchSuggestion.matches(
        record: record(title: "'Salem's Lot"),
        remote: remote(title: "Salems Lot", authors: ["Stephen King"])))
    XCTAssertTrue(
      LibraryMatchSuggestion.matches(
        record: record(title: "'Salem's Lot", author: "Stephen King"),
        remote: remote(title: "Salems Lot")))
  }

  func testSuggestionCountsAsNeedsAttentionAndSlotsPend() {
    let row = StudioLibraryRow(
      id: "x", title: "'Salem's Lot", author: "Stephen King",
      record: record(title: "'Salem's Lot", author: "Stephen King"),
      remote: nil, level: .localComplete, presence: .local, narration: .unknown,
      stale: false, localEPUBReady: true, localAudiobookReady: true,
      localReadAloudReady: true, localReadAloudProductID: nil, ttsProvenance: nil,
      localQualityVerdict: nil, remoteQualityVerdict: nil, updatedAt: .distantPast,
      searchIndex: "salems lot",
      suggestedRemote: LibraryRemoteBookSnapshot(
        connectionID: UUID(), remoteBookID: UUID(), title: "Salems Lot",
        assets: [
          .init(
            format: .audiobook, assetID: UUID(), filepath: nil, fingerprint: nil,
            fileSize: 5, updatedAt: nil, state: .ready, status: nil,
            currentStage: nil, stageProgress: nil, identifiers: [])
        ]))

    XCTAssertEqual(
      StudioLibraryQuery(filter: .attention).apply(to: [row]).map(\.id), ["x"])
    // Local package fills the TTS slots; the suggested remote's audiobook with
    // unknown narration renders as a pending human slot.
    XCTAssertEqual(row.slots.ttsAudiobook, .verified)
    XCTAssertEqual(row.slots.humanAudiobook, .pending)
    XCTAssertEqual(row.slots.humanReadAloud, .missing)
  }
}

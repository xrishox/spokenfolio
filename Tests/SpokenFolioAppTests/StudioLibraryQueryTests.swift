import Foundation
import LibraryKit
import XCTest

@testable import SpokenFolioApp

final class StudioLibraryQueryTests: XCTestCase {
  func testSearchIsCaseAndDiacriticInsensitiveAndRequiresEveryTerm() {
    let rows = [
      row(id: "one", title: "Cien años de soledad", author: "Gabriel García Márquez", search: "Cien años de soledad Gabriel García Márquez 9780307474728"),
      row(id: "two", title: "The Final Empire", author: "Brandon Sanderson", search: "The Final Empire Brandon Sanderson 9780765311788"),
    ]

    let result = StudioLibraryQuery(searchText: "garcia 978030", filter: .all).apply(to: rows)

    XCTAssertEqual(result.map(\.id), ["one"])
  }

  func testPresenceFiltersAreExplicit() {
    let rows = [
      row(id: "local", presence: .local),
      row(id: "remote", presence: .storyteller),
      row(id: "linked", presence: .both),
    ]

    XCTAssertEqual(
      StudioLibraryQuery(filter: .local).apply(to: rows).map(\.id), ["local"])
    XCTAssertEqual(
      StudioLibraryQuery(filter: .storyteller).apply(to: rows).map(\.id), ["remote"])
    XCTAssertEqual(
      StudioLibraryQuery(filter: .linked).apply(to: rows).map(\.id), ["linked"])
  }

  func testNeedsAttentionIncludesIncompleteStaleAndProblemQualityRows() {
    let rows = [
      row(id: "complete", level: .fullyResilient),
      row(id: "incomplete", level: .readable),
      row(id: "stale", level: .fullyResilient, stale: true),
      row(id: "broken", level: .fullyResilient, localQuality: "likelyBroken"),
    ]

    XCTAssertEqual(
      Set(StudioLibraryQuery(filter: .attention).apply(to: rows).map(\.id)),
      Set(["incomplete", "stale", "broken"]))
  }

  private func row(
    id: String, title: String = "Book", author: String? = nil,
    presence: StudioLibraryRow.Presence = .both,
    level: LibraryLevel = .fullyResilient, stale: Bool = false,
    localQuality: String? = nil, remoteQuality: String? = nil,
    search: String? = nil
  ) -> StudioLibraryRow {
    StudioLibraryRow(
      id: id, title: title, author: author, record: nil, remote: nil,
      level: level, presence: presence, narration: .unknown, stale: stale,
      localEPUBReady: false, localAudiobookReady: false, localReadAloudReady: false,
      localReadAloudProductID: nil, ttsProvenance: nil,
      localQualityVerdict: localQuality, remoteQualityVerdict: remoteQuality,
      updatedAt: .distantPast, searchIndex: search ?? [title, author].compactMap { $0 }.joined(separator: " "))
  }
}

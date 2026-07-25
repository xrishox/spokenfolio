import BookJobKit
import StorytellerKit
import XCTest

@testable import SpokenFolioApp

/// The whole-book replacement safety core: the delete may only happen when
/// the live remote book still matches the snapshot the user confirmed.
final class StorytellerReplaceTests: XCTestCase {
  private func book(
    ebook: StorytellerAsset? = nil, audiobook: StorytellerAsset? = nil,
    readaloud: StorytellerAsset? = nil
  ) -> StorytellerBook {
    StorytellerBook(
      uuid: UUID(), title: "Fixture", ebook: ebook, audiobook: audiobook,
      readaloud: readaloud)
  }

  private func asset(_ id: UUID, size: UInt64? = 100) -> StorytellerAsset {
    StorytellerAsset(uuid: id, filepath: "/assets/\(id).bin", fileSize: size)
  }

  private func expected(
    _ format: StorytellerFormat, _ id: UUID, size: UInt64? = 100, sha256: String? = nil
  ) -> BookJobRequest.StorytellerDelivery.ExpectedRemoteAsset {
    .init(format: format.rawValue, assetID: id, size: size, sha256: sha256)
  }

  func testMatchingSnapshotPasses() async throws {
    let ebookID = UUID()
    let target = book(ebook: asset(ebookID))
    try await BookJobExecutor.verifyReplacementSnapshot(
      target: target, expected: [expected(.ebook, ebookID)]
    ) { _, _ in XCTFail("no hash probe needed without sha256"); return nil }
  }

  func testUnexpectedNewAssetAborts() async throws {
    let ebookID = UUID()
    let target = book(ebook: asset(ebookID), readaloud: asset(UUID()))
    do {
      try await BookJobExecutor.verifyReplacementSnapshot(
        target: target, expected: [expected(.ebook, ebookID)]
      ) { _, _ in nil }
      XCTFail("expected a conflict for the surprise readaloud")
    } catch let error as StorytellerAPIError {
      XCTAssertTrue("\(error)".contains("appeared after"), "\(error)")
    }
  }

  func testVanishedConfirmedAssetIsTolerated() async throws {
    // The confirmation is a ceiling on destruction: an asset the user
    // approved destroying that has since vanished (or is a broken
    // server-side ReadAloud with no available file) destroys nothing extra,
    // so the replacement proceeds.
    let ebookID = UUID()
    let target = book(ebook: asset(ebookID))
    try await BookJobExecutor.verifyReplacementSnapshot(
      target: target,
      expected: [expected(.ebook, ebookID), expected(.readaloud, UUID())]
    ) { _, _ in nil }
  }

  func testChangedAssetIdentityAborts() async throws {
    let target = book(ebook: asset(UUID()))
    do {
      try await BookJobExecutor.verifyReplacementSnapshot(
        target: target, expected: [expected(.ebook, UUID())]
      ) { _, _ in nil }
      XCTFail("expected a conflict for the changed asset id")
    } catch let error as StorytellerAPIError {
      XCTAssertTrue("\(error)".contains("changed"), "\(error)")
    }
  }

  func testContentDriftAbortsViaHashProbe() async throws {
    let ebookID = UUID()
    let target = book(ebook: asset(ebookID))
    do {
      try await BookJobExecutor.verifyReplacementSnapshot(
        target: target, expected: [expected(.ebook, ebookID, sha256: "aa")]
      ) { _, _ in "bb" }
      XCTFail("expected a content conflict")
    } catch let error as StorytellerAPIError {
      XCTAssertTrue("\(error)".contains("content"), "\(error)")
    }
    // An unverifiable hash (nil) must also abort rather than proceed.
    do {
      try await BookJobExecutor.verifyReplacementSnapshot(
        target: target, expected: [expected(.ebook, ebookID, sha256: "aa")]
      ) { _, _ in nil }
      XCTFail("expected a conflict for the unverifiable content")
    } catch is StorytellerAPIError {}
  }

  func testDeliveryValidationRequiresSnapshotForReplace() throws {
    var request = BookJobRequest(
      catalogID: UUID(),
      title: "Fixture", author: nil,
      source: .init(
        path: "/tmp/x.epub", sha256: String(repeating: "a", count: 64),
        format: "epub", importerVersion: 1),
      narration: .init(
        backendID: "siri", modelID: "siri-private", voiceID: "voice",
        includedSectionIDs: [], bitrateKbps: 256, workers: 4,
        paragraphPauseSeconds: 0.6, chapterPauseSeconds: 1.75, announceTitles: false),
      m4bOutputPath: "/tmp/x.m4b",
      storyteller: .init(
        connectionID: UUID(), remoteBookID: UUID(), products: [.sourceEPUB],
        replaceRemoteBook: true),
      operation: .storytellerDelivery)
    XCTAssertThrowsError(try request.validate()) { error in
      XCTAssertTrue("\(error)".contains("snapshot"), "\(error)")
    }
    request.storyteller?.expectedRemoteAssets = [
      .init(format: "ebook", assetID: UUID(), size: 10, sha256: nil)
    ]
    XCTAssertNoThrow(try request.validate())
    request.storyteller?.assertNarration = "alien"
    XCTAssertThrowsError(try request.validate())
    request.storyteller?.assertNarration = "human"
    XCTAssertNoThrow(try request.validate())
  }
}

import BookJobKit
import StorytellerKit
import XCTest

@testable import SpokenFolioApp

/// The per-asset replacement safety core: an acknowledged asset is replaced
/// only while it still matches the snapshot the user confirmed (ceiling
/// semantics — drift that could destroy more aborts).
final class StorytellerReplaceTests: XCTestCase {
  private func asset(_ id: UUID, size: UInt64? = 100) -> StorytellerAsset {
    StorytellerAsset(uuid: id, filepath: "/assets/\(id).bin", fileSize: size)
  }

  private func expected(
    _ format: StorytellerFormat, _ id: UUID, size: UInt64? = 100, sha256: String? = nil
  ) -> BookJobRequest.StorytellerDelivery.ExpectedRemoteAsset {
    .init(format: format.rawValue, assetID: id, size: size, sha256: sha256)
  }

  func testMatchingSnapshotPasses() throws {
    let id = UUID()
    try BookJobExecutor.verifyAcknowledgedAsset(
      format: .readaloud, asset: asset(id), hash: nil,
      expected: [expected(.readaloud, id)])
  }

  func testUnconfirmedAssetAborts() throws {
    // The live slot holds an asset the user never saw in the manifest.
    XCTAssertThrowsError(
      try BookJobExecutor.verifyAcknowledgedAsset(
        format: .readaloud, asset: asset(UUID()), hash: nil,
        expected: [expected(.ebook, UUID())])
    ) { error in
      XCTAssertTrue("\(error)".contains("appeared after"), "\(error)")
    }
  }

  func testChangedAssetIdentityAborts() throws {
    XCTAssertThrowsError(
      try BookJobExecutor.verifyAcknowledgedAsset(
        format: .audiobook, asset: asset(UUID()), hash: nil,
        expected: [expected(.audiobook, UUID())])
    ) { error in
      XCTAssertTrue("\(error)".contains("changed"), "\(error)")
    }
  }

  func testChangedSizeAborts() throws {
    let id = UUID()
    XCTAssertThrowsError(
      try BookJobExecutor.verifyAcknowledgedAsset(
        format: .ebook, asset: asset(id, size: 999), hash: nil,
        expected: [expected(.ebook, id, size: 100)])
    ) { error in
      XCTAssertTrue("\(error)".contains("size"), "\(error)")
    }
  }

  func testChangedContentAborts() throws {
    let id = UUID()
    XCTAssertThrowsError(
      try BookJobExecutor.verifyAcknowledgedAsset(
        format: .ebook, asset: asset(id), hash: "bb",
        expected: [expected(.ebook, id, sha256: "aa")])
    ) { error in
      XCTAssertTrue("\(error)".contains("content"), "\(error)")
    }
    // An unavailable live hash cannot prove drift; identity+size carried the
    // confirmation, so the replacement proceeds.
    try BookJobExecutor.verifyAcknowledgedAsset(
      format: .ebook, asset: asset(id), hash: nil,
      expected: [expected(.ebook, id, sha256: "aa")])
  }

  func testDeliveryValidationRequiresSnapshotsForReplaceFormats() throws {
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
        replaceFormats: ["ebook"]),
      operation: .storytellerDelivery)
    XCTAssertThrowsError(try request.validate()) { error in
      XCTAssertTrue("\(error)".contains("snapshot"), "\(error)")
    }
    request.storyteller?.expectedRemoteAssets = [
      .init(format: "ebook", assetID: UUID(), size: 10, sha256: nil)
    ]
    XCTAssertNoThrow(try request.validate())
    request.storyteller?.replaceFormats = ["alien"]
    XCTAssertThrowsError(try request.validate())
    request.storyteller?.replaceFormats = ["ebook"]
    request.storyteller?.assertNarration = "alien"
    XCTAssertThrowsError(try request.validate())
    request.storyteller?.assertNarration = "human"
    XCTAssertNoThrow(try request.validate())
  }
}

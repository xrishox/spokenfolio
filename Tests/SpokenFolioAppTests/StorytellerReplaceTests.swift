import BookJobKit
import StorytellerKit
import XCTest

@testable import SpokenFolioApp

/// The per-asset replacement safety core: an acknowledged asset is replaced
/// only while it still matches the snapshot the user confirmed (ceiling
/// semantics — drift that could destroy more aborts).
final class StorytellerReplaceTests: XCTestCase {
  private func asset(
    _ id: UUID, size: UInt64? = 100, fingerprint: String? = nil
  ) -> StorytellerAsset {
    StorytellerAsset(
      uuid: id, filepath: "/assets/\(id).bin", fingerprint: fingerprint, fileSize: size)
  }

  private func expected(
    _ format: StorytellerFormat, _ id: UUID, size: UInt64? = 100, sha256: String? = nil,
    fingerprint: String? = nil
  ) -> BookJobRequest.StorytellerDelivery.ExpectedRemoteAsset {
    .init(
      format: format.rawValue, assetID: id, size: size, sha256: sha256,
      fingerprint: fingerprint)
  }

  private func verify(
    _ format: StorytellerFormat, asset: StorytellerAsset,
    liveHash: StorytellerMutationVerifier.LiveHash = .unavailable,
    expected: [BookJobRequest.StorytellerDelivery.ExpectedRemoteAsset],
    action: StorytellerMutationVerifier.Action = .replacement
  ) throws {
    try StorytellerMutationVerifier.verify(
      format: format, asset: asset, liveHash: liveHash, expected: expected, action: action)
  }

  func testMatchingSnapshotPasses() throws {
    let id = UUID()
    try verify(.readaloud, asset: asset(id), expected: [expected(.readaloud, id)])
  }

  func testUnconfirmedAssetAborts() throws {
    // The live slot holds an asset the user never saw in the manifest.
    XCTAssertThrowsError(
      try verify(.readaloud, asset: asset(UUID()), expected: [expected(.ebook, UUID())])
    ) { error in
      XCTAssertTrue("\(error)".contains("appeared after"), "\(error)")
    }
  }

  func testChangedAssetIdentityAborts() throws {
    XCTAssertThrowsError(
      try verify(.audiobook, asset: asset(UUID()), expected: [expected(.audiobook, UUID())])
    ) { error in
      XCTAssertTrue("\(error)".contains("changed"), "\(error)")
    }
  }

  func testChangedSizeAborts() throws {
    let id = UUID()
    XCTAssertThrowsError(
      try verify(.ebook, asset: asset(id, size: 999), expected: [expected(.ebook, id, size: 100)])
    ) { error in
      XCTAssertTrue("\(error)".contains("size"), "\(error)")
    }
  }

  func testChangedContentAborts() throws {
    let id = UUID()
    XCTAssertThrowsError(
      try verify(
        .ebook, asset: asset(id), liveHash: .value("bb"),
        expected: [expected(.ebook, id, sha256: "aa")])
    ) { error in
      XCTAssertTrue("\(error)".contains("content"), "\(error)")
    }
    try verify(
      .ebook, asset: asset(id), liveHash: .value("aa"),
      expected: [expected(.ebook, id, sha256: "aa")])
  }

  /// A confirmed hash that cannot be re-proved fails the mutation closed.
  /// Storyteller offers no precondition, so an unverifiable hash is the only
  /// signal left that the acknowledged content is still the content there;
  /// treating "no answer" as "unchanged" would destroy on a guess.
  func testUnprovableConfirmedHashFailsClosed() throws {
    let id = UUID()
    for hash: StorytellerMutationVerifier.LiveHash in [.unavailable, .failed("network down")] {
      XCTAssertThrowsError(
        try verify(
          .ebook, asset: asset(id), liveHash: hash,
          expected: [expected(.ebook, id, sha256: "aa")], action: .deletion)
      ) { error in
        XCTAssertTrue("\(error)".contains("could not be re-verified"), "\(error)")
        XCTAssertTrue("\(error)".contains("deletion aborted"), "\(error)")
      }
    }
    // Without a confirmed hash there is nothing to re-prove: identity, size,
    // and fingerprint carried the confirmation.
    try verify(.ebook, asset: asset(id), liveHash: .unavailable, expected: [expected(.ebook, id)])
  }

  /// Storyteller preserves the format-row UUID across a replacement, so a
  /// changed fingerprint is the signal that content was swapped underneath
  /// an otherwise identical-looking asset.
  func testChangedFingerprintAborts() throws {
    let id = UUID()
    XCTAssertThrowsError(
      try verify(
        .audiobook, asset: asset(id, fingerprint: "live"),
        expected: [expected(.audiobook, id, fingerprint: "confirmed")])
    ) { error in
      XCTAssertTrue("\(error)".contains("fingerprint"), "\(error)")
    }
    try verify(
      .audiobook, asset: asset(id, fingerprint: "same"),
      expected: [expected(.audiobook, id, fingerprint: "same")])
    // A request written before fingerprints were recorded still verifies on
    // identity and size.
    try verify(
      .audiobook, asset: asset(id, fingerprint: "live"),
      expected: [expected(.audiobook, id, fingerprint: nil)])
  }

  /// Stock Storyteller files the first uploaded file by its own type, so a
  /// new book seeded with a ReadAloud EPUB would record the narrated EPUB as
  /// the book's source EPUB. Refuse instead.
  func testNewBookCannotBeSeededByAReadAloudAlone() throws {
    XCTAssertThrowsError(try BookJobExecutor.validateNewBookSeed([.readaloud])) { error in
      XCTAssertTrue("\(error)".contains("ReadAloud alone"), "\(error)")
    }
    // The EPUB or the audiobook seeds the book, and the ReadAloud then goes
    // to the per-asset endpoint that does honor a format.
    try BookJobExecutor.validateNewBookSeed([.ebook, .readaloud])
    try BookJobExecutor.validateNewBookSeed([.audiobook, .readaloud])
    try BookJobExecutor.validateNewBookSeed([.ebook])
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

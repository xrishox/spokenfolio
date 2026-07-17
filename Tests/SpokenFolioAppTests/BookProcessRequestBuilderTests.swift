import BookJobKit
import Foundation
import XCTest

@testable import SpokenFolioApp

final class BookProcessRequestBuilderTests: XCTestCase {
  private let m4bHash = String(repeating: "a", count: 64)
  private let readAloudHash = String(repeating: "b", count: 64)
  private let sourceHash = String(repeating: "c", count: 64)

  private func catalog(
    m4b: Bool = false, m4bAnnouncesTitles: Bool = false, readAloud: Bool = false
  ) -> BookCatalogRecord {
    var products: [BookCatalogProduct] = [
      .init(
        kind: .sourceEPUB, path: "/managed/Book/Book.epub", size: 10,
        sha256: sourceHash, verifiedAt: Date())
    ]
    if m4b {
      var narration = BookJobRequest.Narration(
        backendID: "siri", modelID: "siri-private", voiceID: "voice",
        includedSectionIDs: [], bitrateKbps: 256, workers: 2,
        paragraphPauseSeconds: 0.6, chapterPauseSeconds: 1.75,
        announceTitles: m4bAnnouncesTitles)
      narration.announceTitles = m4bAnnouncesTitles
      products.append(
        .init(
          kind: .m4b, path: "/managed/Book/Book.m4b", size: 99,
          sha256: m4bHash, verifiedAt: Date(), narration: narration))
    }
    if readAloud {
      products.append(
        .init(
          kind: .readAloudEPUB, path: "/managed/Book/Book.readaloud.epub", size: 55,
          sha256: readAloudHash, verifiedAt: Date(),
          readAloud: .init(outputPath: "/managed/Book/Book.readaloud.epub", opusBitrateKbps: 64)))
    }
    return BookCatalogRecord(
      source: .init(format: "epub", importerVersion: 1, sha256: sourceHash, size: 10),
      metadata: .init(title: "Book", author: "Author"),
      outputDirectory: "/managed/Book", outputBaseName: "Book",
      products: products)
  }

  private func settings(
    createReadAloud: Bool = false, recreateReadAloud: Bool = false,
    reprocess: Bool = false, announceTitles: Bool = true,
    asrEngine: String = "apple", asrModel: String = "large-v3-turbo"
  ) -> BookProcessSettings {
    BookProcessSettings(
      voiceID: "voice", voiceModelRevision: nil, voiceRevision: nil,
      bitrateKbps: 256, workers: 2, announceTitles: announceTitles,
      paragraphPauseSeconds: 0.6, chapterPauseSeconds: 1.75,
      createReadAloud: createReadAloud, recreateReadAloud: recreateReadAloud,
      reprocessAudiobook: reprocess,
      readAloudBitrateKbps: 32, readAloudASREngineID: asrEngine,
      readAloudASRModelID: asrModel, language: "en", workDirectory: nil)
  }

  private var delivery: BookProcessSettings.Delivery {
    .init(connectionID: UUID(), remoteBookID: UUID(), products: [.sourceEPUB, .m4b])
  }

  func testFreshBookProducesProductionJobAndForcesAnnouncementsOffForReadAloud() throws {
    let request = try BookProcessRequestBuilder.request(
      catalog: catalog(), settings: settings(createReadAloud: true), delivery: nil)
    XCTAssertEqual(request.resolvedOperation, .production)
    XCTAssertFalse(request.allowOverwrite)
    XCTAssertTrue(request.resolvedProductReplacements.isEmpty)
    XCTAssertFalse(request.narration.announceTitles)
    XCTAssertEqual(request.readAloud?.resolvedASREngineID, "apple")
    XCTAssertNoThrow(try request.validate())
  }

  func testReprocessReplacesM4BAndSuppressesCatalogReadAloudDescriptor() throws {
    let request = try BookProcessRequestBuilder.request(
      catalog: catalog(m4b: true, readAloud: true),
      settings: settings(reprocess: true), delivery: nil)
    XCTAssertEqual(request.resolvedOperation, .production)
    XCTAssertTrue(request.allowOverwrite)
    XCTAssertEqual(request.resolvedProductReplacements.map(\.kind), [.m4b])
    XCTAssertEqual(request.resolvedProductReplacements.first?.expectedSHA256, m4bHash)
    XCTAssertNil(request.readAloud, "a reprocess must not inherit the stale ReadAloud descriptor")
    XCTAssertNoThrow(try request.validate())
  }

  func testReprocessWithReadAloudReplacesBothProducts() throws {
    let request = try BookProcessRequestBuilder.request(
      catalog: catalog(m4b: true, readAloud: true),
      settings: settings(createReadAloud: true, reprocess: true), delivery: nil)
    XCTAssertEqual(request.resolvedOperation, .production)
    XCTAssertEqual(
      Set(request.resolvedProductReplacements.map(\.kind)), [.m4b, .readAloudEPUB])
    XCTAssertNoThrow(try request.validate())
  }

  func testReadAloudOnlyAlignsWithExistingM4BWhenAnnouncementsWereOff() throws {
    let request = try BookProcessRequestBuilder.request(
      catalog: catalog(m4b: true, m4bAnnouncesTitles: false),
      settings: settings(createReadAloud: true, asrEngine: "whisper"), delivery: nil)
    XCTAssertEqual(request.resolvedOperation, .readAloud)
    XCTAssertEqual(request.alignmentAudio?.mode, .existingM4B)
    XCTAssertEqual(request.alignmentAudio?.sha256, m4bHash)
    XCTAssertEqual(request.readAloud?.resolvedASREngineID, "whisper")
    XCTAssertEqual(request.readAloud?.resolvedASRModelID, "large-v3-turbo")
    XCTAssertNoThrow(try request.validate())
  }

  func testReadAloudOnlyResynthesizesWhenM4BAnnouncedTitles() throws {
    let request = try BookProcessRequestBuilder.request(
      catalog: catalog(m4b: true, m4bAnnouncesTitles: true),
      settings: settings(createReadAloud: true), delivery: nil)
    XCTAssertEqual(request.resolvedOperation, .readAloud)
    XCTAssertEqual(request.alignmentAudio?.mode, .temporaryResynthesis)
    XCTAssertNoThrow(try request.validate())
  }

  func testRecreateReadAloudReplacesItInPlaceDigestGuarded() throws {
    let request = try BookProcessRequestBuilder.request(
      catalog: catalog(m4b: true, readAloud: true),
      settings: settings(createReadAloud: true, recreateReadAloud: true, asrEngine: "whisper"),
      delivery: nil)
    XCTAssertEqual(request.resolvedOperation, .readAloud)
    XCTAssertTrue(request.allowOverwrite)
    XCTAssertEqual(request.resolvedProductReplacements.map(\.kind), [.readAloudEPUB])
    XCTAssertEqual(request.resolvedProductReplacements.first?.expectedSHA256, readAloudHash)
    XCTAssertEqual(request.readAloud?.resolvedASREngineID, "whisper")
    XCTAssertNoThrow(try request.validate())
  }

  func testDeliveryOnlyDescribesExistingReadAloudForUpload() throws {
    var sendAll = delivery
    sendAll.products = [.sourceEPUB, .m4b, .readAloudEPUB]
    let request = try BookProcessRequestBuilder.request(
      catalog: catalog(m4b: true, readAloud: true),
      settings: settings(), delivery: sendAll)
    XCTAssertEqual(request.resolvedOperation, .storytellerDelivery)
    XCTAssertEqual(request.readAloud?.outputPath, "/managed/Book/Book.readaloud.epub")
    XCTAssertEqual(request.readAloud?.opusBitrateKbps, 64)
    XCTAssertFalse(
      request.narration.announceTitles,
      "carrying a ReadAloud descriptor requires announcements off, even for delivery-only")
    XCTAssertNoThrow(try request.validate())
  }

  func testNothingToDoAndMissingTargetsThrow() {
    XCTAssertThrowsError(
      try BookProcessRequestBuilder.request(
        catalog: catalog(m4b: true), settings: settings(), delivery: nil)
    ) { error in
      XCTAssertEqual(error as? BookProcessRequestBuilder.PlanError, .nothingToDo)
    }
    XCTAssertThrowsError(
      try BookProcessRequestBuilder.request(
        catalog: catalog(), settings: settings(reprocess: true), delivery: nil)
    ) { error in
      XCTAssertEqual(error as? BookProcessRequestBuilder.PlanError, .reprocessTargetMissing)
    }
    XCTAssertThrowsError(
      try BookProcessRequestBuilder.request(
        catalog: catalog(m4b: true),
        settings: settings(createReadAloud: true, recreateReadAloud: true), delivery: nil)
    ) { error in
      XCTAssertEqual(error as? BookProcessRequestBuilder.PlanError, .recreateTargetMissing)
    }
  }
}

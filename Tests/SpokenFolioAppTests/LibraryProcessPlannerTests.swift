import BookJobKit
import Foundation
import LibraryKit
import XCTest

@testable import SpokenFolioApp

final class LibraryProcessPlannerTests: XCTestCase {
  private func book() -> LibraryProcessPlanner.Book {
    let record = BookCatalogRecord(
      source: .init(
        format: "epub", importerVersion: 1,
        sha256: String(repeating: "a", count: 64), size: 12),
      metadata: .init(title: "Fixture", author: "Author"),
      outputDirectory: "/tmp/Fixture", outputBaseName: "Fixture",
      products: [])
    return LibraryProcessPlanner.Book(
      id: "row", title: "Fixture", author: "Author", source: .cataloged(record),
      hasAudiobook: false, hasReadAloud: false, audiobookNarration: nil,
      audiobookAlignsDirectly: false, remote: nil, remoteNarration: .unknown)
  }

  private var toggles: LibraryProcessPlanner.Toggles {
    .init(
      createMissingAudiobooks: true, recreateExistingAudiobooks: false,
      createMissingReadAlouds: false, recreateExistingReadAlouds: false,
      sendToStoryteller: false, deliveryConnectionID: nil, sendEPUB: false,
      sendM4B: false, sendReadAloud: false, confirmedRemoteBookID: nil)
  }

  private var settings: LibraryProcessPlanner.SharedSettings {
    .init(
      backendID: "siri-fm", modelID: "siri-expressive", voiceID: "voice",
      pacePreset: 3, expressivityPreset: 3, bitrateKbps: 256, workers: 1,
      announceTitles: true, paragraphPause: 0.6, chapterPause: 1.75,
      readAloudBitrateKbps: 32, readAloudASREngineID: "synthesis",
      readAloudASRModelID: "large-v3-turbo")
  }

  func testSynthesisRejectsMissingOrMismatchedQualifiedVoice() {
    let wrongBackend = LibraryProcessPlanner.VoiceDescriptorLite(
      backendID: "siri", modelID: "siri-private", voiceID: "voice",
      modelRevision: nil, voiceRevision: nil)
    XCTAssertThrowsError(
      try LibraryProcessPlanner.makeSettings(
        for: book(), toggles: toggles, shared: settings, voices: [wrongBackend],
        configuredWorkDirectory: nil, requiresSelectedVoice: true))
  }

  func testDeliveryOnlySettingsDoNotRequireUnusedSharedVoice() throws {
    XCTAssertNoThrow(
      try LibraryProcessPlanner.makeSettings(
        for: book(), toggles: toggles, shared: settings, voices: [],
        configuredWorkDirectory: nil, requiresSelectedVoice: false))
  }
}

import AudiobookKit
import XCTest

@testable import SpokenFolioApp

final class ServerConfigTests: XCTestCase {
  func testConfigDefaultsAndEnvironmentOverrides() throws {
    let missing = "/tmp/nonexistent-siri-config-\(UUID().uuidString).json"
    let config = try ServerConfig.load(environment: [
      "SPOKENFOLIO_CONFIG": missing,
      "HTTP_HOST": "127.0.0.1",
      "HTTP_PORT": "18790",
    ])
    XCTAssertEqual(config.host, "127.0.0.1")
    XCTAssertEqual(config.port, 18_790)
    XCTAssertEqual(config.maxWorkers, 4)
    XCTAssertEqual(config.maxQueuedRequests, 20)
  }

  func testConfigValidationRejectsUnsafeLimits() {
    var config = ServerConfig()
    config.maxWorkers = 5
    XCTAssertThrowsError(try config.validate())
    config.maxWorkers = 4
    config.maxQueuedRequests = 21
    XCTAssertThrowsError(try config.validate())
  }

  func testPartialConfigUsesSafeDefaults() throws {
    let config = try JSONDecoder().decode(
      ServerConfig.self, from: Data(#"{"port":9000}"#.utf8))
    XCTAssertEqual(config.host, "0.0.0.0")
    XCTAssertEqual(config.port, 9000)
    XCTAssertNil(config.defaultTTS)
    XCTAssertEqual(config.maxWorkers, 4)
    XCTAssertEqual(config.maxQueuedRequests, 20)
    XCTAssertEqual(config.requestDeadlineSeconds, 25)
  }

  func testDefaultTTSConfigDecodesAndValidatesPresetBounds() throws {
    let config = try JSONDecoder().decode(
      ServerConfig.self,
      from: Data(
        #"{"defaultVoice":"legacy","defaultTTS":{"backendID":"siri-fm","modelID":"siri-expressive","voiceID":"en-US-F","pacePreset":2,"expressivityPreset":5}}"#.utf8))
    XCTAssertEqual(config.defaultVoice, "legacy")
    XCTAssertEqual(config.defaultTTS?.backendID, "siri-fm")
    XCTAssertEqual(config.defaultTTS?.modelID, "siri-expressive")
    XCTAssertEqual(config.defaultTTS?.voiceID, "en-US-F")
    XCTAssertEqual(config.defaultTTS?.pacePreset, 2)
    XCTAssertEqual(config.defaultTTS?.expressivityPreset, 5)
    XCTAssertNoThrow(try config.validate())

    var invalid = config
    invalid.defaultTTS?.pacePreset = 6
    XCTAssertThrowsError(try invalid.validate())
  }

  func testInvalidHTTPPortOverrideIsRejected() {
    XCTAssertThrowsError(
      try ServerConfig.load(environment: [
        "SPOKENFOLIO_CONFIG": "/tmp/nonexistent-siri-config-\(UUID().uuidString).json",
        "HTTP_PORT": "not-a-number",
      ]))
  }

  func testAppConfigLoadsBothSectionsOnceAndRejectsInvalidAudiobookValues() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("app-config-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    try Data(
      #"{"port":9001,"audiobook":{"defaultBitrateKbps":64,"maxWorkers":3}}"#.utf8
    ).write(to: url)
    let loaded = try AppConfig.load(environment: ["SPOKENFOLIO_CONFIG": url.path])
    XCTAssertEqual(loaded.server.port, 9_001)
    XCTAssertEqual(loaded.audiobook.defaultBitrateKbps, 64)
    XCTAssertEqual(loaded.audiobook.maxWorkers, 3)

    // The ceiling is the measured plateau: eight is accepted, nine is not,
    // because every measured point above eight was slower.
    try Data(#"{"audiobook":{"maxWorkers":8}}"#.utf8).write(to: url)
    XCTAssertEqual(
      try AppConfig.load(environment: ["SPOKENFOLIO_CONFIG": url.path]).audiobook.maxWorkers,
      AudiobookConfig.maximumWorkers)

    try Data(#"{"audiobook":{"maxWorkers":9}}"#.utf8).write(to: url)
    XCTAssertThrowsError(try AppConfig.load(environment: ["SPOKENFOLIO_CONFIG": url.path]))
  }
}

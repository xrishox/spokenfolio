import XCTest

@testable import SiriTTSServer

final class ServerConfigTests: XCTestCase {
  func testConfigDefaultsAndEnvironmentOverrides() throws {
    let missing = "/tmp/nonexistent-siri-config-\(UUID().uuidString).json"
    let config = try ServerConfig.load(environment: [
      "SIRI_TTS_CONFIG": missing,
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
    XCTAssertEqual(config.maxWorkers, 4)
    XCTAssertEqual(config.maxQueuedRequests, 20)
    XCTAssertEqual(config.requestDeadlineSeconds, 25)
  }

  func testInvalidHTTPPortOverrideIsRejected() {
    XCTAssertThrowsError(
      try ServerConfig.load(environment: [
        "SIRI_TTS_CONFIG": "/tmp/nonexistent-siri-config-\(UUID().uuidString).json",
        "HTTP_PORT": "not-a-number",
      ]))
  }
}

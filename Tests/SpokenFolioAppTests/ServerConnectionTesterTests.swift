import XCTest

@testable import SpokenFolioApp

final class ServerConnectionTesterTests: XCTestCase {
  func testHTTPFailureNamesCodecAndStatus() {
    let error = ServerConnectionTester.Failure.http(format: "opus", statusCode: 503)

    XCTAssertEqual(
      error.localizedDescription,
      "The Opus test returned HTTP 503. Check the server status and try again.")
  }

  func testNonHTTPFailureExplainsMissingResponse() {
    let error = ServerConnectionTester.Failure.http(format: "aac", statusCode: nil)

    XCTAssertEqual(
      error.localizedDescription,
      "The AAC test did not receive an HTTP response. Check the server status and try again.")
  }

  func testTransportFailureNamesCodec() {
    let error = ServerConnectionTester.Failure.transport(format: "aac")

    XCTAssertEqual(
      error.localizedDescription,
      "The AAC test could not reach the local TTS server. Check the server status and try again.")
  }

  func testRequestBodyCarriesExpressiveModelVoiceAndControls() throws {
    let data = try ServerConnectionTester.requestBody(
      selection: .init(
        publicModelID: "siri-expressive", voiceID: "en-US-F",
        pacePreset: 2, expressivityPreset: 5),
      text: "Testing expression.", format: "aac")
    let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

    XCTAssertEqual(body["model"] as? String, "siri-expressive")
    XCTAssertEqual(body["voice"] as? String, "en-US-F")
    XCTAssertEqual(body["pace"] as? Int, 2)
    XCTAssertEqual(body["expressivity"] as? Int, 5)
    XCTAssertEqual(body["response_format"] as? String, "aac")
  }

  func testInvalidInputStatesPublicLimit() {
    XCTAssertEqual(
      ServerConnectionTester.Failure.invalidInput.localizedDescription,
      "Enter between 1 and 4,096 characters to test.")
  }

  func testWrongMIMEOrEmptyResponseNamesCodec() {
    XCTAssertEqual(
      ServerConnectionTester.Failure.response(format: "aac").localizedDescription,
      "The AAC test returned an empty or incorrectly typed audio response.")
  }

  func testDecodeFailureStatesExpectedAudioContract() {
    let error = ServerConnectionTester.Failure.decode(format: "opus")

    XCTAssertEqual(
      error.localizedDescription,
      "The Opus response was not valid mono 48 kHz audio. Open Console for details.")
  }
}

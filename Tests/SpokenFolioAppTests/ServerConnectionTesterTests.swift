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

  func testDecodeFailureStatesExpectedAudioContract() {
    let error = ServerConnectionTester.Failure.decode(format: "opus")

    XCTAssertEqual(
      error.localizedDescription,
      "The Opus response was not valid mono 48 kHz audio. Open Console for details.")
  }
}

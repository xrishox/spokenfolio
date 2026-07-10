import Vapor
import XCTVapor
import XCTest

@testable import SiriTTSServer

final class HTTPContractTests: XCTestCase {
  func testSpeechReturnsOpenAIShapedValidationError() async throws {
    try await withTestApplication { app in
      try await app.test(
        .POST,
        "/v1/audio/speech",
        beforeRequest: { request in
          try request.content.encode([
            "model": "missing-model",
            "input": "Hello.",
            "voice": "test-voice",
          ])
        },
        afterResponse: { response in
          await Task.yield()
          XCTAssertEqual(response.status, .badRequest)
          XCTAssertEqual(response.headers.contentType, .json)
          let error = try response.content.decode(OpenAIErrorResponse.self)
          XCTAssertEqual(error.error.code, "model_not_found")
        })
    }
  }

  func testRateLimitErrorsPassThroughOpenAIErrorMiddleware() async throws {
    try await withTestApplication { app in
      for requestNumber in 1...21 {
        try await app.test(
          .POST,
          "/v1/audio/speech",
          beforeRequest: { request in
            try request.content.encode([
              "model": "missing-model",
              "input": "Hello.",
              "voice": "test-voice",
            ])
          },
          afterResponse: { response in
            await Task.yield()
            if requestNumber <= 20 {
              XCTAssertEqual(response.status, .badRequest)
            } else {
              XCTAssertEqual(response.status, .tooManyRequests)
              let error = try response.content.decode(OpenAIErrorResponse.self)
              XCTAssertEqual(error.error.code, "rate_limited")
            }
          })
      }
    }
  }

  func testOpusResponseHasExactAdvertisedContainer() async throws {
    try await withTestApplication { app in
      try await app.test(
        .POST,
        "/v1/audio/speech",
        beforeRequest: { request in
          try request.content.encode([
            "model": "tts-1",
            "input": "Hello from the HTTP contract test.",
            "voice": "test-voice",
            "response_format": "opus",
          ])
        },
        afterResponse: { response in
          await Task.yield()
          XCTAssertEqual(response.status, .ok)
          XCTAssertEqual(response.headers.first(name: .contentType), "audio/ogg; codecs=opus")
          XCTAssertEqual(
            response.headers.first(name: .contentLength), String(response.body.readableBytes))
          XCTAssertTrue(
            response.body.getData(at: 0, length: 4)?.starts(with: Data("OggS".utf8)) == true)
        })
    }
  }

  private func withTestApplication(
    _ body: (Application) async throws -> Void
  ) async throws {
    let app = try await makeTestApplication()
    do {
      try await body(app)
      try await app.asyncShutdown()
    } catch {
      try? await app.asyncShutdown()
      throw error
    }
  }

  private func makeTestApplication() async throws -> Application {
    let app = try await Application.make(.testing)
    app.serverHealth = ServerHealth()
    app.serverHealth.set(.ready)
    app.rateLimiter = IPRateLimiter()
    app.ttsService = TestTTSService()
    app.middleware = Middlewares()
    app.middleware.use(OpenAIErrorMiddleware())
    app.middleware.use(RateLimitMiddleware())
    try app.grouped("v1").register(collection: SpeechController())
    return app
  }
}

private final class TestTTSService: TTSService, @unchecked Sendable {
  let sampleRate = 48_000
  let defaultVoice = "test-voice"
  let availableVoices = ["test-voice"]

  func synthesize(text: String, voice: String) async throws -> Data {
    makeWAV(pcmData: pcm, sampleRate: sampleRate)
  }

  func synthesizeStream(
    text: String, voice: String
  ) -> AsyncThrowingStream<Data, Error> {
    AsyncThrowingStream { continuation in
      continuation.yield(pcm)
      continuation.finish()
    }
  }

  private var pcm: Data {
    var data = Data(capacity: 48_000)
    for frame in 0..<24_000 {
      var sample = Int16(sin(2 * Double.pi * 220 * Double(frame) / 48_000) * 8_000)
        .littleEndian
      withUnsafeBytes(of: &sample) { data.append(contentsOf: $0) }
    }
    return data
  }
}

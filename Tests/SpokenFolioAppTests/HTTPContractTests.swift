import SiriTTSCore
import TTSKit
import Vapor
import XCTVapor
import XCTest

@testable import SpokenFolioApp

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
          XCTAssertEqual(response.headers.first(name: .cacheControl), "no-store")
          XCTAssertEqual(
            response.headers.first(name: .contentLength), String(response.body.readableBytes))
          XCTAssertTrue(
            response.body.getData(at: 0, length: 4)?.starts(with: Data("OggS".utf8)) == true)
        })
    }
  }

  func testDegradedGatewayKeepsLivenessAndReturnsPermissionError() async throws {
    try await withTestApplication(healthFailure: .permissionRequired) { app in
      try await app.test(
        .GET, "/health/live", beforeRequest: { _ in },
        afterResponse: { response in
          await Task.yield()
          XCTAssertEqual(response.status, .ok)
        })
      for path in ["/health/ready", "/v1/models"] {
        try await app.test(
          .GET, path, beforeRequest: { _ in },
          afterResponse: { response in
            await Task.yield()
            XCTAssertEqual(response.status, .serviceUnavailable)
            let error = try response.content.decode(OpenAIErrorResponse.self)
            XCTAssertEqual(error.error.code, "siri_permission_required")
          })
      }
      try await app.test(
        .POST, "/v1/audio/speech",
        beforeRequest: { request in
          try request.content.encode([
            "model": "tts-1", "input": "Hello.", "voice": "test-voice",
            "response_format": "opus",
          ])
        },
        afterResponse: { response in
          await Task.yield()
          XCTAssertEqual(response.status, .serviceUnavailable)
          let error = try response.content.decode(OpenAIErrorResponse.self)
          XCTAssertEqual(error.error.code, "siri_permission_required")
        })
      try await app.test(
        .GET, "/v1/audio/voices/all", beforeRequest: { _ in },
        afterResponse: { response in
          await Task.yield()
          XCTAssertEqual(response.status, .ok)
        })
    }
  }

  func testRateLimiterTrackingIsHardBounded() async {
    let limiter = IPRateLimiter()
    for index in 0..<4_200 {
      let key = "client-\(index)"
      let acquired = await limiter.acquire(key)
      XCTAssertTrue(acquired)
      await limiter.release(key)
    }
    let count = await limiter.trackedClientCount
    XCTAssertLessThanOrEqual(count, 4_096)
  }

  private func withTestApplication(
    healthFailure: ServiceError? = nil,
    _ body: (Application) async throws -> Void
  ) async throws {
    let app = try await makeTestApplication(healthFailure: healthFailure)
    do {
      try await body(app)
      try await app.asyncShutdown()
    } catch {
      try? await app.asyncShutdown()
      throw error
    }
  }

  private func makeTestApplication(healthFailure: ServiceError? = nil) async throws -> Application {
    let app = try await Application.make(.testing)
    app.serverHealth = ServerHealth()
    if let healthFailure { app.serverHealth.setFailure(healthFailure) } else {
      app.serverHealth.set(.ready)
    }
    app.rateLimiter = IPRateLimiter()
    app.ttsService = TestTTSService()
    app.middleware = Middlewares()
    app.middleware.use(OpenAIErrorMiddleware())
    app.middleware.use(RateLimitMiddleware())
    try app.grouped("v1").register(collection: SpeechController())
    try app.grouped("v1").register(collection: VoicesController())
    try app.register(collection: HealthController())
    return app
  }
}

private final class TestTTSService: TTSService, @unchecked Sendable {
  let defaultVoice = "test-voice"
  let voiceCatalog = [VoiceInfo(id: "test-voice", name: "Test", lang: "en-US", quality: "test")]

  func synthesize(text: String, voice: String) async throws -> PCM16Audio {
    try PCM16Audio(data: pcm, sampleRate: 48_000, channels: 1)
  }

  func resolveVoice(_ voice: String) -> String? { voice == defaultVoice ? voice : nil }

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

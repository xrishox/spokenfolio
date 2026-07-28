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
          XCTAssertEqual(response.headers.first(name: .cacheControl), "no-store")
          XCTAssertEqual(
            response.headers.first(name: .contentLength), String(response.body.readableBytes))
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

  func testExpressiveModelRoutesQualifiedVoiceAndPresetControls() async throws {
    try await withTestApplication { app in
      try await app.test(
        .POST,
        "/v1/audio/speech",
        beforeRequest: { request in
          try request.content.encode(
            ExpressiveSpeechPayload(
              model: "siri-expressive",
              input: "One expressive paragraph.",
              voice: "en-US-F",
              responseFormat: "wav",
              pace: 2,
              expressivity: 5))
        },
        afterResponse: { response in
          await Task.yield()
          XCTAssertEqual(response.status, .ok)
          XCTAssertEqual(response.headers.first(name: .contentType), "audio/wav")
        })
      let service = try XCTUnwrap(app.ttsService as? TestTTSService)
      let request = try XCTUnwrap(service.lastRequest)
      XCTAssertEqual(request.selection.voice.backendID.rawValue, "siri-fm")
      XCTAssertEqual(request.selection.voice.modelID, "siri-expressive")
      XCTAssertEqual(request.selection.voice.voiceID, "en-US-F")
      XCTAssertEqual(request.selection.controls.pace?.rawValue, 2)
      XCTAssertEqual(request.selection.controls.expressivity?.rawValue, 5)
      XCTAssertEqual(request.utteranceMode, .singleUtterance)
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

private struct ExpressiveSpeechPayload: Content {
  let model: String
  let input: String
  let voice: String
  let responseFormat: String
  let pace: Int
  let expressivity: Int

  enum CodingKeys: String, CodingKey {
    case model, input, voice, pace, expressivity
    case responseFormat = "response_format"
  }
}

private final class TestTTSService: TTSService, @unchecked Sendable {
  let defaultVoice = "test-voice"
  let defaultModelID = "tts-1"
  let defaultSelection = TTSVoiceSelection(
    voice: VoiceKey(
      backendID: TTSBackendID(rawValue: "siri"),
      modelID: "siri-private", voiceID: "test-voice"))
  let voiceCatalog = [VoiceInfo(id: "test-voice", name: "Test", lang: "en-US", quality: "test")]
  let allVoiceCatalog = [
    VoiceInfo(
      id: "test-voice", name: "Test", lang: "en-US", quality: "test",
      backend: "siri", model: "siri-private", supportsPace: false,
      supportsExpressivity: false),
    VoiceInfo(
      id: "en-US-F", name: "American Voice 7", lang: "en-US", quality: "premium",
      backend: "siri-fm", model: "siri-expressive", supportsPace: true,
      supportsExpressivity: true),
  ]
  let modelCatalog = [
    TTSModelInfo(
      id: "tts-1", backendID: "siri", modelID: "siri-private", name: "Siri",
      defaultVoiceID: "test-voice", supportsPace: false, supportsExpressivity: false),
    TTSModelInfo(
      id: "tts-1-hd", backendID: "siri", modelID: "siri-private", name: "Siri",
      defaultVoiceID: "test-voice", supportsPace: false, supportsExpressivity: false),
    TTSModelInfo(
      id: "siri-expressive", backendID: "siri-fm", modelID: "siri-expressive",
      name: "Siri Expressive (Golden Gate)", defaultVoiceID: "en-US-F",
      supportsPace: true, supportsExpressivity: true),
  ]
  private let lock = NSLock()
  private var recordedRequest: TTSSynthesisRequest?

  var lastRequest: TTSSynthesisRequest? { lock.withLock { recordedRequest } }

  func synthesize(text: String, voice: String) async throws -> PCM16Audio {
    try PCM16Audio(data: pcm, sampleRate: 48_000, channels: 1)
  }

  func synthesize(request: TTSSynthesisRequest) async throws -> PCM16Audio {
    lock.withLock { recordedRequest = request }
    return try PCM16Audio(data: pcm, sampleRate: 48_000, channels: 1)
  }

  func resolveSelection(
    model: String, voice: String?, pace: Int?, expressivity: Int?
  ) throws -> TTSVoiceSelection {
    if model == "siri-expressive" {
      guard voice == nil || voice == "en-US-F" else {
        throw ServiceError.voiceNotFound(voice!)
      }
      return TTSVoiceSelection(
        voice: VoiceKey(
          backendID: TTSBackendID(rawValue: "siri-fm"),
          modelID: "siri-expressive", voiceID: "en-US-F"),
        controls: TTSSynthesisControls(
          pace: try TTSPreset(pace ?? 3), expressivity: try TTSPreset(expressivity ?? 3)))
    }
    guard model == "tts-1" || model == "tts-1-hd" else {
      throw ServiceError.invalidInput("Unknown model '\(model)'.", code: "model_not_found")
    }
    guard pace == nil, expressivity == nil else {
      throw ServiceError.invalidInput(
        "This model does not support expressive controls.", code: "unsupported_controls")
    }
    let resolved = voice ?? defaultVoice
    guard resolveVoice(resolved) != nil else { throw ServiceError.voiceNotFound(resolved) }
    return TTSVoiceSelection(
      voice: VoiceKey(
        backendID: TTSBackendID(rawValue: "siri"),
        modelID: "siri-private", voiceID: resolved))
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

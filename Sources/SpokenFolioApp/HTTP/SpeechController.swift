import TTSKit
import Vapor

struct SpeechController: RouteCollection {
  func boot(routes: any RoutesBuilder) throws {
    routes.post("audio", "speech", use: handleSpeech)
  }

  @Sendable
  func handleSpeech(req: Request) async throws -> Response {
    let speech = try req.content.decode(SpeechRequest.self)
    guard !speech.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ServiceError.invalidInput("'input' must be non-empty.", code: "invalid_input")
    }
    guard speech.input.count <= 4_096 else {
      throw ServiceError.invalidInput(
        "'input' must be 4096 characters or fewer.", code: "invalid_input")
    }
    guard speech.resolvedSpeed == 1.0 else {
      throw ServiceError.invalidInput(
        "This endpoint supports speed 1.0 only; expressive models use the pace preset.",
        code: "unsupported_speed")
    }

    let format = speech.resolvedFormat.lowercased()
    guard ["opus", "aac", "wav", "pcm"].contains(format) else {
      throw ServiceError.invalidInput(
        "'response_format' must be 'opus', 'aac', 'wav', or 'pcm'.",
        code: "unsupported_format")
    }

    try req.application.serverHealth.requireReady()

    let service = req.ttsService
    let selection = try service.resolveSelection(
      model: speech.model,
      voice: speech.voice,
      pace: speech.pace,
      expressivity: speech.expressivity)
    let request = TTSSynthesisRequest(
      text: speech.input,
      selection: selection,
      utteranceMode: speech.model == "siri-expressive" ? .singleUtterance : .sentenceSequence)
    let audio = try await service.synthesize(request: request)
    guard !audio.data.isEmpty else { throw ServiceError.synthesisFailed }

    let sampleRate = audio.sampleRate
    let pcmForEncoding = audio.data
    let encoded = try await req.application.threadPool.runIfActive(eventLoop: req.eventLoop) {
      switch format {
      case "opus":
        try AudioResponseEncoder.encodeOpus(pcm16: pcmForEncoding, sampleRate: sampleRate)
      case "aac":
        try AudioResponseEncoder.encodeAAC(pcm16: pcmForEncoding, sampleRate: sampleRate)
      case "wav": makeWAV(pcmData: pcmForEncoding, sampleRate: sampleRate)
      case "pcm": pcmForEncoding
      default: preconditionFailure("validated response format changed")
      }
    }.get()

    let response = Response(status: .ok, body: .init(data: encoded))
    switch format {
    case "opus":
      response.headers.contentType = HTTPMediaType(
        type: "audio", subType: "ogg", parameters: ["codecs": "opus"])
    case "aac":
      response.headers.contentType = HTTPMediaType(
        type: "audio", subType: "mp4", parameters: ["codecs": "mp4a.40.2"])
    case "wav": response.headers.contentType = HTTPMediaType(type: "audio", subType: "wav")
    case "pcm": response.headers.contentType = HTTPMediaType(type: "audio", subType: "pcm")
    default: break
    }
    response.headers.replaceOrAdd(name: .contentLength, value: String(encoded.count))
    response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
    return response
  }
}

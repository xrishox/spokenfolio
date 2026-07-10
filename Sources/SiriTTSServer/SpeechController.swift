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
    guard ["tts-1", "tts-1-hd"].contains(speech.model) else {
      throw ServiceError.invalidInput("Unknown model '\(speech.model)'.", code: "model_not_found")
    }
    guard speech.resolvedSpeed == 1.0 else {
      throw ServiceError.invalidInput(
        "This Siri endpoint supports speed 1.0 only.", code: "unsupported_speed")
    }

    let format = speech.resolvedFormat.lowercased()
    guard ["opus", "aac", "wav", "pcm"].contains(format) else {
      throw ServiceError.invalidInput(
        "'response_format' must be 'opus', 'aac', 'wav', or 'pcm'.",
        code: "unsupported_format")
    }

    let service = req.ttsService
    let requestedVoice = speech.voice ?? service.defaultVoice
    guard let voice = service.resolveVoice(requestedVoice) else {
      throw ServiceError.voiceNotFound(requestedVoice)
    }

    var pcm = Data()
    for try await chunk in service.synthesizeStream(text: speech.input, voice: voice) {
      pcm.append(chunk)
    }
    guard !pcm.isEmpty else { throw ServiceError.synthesisFailed }

    let sampleRate = service.sampleRate
    let pcmForEncoding = pcm
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

import Vapor

struct SpeechRequest: Content {
  let model: String
  let input: String
  let voice: String?
  let responseFormat: String?
  let speed: Double?
  let pace: Int?
  let expressivity: Int?

  var resolvedFormat: String { responseFormat ?? "wav" }
  var resolvedSpeed: Double { speed ?? 1.0 }

  enum CodingKeys: String, CodingKey {
    case model, input, voice, speed, pace, expressivity
    case responseFormat = "response_format"
  }
}

import AVFAudio
import Foundation

enum ServerConnectionTester {
  enum Failure: Error { case invalidURL, http, decode }

  static func run(port: Int, voice: String) async throws {
    guard let url = URL(string: "http://127.0.0.1:\(port)/v1/audio/speech") else {
      throw Failure.invalidURL
    }
    for format in ["opus", "aac"] {
      var request = URLRequest(url: url)
      request.httpMethod = "POST"
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: [
        "model": "tts-1",
        "voice": voice,
        "response_format": format,
        "input": "Siri connection test.",
      ])
      let (audio, response) = try await URLSession.shared.data(for: request)
      guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.http }
      try decode(audio, fileExtension: format == "opus" ? "ogg" : "m4a")
    }
  }

  private static func decode(_ audio: Data, fileExtension: String) throws {
    let fileURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("siri-tts-\(UUID().uuidString).\(fileExtension)")
    defer { try? FileManager.default.removeItem(at: fileURL) }
    try audio.write(to: fileURL, options: .atomic)
    let file = try AVAudioFile(forReading: fileURL)
    guard file.length > 0, file.processingFormat.channelCount == 1,
      file.processingFormat.sampleRate == 48_000,
      let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8_192)
    else { throw Failure.decode }
    var decoded: AVAudioFramePosition = 0
    while file.framePosition < file.length {
      try file.read(into: buffer, frameCount: buffer.frameCapacity)
      guard buffer.frameLength > 0 else { throw Failure.decode }
      decoded += AVAudioFramePosition(buffer.frameLength)
    }
    guard decoded > 0 else { throw Failure.decode }
  }
}

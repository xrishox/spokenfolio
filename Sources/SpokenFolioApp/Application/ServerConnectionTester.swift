import AVFAudio
import Foundation

enum ServerConnectionTester {
  enum Failure: Error, Equatable, LocalizedError {
    case invalidURL
    case transport(format: String)
    case http(format: String, statusCode: Int?)
    case decode(format: String)

    var errorDescription: String? {
      switch self {
      case .invalidURL:
        return "The local audio-test URL is invalid. Restart SpokenFolio and try again."
      case .transport(let format):
        return "The \(Self.displayName(for: format)) test could not reach the local TTS server. Check the server status and try again."
      case .http(let format, let statusCode):
        let format = Self.displayName(for: format)
        if let statusCode {
          return "The \(format) test returned HTTP \(statusCode). Check the server status and try again."
        } else {
          return "The \(format) test did not receive an HTTP response. Check the server status and try again."
        }
      case .decode(let format):
        return "The \(Self.displayName(for: format)) response was not valid mono 48 kHz audio. Open Console for details."
      }
    }

    private static func displayName(for format: String) -> String {
      switch format.lowercased() {
      case "opus": "Opus"
      case "aac": "AAC"
      default: format.uppercased()
      }
    }
  }

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
      let audio: Data
      let response: URLResponse
      do {
        (audio, response) = try await URLSession.shared.data(for: request)
      } catch {
        if Task.isCancelled { throw CancellationError() }
        throw Failure.transport(format: format)
      }
      let statusCode = (response as? HTTPURLResponse)?.statusCode
      guard statusCode == 200 else { throw Failure.http(format: format, statusCode: statusCode) }
      do {
        try decode(audio, fileExtension: format == "opus" ? "ogg" : "m4a")
      } catch {
        throw Failure.decode(format: format)
      }
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
    else { throw Failure.decode(format: fileExtension) }
    var decoded: AVAudioFramePosition = 0
    while file.framePosition < file.length {
      try file.read(into: buffer, frameCount: buffer.frameCapacity)
      guard buffer.frameLength > 0 else { throw Failure.decode(format: fileExtension) }
      decoded += AVAudioFramePosition(buffer.frameLength)
    }
    guard decoded > 0 else { throw Failure.decode(format: fileExtension) }
  }
}

import AVFAudio
import Foundation

enum ServerConnectionTester {
  struct Selection: Equatable, Sendable {
    let publicModelID: String
    let voiceID: String
    let pacePreset: Int?
    let expressivityPreset: Int?
  }

  enum Failure: Error, Equatable, LocalizedError {
    case invalidURL
    case invalidInput
    case transport(format: String)
    case http(format: String, statusCode: Int?)
    case response(format: String)
    case decode(format: String)

    var errorDescription: String? {
      switch self {
      case .invalidURL:
        return "The local audio-test URL is invalid. Restart SpokenFolio and try again."
      case .invalidInput:
        return "Enter between 1 and 4,096 characters to test."
      case .transport(let format):
        return "The \(Self.displayName(for: format)) test could not reach the local TTS server. Check the server status and try again."
      case .http(let format, let statusCode):
        let format = Self.displayName(for: format)
        if let statusCode {
          return "The \(format) test returned HTTP \(statusCode). Check the server status and try again."
        } else {
          return "The \(format) test did not receive an HTTP response. Check the server status and try again."
        }
      case .response(let format):
        return "The \(Self.displayName(for: format)) test returned an empty or incorrectly typed audio response."
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

  /// Exercises both public compressed formats and returns the verified AAC
  /// container so the caller can retain an AVAudioPlayer and play it.
  static func run(
    port: Int, selection: Selection, text: String
  ) async throws -> Data {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, text.count <= 4_096 else { throw Failure.invalidInput }
    guard let url = URL(string: "http://127.0.0.1:\(port)/v1/audio/speech") else {
      throw Failure.invalidURL
    }
    var playableAAC = Data()
    for format in ["opus", "aac"] {
      var request = URLRequest(url: url)
      request.httpMethod = "POST"
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try requestBody(selection: selection, text: text, format: format)
      let audio: Data
      let response: URLResponse
      do {
        (audio, response) = try await URLSession.shared.data(for: request)
      } catch {
        if Task.isCancelled { throw CancellationError() }
        throw Failure.transport(format: format)
      }
      guard let http = response as? HTTPURLResponse else {
        throw Failure.http(format: format, statusCode: nil)
      }
      guard http.statusCode == 200 else {
        throw Failure.http(format: format, statusCode: http.statusCode)
      }
      let expectedMIME = format == "opus" ? "audio/ogg" : "audio/mp4"
      guard !audio.isEmpty, http.value(forHTTPHeaderField: "Content-Type")?
        .lowercased().hasPrefix(expectedMIME) == true
      else { throw Failure.response(format: format) }
      do {
        try decode(audio, fileExtension: format == "opus" ? "ogg" : "m4a")
      } catch {
        throw Failure.decode(format: format)
      }
      if format == "aac" { playableAAC = audio }
    }
    return playableAAC
  }

  static func requestBody(
    selection: Selection, text: String, format: String
  ) throws -> Data {
    var body: [String: Any] = [
      "model": selection.publicModelID,
      "voice": selection.voiceID,
      "response_format": format,
      "input": text,
    ]
    if let pacePreset = selection.pacePreset { body["pace"] = pacePreset }
    if let expressivityPreset = selection.expressivityPreset {
      body["expressivity"] = expressivityPreset
    }
    return try JSONSerialization.data(withJSONObject: body)
  }

  private static func decode(_ audio: Data, fileExtension: String) throws {
    let fileURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("spokenfolio-tts-test-\(UUID().uuidString).\(fileExtension)")
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

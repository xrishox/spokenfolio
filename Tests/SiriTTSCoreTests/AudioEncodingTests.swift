import AVFAudio
import XCTest

@testable import SiriTTSCore

final class AudioEncodingTests: XCTestCase {
  func testAllAdvertisedFormatsHaveValidContainersAndDecode() throws {
    let pcm = sineWavePCM(seconds: 1)
    let formats: [(String, Data)] = [
      ("ogg", try AudioResponseEncoder.encodeOpus(pcm16: pcm, sampleRate: 48_000)),
      ("m4a", try AudioResponseEncoder.encodeAAC(pcm16: pcm, sampleRate: 48_000)),
      ("wav", makeWAV(pcmData: pcm, sampleRate: 48_000)),
    ]

    XCTAssertTrue(formats[0].1.starts(with: Data("OggS".utf8)))
    XCTAssertEqual(formats[1].1.subdata(in: 4..<8), Data("ftyp".utf8))
    XCTAssertTrue(formats[2].1.starts(with: Data("RIFF".utf8)))

    for (extensionName, data) in formats {
      let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("encoding-test-\(UUID().uuidString).\(extensionName)")
      defer { try? FileManager.default.removeItem(at: url) }
      try data.write(to: url)
      let file = try AVAudioFile(forReading: url)
      XCTAssertGreaterThan(file.length, 0)
      XCTAssertEqual(file.processingFormat.channelCount, 1)
      let buffer = try XCTUnwrap(
        AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8_192))
      var decoded: AVAudioFramePosition = 0
      while file.framePosition < file.length {
        try file.read(into: buffer, frameCount: buffer.frameCapacity)
        XCTAssertGreaterThan(buffer.frameLength, 0)
        decoded += AVAudioFramePosition(buffer.frameLength)
      }
      XCTAssertGreaterThan(decoded, 0)
    }
  }

  func testEncodersRejectEmptyAndMisalignedPCM() {
    XCTAssertThrowsError(try AudioResponseEncoder.encodeOpus(pcm16: Data(), sampleRate: 48_000))
    XCTAssertThrowsError(try AudioResponseEncoder.encodeAAC(pcm16: Data([0]), sampleRate: 48_000))
  }

  private func sineWavePCM(seconds: Int) -> Data {
    var data = Data(capacity: 48_000 * seconds * 2)
    for frame in 0..<(48_000 * seconds) {
      let sample = sin(2 * Double.pi * 440 * Double(frame) / 48_000)
      var value = Int16(sample * 12_000).littleEndian
      withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }
    return data
  }
}

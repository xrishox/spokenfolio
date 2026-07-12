import Foundation

// MARK: - Shared PCM conversion utilities

// Wraps raw 16-bit PCM data in a RIFF/WAVE container with
// correct size fields. Use this for complete (non-streaming) WAV responses.
package func makeWAV(pcmData: Data, sampleRate: Int, channels: Int = 1, bitsPerSample: Int = 16) -> Data {
  var wav = Data()
  let dataSize = UInt32(pcmData.count)
  let byteRate = UInt32(sampleRate * channels * bitsPerSample / 8)
  let blockAlign = UInt16(channels * bitsPerSample / 8)

  func u32(_ v: UInt32) {
    var le = v.littleEndian
    withUnsafeBytes(of: &le) { wav.append(contentsOf: $0) }
  }
  func u16(_ v: UInt16) {
    var le = v.littleEndian
    withUnsafeBytes(of: &le) { wav.append(contentsOf: $0) }
  }

  wav.append(contentsOf: "RIFF".utf8)
  u32(36 + dataSize)  // file size minus the 8-byte "RIFF" + size field
  wav.append(contentsOf: "WAVE".utf8)
  wav.append(contentsOf: "fmt ".utf8)
  u32(16)  // PCM fmt chunk size
  u16(1)  // PCM audio format
  u16(UInt16(channels))
  u32(UInt32(sampleRate))
  u32(byteRate)
  u16(blockAlign)
  u16(UInt16(bitsPerSample))
  wav.append(contentsOf: "data".utf8)
  u32(dataSize)
  wav.append(pcmData)

  return wav
}

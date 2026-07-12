import AVFAudio
import Foundation

package enum PCMNormalizer {
  package static let outputSampleRate = 48_000
  package static let outputChannels = 1

  package static func normalize(_ audio: PCM16Audio) throws -> PCM16Audio {
    if audio.sampleRate == outputSampleRate, audio.channels == outputChannels { return audio }

    let inputFrames = audio.data.count / (MemoryLayout<Int16>.size * audio.channels)
    guard inputFrames > 0, inputFrames <= Int(AVAudioFrameCount.max) else {
      throw TTSBackendError.invalidAudioFormat
    }
    guard
      let inputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: Double(audio.sampleRate),
        channels: AVAudioChannelCount(audio.channels),
        interleaved: true),
      let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: Double(outputSampleRate),
        channels: AVAudioChannelCount(outputChannels),
        interleaved: true),
      let inputBuffer = AVAudioPCMBuffer(
        pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(inputFrames)),
      let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
    else { throw TTSBackendError.invalidAudioFormat }

    inputBuffer.frameLength = inputBuffer.frameCapacity
    guard let destination = inputBuffer.mutableAudioBufferList.pointee.mBuffers.mData else {
      throw TTSBackendError.invalidAudioFormat
    }
    audio.data.withUnsafeBytes { source in
      if let baseAddress = source.baseAddress {
        destination.copyMemory(from: baseAddress, byteCount: source.count)
      }
    }

    converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
    let estimatedFrames =
      Int(ceil(Double(inputFrames) * Double(outputSampleRate) / Double(audio.sampleRate))) + 64
    guard estimatedFrames > 0, estimatedFrames <= Int(AVAudioFrameCount.max),
      let outputBuffer = AVAudioPCMBuffer(
        pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(estimatedFrames))
    else { throw TTSBackendError.invalidAudioFormat }

    let state = PCMInputState(buffer: inputBuffer)
    var conversionError: NSError?
    let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
      state.next(status: inputStatus)
    }
    guard status != .error, outputBuffer.frameLength > 0,
      let bytes = outputBuffer.audioBufferList.pointee.mBuffers.mData
    else { throw TTSBackendError.invalidAudioFormat }
    let byteCount = Int(outputBuffer.frameLength) * MemoryLayout<Int16>.size * outputChannels
    return try PCM16Audio(
      data: Data(bytes: bytes, count: byteCount),
      sampleRate: outputSampleRate,
      channels: outputChannels)
  }
}

private final class PCMInputState: @unchecked Sendable {
  private let buffer: AVAudioPCMBuffer
  private let lock = NSLock()
  private var supplied = false

  init(buffer: AVAudioPCMBuffer) { self.buffer = buffer }

  func next(status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
    lock.lock()
    defer { lock.unlock() }
    if supplied {
      status.pointee = .endOfStream
      return nil
    }
    supplied = true
    status.pointee = .haveData
    return buffer
  }
}

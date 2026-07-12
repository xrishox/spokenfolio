import AVFAudio
import AudioToolbox
import Foundation

/// Encodes complete mono PCM responses into mobile-friendly compressed files.
///
/// Both encoders resample the service's native PCM to 48 kHz. The HTTP layer
/// intentionally buffers these formats until the file is complete so clients
/// never receive a partial Ogg or MP4 container after a synthesis/encode error.
package enum AudioResponseEncoder {
  package static let outputSampleRate = 48_000
  package static let opusBitRate = 64_000
  package static let aacBitRate = 64_000

  /// Encodes PCM16-LE mono audio as RFC 7845 Ogg Opus.
  package static func encodeOpus(pcm16: Data, sampleRate: Int) throws -> Data {
    let encoded = try encodePackets(
      pcm16: pcm16,
      sampleRate: sampleRate,
      formatID: kAudioFormatOpus,
      bitRate: opusBitRate,
      bitRateStrategy: AVAudioBitRateStrategy_VariableConstrained,
      nominalFramesPerPacket: 960
    )
    return try OggOpusMuxer.mux(
      packets: encoded.packets,
      leadingFrames: encoded.leadingFrames,
      trailingFrames: encoded.trailingFrames
    )
  }

  /// Encodes PCM16-LE mono audio as AAC-LC in an audio-only MP4 (M4A) file.
  package static func encodeAAC(pcm16: Data, sampleRate: Int) throws -> Data {
    let encoded = try encodePackets(
      pcm16: pcm16,
      sampleRate: sampleRate,
      formatID: kAudioFormatMPEG4AAC,
      bitRate: aacBitRate,
      bitRateStrategy: AVAudioBitRateStrategy_Constant,
      nominalFramesPerPacket: 1024
    )
    return try M4AMuxer.mux(encoded)
  }

  private static func encodePackets(
    pcm16: Data,
    sampleRate: Int,
    formatID: AudioFormatID,
    bitRate: Int,
    bitRateStrategy: String,
    nominalFramesPerPacket: Int
  ) throws -> EncodedAudioPackets {
    guard !pcm16.isEmpty else { throw AudioEncodingError.emptyPCM }
    guard pcm16.count.isMultiple(of: MemoryLayout<Int16>.size) else {
      throw AudioEncodingError.misalignedPCM
    }
    guard sampleRate > 0 else { throw AudioEncodingError.invalidSampleRate(sampleRate) }

    let frameCount = pcm16.count / MemoryLayout<Int16>.size
    guard frameCount <= Int(AVAudioFrameCount.max) else { throw AudioEncodingError.inputTooLarge }
    guard
      let inputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: Double(sampleRate),
        channels: 1,
        interleaved: true),
      let outputFormat = AVAudioFormat(settings: [
        AVFormatIDKey: formatID,
        AVSampleRateKey: outputSampleRate,
        AVNumberOfChannelsKey: 1,
      ])
    else {
      throw AudioEncodingError.unsupportedFormat(formatID)
    }

    guard
      let inputBuffer = AVAudioPCMBuffer(
        pcmFormat: inputFormat,
        frameCapacity: AVAudioFrameCount(frameCount))
    else {
      throw AudioEncodingError.bufferAllocationFailed
    }
    inputBuffer.frameLength = inputBuffer.frameCapacity
    guard let destination = inputBuffer.mutableAudioBufferList.pointee.mBuffers.mData else {
      throw AudioEncodingError.bufferAllocationFailed
    }
    pcm16.withUnsafeBytes { source in
      if let baseAddress = source.baseAddress {
        destination.copyMemory(from: baseAddress, byteCount: source.count)
      }
    }

    guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
      throw AudioEncodingError.converterUnavailable(formatID)
    }
    converter.bitRate = bitRate
    converter.bitRateStrategy = bitRateStrategy
    converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue

    let estimatedOutputFrames =
      Double(frameCount) * Double(outputSampleRate) / Double(sampleRate)
      + Double(converter.primeInfo.leadingFrames)
      + Double(nominalFramesPerPacket * 2)
    let estimatedPacketCount = Int(ceil(estimatedOutputFrames / Double(nominalFramesPerPacket))) + 8
    guard estimatedPacketCount > 0, estimatedPacketCount <= Int(AVAudioPacketCount.max) else {
      throw AudioEncodingError.inputTooLarge
    }
    guard converter.maximumOutputPacketSize > 0 else {
      throw AudioEncodingError.invalidMaximumPacketSize
    }

    let inputState = ConverterInputState(buffer: inputBuffer)
    var packets: [Data] = []
    var reachedEnd = false
    var iterations = 0

    while !reachedEnd {
      iterations += 1
      guard iterations <= 4 else { throw AudioEncodingError.converterDidNotFinish }
      let outputBuffer = AVAudioCompressedBuffer(
        format: outputFormat,
        packetCapacity: AVAudioPacketCount(estimatedPacketCount),
        maximumPacketSize: converter.maximumOutputPacketSize)

      var conversionError: NSError?
      let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
        inputState.next(status: inputStatus)
      }
      try appendPackets(from: outputBuffer, to: &packets)

      switch status {
      case .haveData:
        if outputBuffer.packetCount == 0 { throw AudioEncodingError.converterProducedNoData }
      case .inputRanDry:
        if outputBuffer.packetCount == 0 { continue }
      case .endOfStream:
        reachedEnd = true
      case .error:
        throw AudioEncodingError.conversionFailed(
          conversionError?.localizedDescription ?? "Unknown AVAudioConverter error")
      @unknown default:
        throw AudioEncodingError.conversionFailed("Unknown AVAudioConverter status")
      }
    }

    guard !packets.isEmpty else { throw AudioEncodingError.converterProducedNoData }
    let primeInfo = converter.primeInfo
    return EncodedAudioPackets(
      packets: packets,
      leadingFrames: Int(primeInfo.leadingFrames),
      trailingFrames: Int(primeInfo.trailingFrames),
      magicCookie: converter.magicCookie,
      outputFormat: outputFormat
    )
  }

  private static func appendPackets(
    from buffer: AVAudioCompressedBuffer,
    to packets: inout [Data]
  ) throws {
    guard buffer.packetCount > 0 else { return }
    guard let descriptions = buffer.packetDescriptions else {
      throw AudioEncodingError.missingPacketDescriptions
    }

    for index in 0..<Int(buffer.packetCount) {
      let description = descriptions[index]
      let offset = Int(description.mStartOffset)
      let size = Int(description.mDataByteSize)
      guard offset >= 0, size > 0, offset + size <= Int(buffer.byteLength) else {
        throw AudioEncodingError.invalidPacketDescription
      }
      packets.append(Data(bytes: buffer.data.advanced(by: offset), count: size))
    }
  }
}
enum AudioEncodingError: LocalizedError {
  case emptyPCM
  case misalignedPCM
  case invalidSampleRate(Int)
  case inputTooLarge
  case unsupportedFormat(AudioFormatID)
  case converterUnavailable(AudioFormatID)
  case bufferAllocationFailed
  case invalidMaximumPacketSize
  case converterDidNotFinish
  case converterProducedNoData
  case conversionFailed(String)
  case missingPacketDescriptions
  case invalidPacketDescription
  case invalidOpusPacket
  case invalidPrimeInfo
  case tooManyOggSegments
  case missingMagicCookie
  case audioToolbox(operation: String, status: OSStatus)

  var errorDescription: String? {
    switch self {
    case .emptyPCM: "Cannot encode an empty PCM response."
    case .misalignedPCM: "PCM16 data must contain a whole number of 16-bit samples."
    case .invalidSampleRate(let rate): "Invalid PCM sample rate: \(rate)."
    case .inputTooLarge: "PCM response is too large to encode."
    case .unsupportedFormat(let format):
      "The system does not support audio format \(fourCC(format))."
    case .converterUnavailable(let format):
      "No encoder is available for audio format \(fourCC(format))."
    case .bufferAllocationFailed: "Could not allocate an audio conversion buffer."
    case .invalidMaximumPacketSize: "The audio encoder reported an invalid maximum packet size."
    case .converterDidNotFinish: "The audio encoder did not reach end-of-stream."
    case .converterProducedNoData: "The audio encoder produced no packets."
    case .conversionFailed(let message): "Audio encoding failed: \(message)"
    case .missingPacketDescriptions: "The audio encoder omitted packet descriptions."
    case .invalidPacketDescription: "The audio encoder returned an invalid packet description."
    case .invalidOpusPacket: "The Opus encoder returned an invalid packet."
    case .invalidPrimeInfo: "The audio encoder returned invalid priming information."
    case .tooManyOggSegments: "An Ogg page would exceed 255 lacing segments."
    case .missingMagicCookie: "The AAC encoder did not provide an MPEG-4 magic cookie."
    case .audioToolbox(let operation, let status):
      "\(operation) failed with AudioToolbox status \(status) (\(fourCC(UInt32(bitPattern: status))))."
    }
  }

  private func fourCC(_ value: UInt32) -> String {
    let bytes = [
      UInt8((value >> 24) & 0xFF),
      UInt8((value >> 16) & 0xFF),
      UInt8((value >> 8) & 0xFF),
      UInt8(value & 0xFF),
    ]
    guard bytes.allSatisfy({ $0 >= 0x20 && $0 <= 0x7E }) else { return "non-printable" }
    return String(bytes: bytes, encoding: .ascii) ?? "non-printable"
  }
}
struct EncodedAudioPackets {
  let packets: [Data]
  let leadingFrames: Int
  let trailingFrames: Int
  let magicCookie: Data?
  let outputFormat: AVAudioFormat
}

private final class ConverterInputState: @unchecked Sendable {
  private let buffer: AVAudioPCMBuffer
  private let lock = NSLock()
  private var supplied = false

  init(buffer: AVAudioPCMBuffer) {
    self.buffer = buffer
  }

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

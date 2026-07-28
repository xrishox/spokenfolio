import AudioToolbox
import Foundation
import TTSKit

private final class GoldenGateOpusInput: @unchecked Sendable {
  let data: Data
  let packets: [AudioStreamPacketDescription]
  let channels: UInt32
  var index = 0
  let scratchAudio = NSMutableData()
  let scratchPackets = NSMutableData()

  init(data: Data, packets: [AudioStreamPacketDescription], channels: UInt32) {
    self.data = data
    self.packets = packets
    self.channels = channels
  }
}

package enum GoldenGateAudioDecoder {
  package static func convertFloat32PCM(
    _ data: Data, sampleRate: Int, channels: Int
  ) throws -> PCM16Audio {
    guard sampleRate > 0, channels > 0,
      data.count.isMultiple(of: MemoryLayout<Float>.size * channels)
    else { throw GoldenGateTTSError.unsupportedAudioFormat("invalid Float32 frame layout") }

    var output = Data(capacity: data.count / 2)
    try data.withUnsafeBytes { raw in
      for offset in stride(from: 0, to: raw.count, by: MemoryLayout<Float>.size) {
        let sample = raw.loadUnaligned(fromByteOffset: offset, as: Float.self)
        guard sample.isFinite else {
          throw GoldenGateTTSError.unsupportedAudioFormat("nonfinite Float32 sample")
        }
        let converted: Int16
        if sample <= -1 {
          converted = .min
        } else if sample >= 1 {
          converted = .max
        } else {
          converted = Int16((sample * Float(Int16.max)).rounded())
        }
        var littleEndian = converted.littleEndian
        withUnsafeBytes(of: &littleEndian) { output.append(contentsOf: $0) }
      }
    }
    return try PCM16Audio(data: output, sampleRate: sampleRate, channels: channels)
  }

  package static func decodeOpus(
    _ data: Data,
    packetDescriptions: [AudioStreamPacketDescription],
    format: AudioStreamBasicDescription
  ) throws -> PCM16Audio {
    guard format.mFormatID == kAudioFormatOpus,
      format.mSampleRate > 0,
      format.mChannelsPerFrame > 0,
      !data.isEmpty, !packetDescriptions.isEmpty
    else { throw GoldenGateTTSError.unsupportedAudioFormat("invalid Opus packet stream") }
    for packet in packetDescriptions {
      let start = Int(packet.mStartOffset)
      let size = Int(packet.mDataByteSize)
      guard start >= 0, size > 0, start <= data.count, size <= data.count - start else {
        throw GoldenGateTTSError.unsupportedAudioFormat("Opus packet range is invalid")
      }
    }

    var source = format
    var destination = AudioStreamBasicDescription(
      mSampleRate: format.mSampleRate,
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
      mBytesPerPacket: 2 * format.mChannelsPerFrame,
      mFramesPerPacket: 1,
      mBytesPerFrame: 2 * format.mChannelsPerFrame,
      mChannelsPerFrame: format.mChannelsPerFrame,
      mBitsPerChannel: 16,
      mReserved: 0)
    var converter: AudioConverterRef?
    guard AudioConverterNew(&source, &destination, &converter) == noErr,
      let converter
    else { throw GoldenGateTTSError.unsupportedAudioFormat("could not create Opus decoder") }
    defer { AudioConverterDispose(converter) }

    let input = GoldenGateOpusInput(
      data: data, packets: packetDescriptions, channels: format.mChannelsPerFrame)
    let inputProc: AudioConverterComplexInputDataProc = {
      _, requestedPackets, bufferList, packetDescriptionsOut, userData in
      guard let userData else { return kAudio_ParamError }
      let input = Unmanaged<GoldenGateOpusInput>.fromOpaque(userData).takeUnretainedValue()
      let remaining = input.packets.count - input.index
      guard remaining > 0 else {
        requestedPackets.pointee = 0
        bufferList.pointee.mNumberBuffers = 1
        bufferList.pointee.mBuffers.mData = nil
        bufferList.pointee.mBuffers.mDataByteSize = 0
        packetDescriptionsOut?.pointee = nil
        return noErr
      }

      let count = min(Int(requestedPackets.pointee), remaining)
      var chunk = Data()
      var relative: [AudioStreamPacketDescription] = []
      relative.reserveCapacity(count)
      for packet in input.packets[input.index..<(input.index + count)] {
        let start = Int(packet.mStartOffset)
        let size = Int(packet.mDataByteSize)
        var adjusted = packet
        adjusted.mStartOffset = Int64(chunk.count)
        chunk.append(input.data[start..<(start + size)])
        relative.append(adjusted)
      }
      input.index += count
      input.scratchAudio.setData(chunk)
      input.scratchPackets.length = relative.count * MemoryLayout<AudioStreamPacketDescription>.size
      relative.withUnsafeBytes { bytes in
        if let base = bytes.baseAddress {
          input.scratchPackets.mutableBytes.copyMemory(from: base, byteCount: bytes.count)
        }
      }
      requestedPackets.pointee = UInt32(count)
      bufferList.pointee.mNumberBuffers = 1
      bufferList.pointee.mBuffers.mNumberChannels = input.channels
      bufferList.pointee.mBuffers.mDataByteSize = UInt32(input.scratchAudio.length)
      bufferList.pointee.mBuffers.mData = input.scratchAudio.mutableBytes
      packetDescriptionsOut?.pointee = input.scratchPackets.mutableBytes.assumingMemoryBound(
        to: AudioStreamPacketDescription.self)
      return noErr
    }

    let inputPointer = Unmanaged.passUnretained(input).toOpaque()
    let framesPerChunk = 4_096
    let bytesPerFrame = Int(destination.mBytesPerFrame)
    var pcm = Data()
    while true {
      var storage = [UInt8](repeating: 0, count: framesPerChunk * bytesPerFrame)
      var producedPackets = UInt32(framesPerChunk)
      let status: OSStatus = storage.withUnsafeMutableBytes { bytes in
        var buffers = AudioBufferList(
          mNumberBuffers: 1,
          mBuffers: AudioBuffer(
            mNumberChannels: destination.mChannelsPerFrame,
            mDataByteSize: UInt32(bytes.count),
            mData: bytes.baseAddress))
        return AudioConverterFillComplexBuffer(
          converter, inputProc, inputPointer, &producedPackets, &buffers, nil)
      }
      guard status == noErr else {
        throw GoldenGateTTSError.unsupportedAudioFormat(
          "Opus decoder failed with status \(status)")
      }
      if producedPackets == 0 { break }
      let byteCount = Int(producedPackets) * bytesPerFrame
      guard byteCount <= storage.count else {
        throw GoldenGateTTSError.unsupportedAudioFormat("Opus decoder overproduced audio")
      }
      pcm.append(contentsOf: storage.prefix(byteCount))
    }
    return try PCM16Audio(
      data: pcm,
      sampleRate: Int(destination.mSampleRate),
      channels: Int(destination.mChannelsPerFrame))
  }
}

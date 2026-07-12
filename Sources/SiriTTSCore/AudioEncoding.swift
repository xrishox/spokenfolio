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

private struct EncodedAudioPackets {
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

// MARK: - Ogg Opus

private enum OggOpusMuxer {
  private static let packetsPerPage = 50

  static func mux(
    packets: [Data],
    leadingFrames: Int,
    trailingFrames: Int
  ) throws -> Data {
    guard leadingFrames >= 0, leadingFrames <= Int(UInt16.max), trailingFrames >= 0 else {
      throw AudioEncodingError.invalidPrimeInfo
    }

    var packetDurations: [UInt64] = []
    packetDurations.reserveCapacity(packets.count)
    for packet in packets {
      packetDurations.append(UInt64(try opusPacketDuration(packet)))
    }
    let totalFrames = packetDurations.reduce(0, +)
    guard UInt64(trailingFrames) <= totalFrames else { throw AudioEncodingError.invalidPrimeInfo }

    let serial = UInt32.random(in: UInt32.min...UInt32.max)
    var sequence: UInt32 = 0
    var result = Data()

    var head = Data("OpusHead".utf8)
    head.append(1)  // OpusHead version
    head.append(1)  // mono
    head.appendLittleEndian(UInt16(leadingFrames))
    head.appendLittleEndian(UInt32(AudioResponseEncoder.outputSampleRate))
    head.appendLittleEndian(Int16(0))  // output gain
    head.append(0)  // channel mapping family 0
    result.append(
      try makePage(
        packets: [head], headerType: 0x02, granule: 0, serial: serial, sequence: sequence))
    sequence += 1

    let vendor = Data("macos-tts-server".utf8)
    var tags = Data("OpusTags".utf8)
    tags.appendLittleEndian(UInt32(vendor.count))
    tags.append(vendor)
    tags.appendLittleEndian(UInt32(0))  // user comment count
    result.append(
      try makePage(packets: [tags], headerType: 0, granule: 0, serial: serial, sequence: sequence))
    sequence += 1

    var pagePackets: [Data] = []
    var pageSegments = 0
    var cumulativeFrames: UInt64 = 0

    for index in packets.indices {
      let packet = packets[index]
      let segmentCount = lacingSegmentCount(forPacketSize: packet.count)
      guard segmentCount <= 255 else { throw AudioEncodingError.tooManyOggSegments }

      if !pagePackets.isEmpty
        && (pagePackets.count == packetsPerPage || pageSegments + segmentCount > 255)
      {
        result.append(
          try makePage(
            packets: pagePackets,
            headerType: 0,
            granule: cumulativeFrames,
            serial: serial,
            sequence: sequence))
        sequence += 1
        pagePackets.removeAll(keepingCapacity: true)
        pageSegments = 0
      }

      pagePackets.append(packet)
      pageSegments += segmentCount
      cumulativeFrames += packetDurations[index]
    }

    guard !pagePackets.isEmpty else { throw AudioEncodingError.converterProducedNoData }
    result.append(
      try makePage(
        packets: pagePackets,
        headerType: 0x04,
        granule: cumulativeFrames - UInt64(trailingFrames),
        serial: serial,
        sequence: sequence))
    return result
  }

  private static func opusPacketDuration(_ packet: Data) throws -> Int {
    guard let toc = packet.first else { throw AudioEncodingError.invalidOpusPacket }
    let configuration = Int(toc >> 3)
    let samplesPerFrame: Int
    switch configuration {
    case 0...11:
      samplesPerFrame = [480, 960, 1920, 2880][configuration & 0x03]
    case 12...15:
      samplesPerFrame = [480, 960][configuration & 0x01]
    default:
      samplesPerFrame = [120, 240, 480, 960][configuration & 0x03]
    }

    let frameCount: Int
    switch toc & 0x03 {
    case 0:
      frameCount = 1
    case 1, 2:
      frameCount = 2
    default:
      guard packet.count >= 2 else { throw AudioEncodingError.invalidOpusPacket }
      frameCount = Int(packet[packet.startIndex + 1] & 0x3F)
    }
    let duration = samplesPerFrame * frameCount
    guard frameCount > 0, duration <= 5760 else { throw AudioEncodingError.invalidOpusPacket }
    return duration
  }

  private static func lacingSegmentCount(forPacketSize size: Int) -> Int {
    size / 255 + 1
  }

  private static func makePage(
    packets: [Data],
    headerType: UInt8,
    granule: UInt64,
    serial: UInt32,
    sequence: UInt32
  ) throws -> Data {
    var lacing = Data()
    var body = Data()
    for packet in packets {
      var remaining = packet.count
      while remaining >= 255 {
        lacing.append(255)
        remaining -= 255
      }
      lacing.append(UInt8(remaining))
      body.append(packet)
    }
    guard lacing.count <= 255 else { throw AudioEncodingError.tooManyOggSegments }

    var page = Data("OggS".utf8)
    page.append(0)  // stream structure version
    page.append(headerType)
    page.appendLittleEndian(granule)
    page.appendLittleEndian(serial)
    page.appendLittleEndian(sequence)
    page.appendLittleEndian(UInt32(0))  // checksum placeholder
    page.append(UInt8(lacing.count))
    page.append(lacing)
    page.append(body)

    let checksum = oggCRC(page)
    var littleEndianChecksum = checksum.littleEndian
    let checksumBytes = withUnsafeBytes(of: &littleEndianChecksum) { Data($0) }
    page.replaceSubrange(22..<26, with: checksumBytes)
    return page
  }

  private static func oggCRC(_ data: Data) -> UInt32 {
    var crc: UInt32 = 0
    for byte in data {
      crc ^= UInt32(byte) << 24
      for _ in 0..<8 {
        crc = (crc & 0x8000_0000) != 0 ? (crc << 1) ^ 0x04C1_1DB7 : crc << 1
      }
    }
    return crc
  }
}

// MARK: - AAC in M4A

private enum M4AMuxer {
  static func mux(_ encoded: EncodedAudioPackets) throws -> Data {
    guard let magicCookie = encoded.magicCookie, !magicCookie.isEmpty else {
      throw AudioEncodingError.missingMagicCookie
    }

    var fileFormat = encoded.outputFormat.streamDescription.pointee
    var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    try check(
      AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, 0, nil, &formatSize, &fileFormat),
      operation: "AudioFormatGetProperty(kAudioFormatProperty_FormatInfo)")
    guard fileFormat.mFramesPerPacket > 0 else { throw AudioEncodingError.invalidPacketDescription }

    let totalFrames = Int64(encoded.packets.count) * Int64(fileFormat.mFramesPerPacket)
    let validFrames = totalFrames - Int64(encoded.leadingFrames) - Int64(encoded.trailingFrames)
    guard validFrames >= 0,
      encoded.leadingFrames <= Int(Int32.max),
      encoded.trailingFrames <= Int(Int32.max)
    else {
      throw AudioEncodingError.invalidPrimeInfo
    }

    let storage = MemoryAudioFileStorage()
    var audioFile: AudioFileID?
    try check(
      AudioFileInitializeWithCallbacks(
        Unmanaged.passUnretained(storage).toOpaque(),
        memoryAudioFileRead,
        memoryAudioFileWrite,
        memoryAudioFileGetSize,
        memoryAudioFileSetSize,
        kAudioFileM4AType,
        &fileFormat,
        AudioFileFlags(rawValue: 0),
        &audioFile),
      operation: "AudioFileInitializeWithCallbacks")
    guard let audioFile else { throw AudioEncodingError.bufferAllocationFailed }
    var isOpen = true
    defer {
      if isOpen { AudioFileClose(audioFile) }
    }

    // Without an explicit duration, the M4A writer reserves tens of kilobytes
    // for a worst-case packet table. Sentence TTS responses are short and their
    // duration is already known, so reserve only the header space they need.
    var reserveDuration = Double(validFrames) / Double(AudioResponseEncoder.outputSampleRate)
    try check(
      AudioFileSetProperty(
        audioFile,
        kAudioFilePropertyReserveDuration,
        UInt32(MemoryLayout<Double>.size),
        &reserveDuration),
      operation: "AudioFileSetProperty(kAudioFilePropertyReserveDuration)")

    try magicCookie.withUnsafeBytes { bytes in
      guard let baseAddress = bytes.baseAddress else { throw AudioEncodingError.missingMagicCookie }
      try check(
        AudioFileSetProperty(
          audioFile,
          kAudioFilePropertyMagicCookieData,
          UInt32(bytes.count),
          baseAddress),
        operation: "AudioFileSetProperty(kAudioFilePropertyMagicCookieData)")
    }

    var packetBytes = Data()
    var descriptions: [AudioStreamPacketDescription] = []
    descriptions.reserveCapacity(encoded.packets.count)
    for packet in encoded.packets {
      descriptions.append(
        AudioStreamPacketDescription(
          mStartOffset: Int64(packetBytes.count),
          mVariableFramesInPacket: 0,
          mDataByteSize: UInt32(packet.count)))
      packetBytes.append(packet)
    }

    guard encoded.packets.count <= Int(UInt32.max), packetBytes.count <= Int(UInt32.max) else {
      throw AudioEncodingError.inputTooLarge
    }
    var packetCount = UInt32(encoded.packets.count)
    let writeStatus = packetBytes.withUnsafeBytes { bytes in
      descriptions.withUnsafeBufferPointer { packetDescriptions in
        AudioFileWritePackets(
          audioFile,
          false,
          UInt32(bytes.count),
          packetDescriptions.baseAddress,
          0,
          &packetCount,
          bytes.baseAddress!)
      }
    }
    try check(writeStatus, operation: "AudioFileWritePackets")
    guard packetCount == UInt32(encoded.packets.count) else {
      throw AudioEncodingError.conversionFailed(
        "M4A writer accepted only \(packetCount) AAC packets")
    }

    var packetTable = AudioFilePacketTableInfo(
      mNumberValidFrames: validFrames,
      mPrimingFrames: Int32(encoded.leadingFrames),
      mRemainderFrames: Int32(encoded.trailingFrames))
    try check(
      AudioFileSetProperty(
        audioFile,
        kAudioFilePropertyPacketTableInfo,
        UInt32(MemoryLayout<AudioFilePacketTableInfo>.size),
        &packetTable),
      operation: "AudioFileSetProperty(kAudioFilePropertyPacketTableInfo)")

    try check(AudioFileClose(audioFile), operation: "AudioFileClose")
    isOpen = false
    return storage.snapshot()
  }

  private static func check(_ status: OSStatus, operation: String) throws {
    guard status == noErr else {
      throw AudioEncodingError.audioToolbox(operation: operation, status: status)
    }
  }
}

private final class MemoryAudioFileStorage: @unchecked Sendable {
  private let lock = NSLock()
  private var data = Data()

  func read(position: Int64, count: UInt32, into buffer: UnsafeMutableRawPointer) -> UInt32 {
    lock.lock()
    defer { lock.unlock() }
    guard position >= 0, position < Int64(data.count) else { return 0 }
    let start = Int(position)
    let byteCount = min(Int(count), data.count - start)
    data.copyBytes(
      to: buffer.assumingMemoryBound(to: UInt8.self), from: start..<(start + byteCount))
    return UInt32(byteCount)
  }

  func write(position: Int64, count: UInt32, from buffer: UnsafeRawPointer) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard position >= 0, position <= Int64(Int.max) - Int64(count) else { return false }
    let start = Int(position)
    let end = start + Int(count)
    if data.count < end { data.count = end }
    data.replaceSubrange(
      start..<end,
      with: UnsafeRawBufferPointer(start: buffer, count: Int(count)))
    return true
  }

  func size() -> Int64 {
    lock.lock()
    defer { lock.unlock() }
    return Int64(data.count)
  }

  func setSize(_ size: Int64) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard size >= 0, size <= Int64(Int.max) else { return false }
    data.count = Int(size)
    return true
  }

  func snapshot() -> Data {
    lock.lock()
    defer { lock.unlock() }
    return data
  }
}

nonisolated(unsafe) private let memoryAudioFileRead: AudioFile_ReadProc = {
  clientData, position, count, buffer, actualCount in
  let storage = Unmanaged<MemoryAudioFileStorage>.fromOpaque(clientData).takeUnretainedValue()
  actualCount.pointee = storage.read(position: position, count: count, into: buffer)
  return noErr
}

nonisolated(unsafe) private let memoryAudioFileWrite: AudioFile_WriteProc = {
  clientData, position, count, buffer, actualCount in
  let storage = Unmanaged<MemoryAudioFileStorage>.fromOpaque(clientData).takeUnretainedValue()
  guard storage.write(position: position, count: count, from: buffer) else {
    actualCount.pointee = 0
    return kAudioFilePositionError
  }
  actualCount.pointee = count
  return noErr
}

nonisolated(unsafe) private let memoryAudioFileGetSize: AudioFile_GetSizeProc = { clientData in
  let storage = Unmanaged<MemoryAudioFileStorage>.fromOpaque(clientData).takeUnretainedValue()
  return storage.size()
}

nonisolated(unsafe) private let memoryAudioFileSetSize: AudioFile_SetSizeProc = {
  clientData, size in
  let storage = Unmanaged<MemoryAudioFileStorage>.fromOpaque(clientData).takeUnretainedValue()
  return storage.setSize(size) ? noErr : kAudioFilePositionError
}

extension Data {
  fileprivate mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
    var littleEndian = value.littleEndian
    Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
  }
}

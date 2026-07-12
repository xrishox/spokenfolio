import AVFAudio
import AudioToolbox
import Foundation

enum M4AMuxer {
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

import AVFAudio
import Foundation

/// Streams one chapter's PCM through a single AVAudioConverter into an
/// `.aacseg` artifact. One converter per chapter keeps every chapter
/// independently encodable, which per-chapter resume requires; the ~44 ms
/// encoder priming this adds at each chapter join is masked by the head/tail
/// silence the pipeline inserts.
///
/// Confine an instance to one task; it is not thread-safe.
final class AACChapterEncoder: ChapterAudioEncoding {
  /// AudioSpecificConfig for AAC-LC, 48 kHz, mono: objectType 2,
  /// frequencyIndex 3, channelConfiguration 1.
  static let audioSpecificConfig = Data([0x11, 0x88])

  private let settings: AACEncodingSettings
  private let converter: AVAudioConverter
  private let inputFormat: AVAudioFormat
  private let writer: ChapterSegmentWriter
  private var pendingBuffer: AVAudioPCMBuffer?
  private var finished = false

  init(artifactURL: URL, settings: AACEncodingSettings, fingerprint: Data) throws {
    self.settings = settings

    guard
      let inputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: Double(settings.sampleRate),
        channels: AVAudioChannelCount(settings.channels),
        interleaved: true),
      let outputFormat = AVAudioFormat(settings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: settings.sampleRate,
        AVNumberOfChannelsKey: settings.channels,
      ]),
      let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
    else {
      throw AudiobookAudioError.encoderUnavailable
    }
    self.inputFormat = inputFormat

    if let applicable = converter.applicableEncodeBitRates?.map(\.intValue),
      !applicable.isEmpty, !applicable.contains(settings.bitRate)
    {
      throw AudiobookAudioError.bitRateNotSupported(
        requested: settings.bitRate, applicable: applicable.sorted())
    }
    converter.bitRate = settings.bitRate
    converter.bitRateStrategy = AVAudioBitRateStrategy_Constant
    converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
    self.converter = converter

    writer = try ChapterSegmentWriter(
      url: artifactURL, settings: settings, fingerprint: fingerprint)
  }

  func append(pcm16: Data) throws {
    precondition(!finished, "append after finish")
    guard !pcm16.isEmpty else { return }
    guard pcm16.count.isMultiple(of: MemoryLayout<Int16>.size) else {
      throw AudiobookAudioError.misalignedPCM
    }

    let frameCount = pcm16.count / MemoryLayout<Int16>.size
    guard
      let buffer = AVAudioPCMBuffer(
        pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(frameCount))
    else {
      throw AudiobookAudioError.converterFailed("buffer allocation failed")
    }
    buffer.frameLength = buffer.frameCapacity
    guard let destination = buffer.mutableAudioBufferList.pointee.mBuffers.mData else {
      throw AudiobookAudioError.converterFailed("buffer allocation failed")
    }
    pcm16.withUnsafeBytes { source in
      if let baseAddress = source.baseAddress {
        destination.copyMemory(from: baseAddress, byteCount: source.count)
      }
    }

    pendingBuffer = buffer
    try drain(end: false)
  }

  func finish() throws -> ChapterArtifact {
    precondition(!finished, "finish called twice")
    finished = true
    try drain(end: true)

    let primeInfo = converter.primeInfo
    let asc = Self.audioSpecificConfig
    // The converter's magic cookie embeds the AudioSpecificConfig in an ES
    // descriptor (tag 0x05). Cross-check our deterministic ASC against it so
    // an unexpected encoder configuration cannot produce an unplayable file.
    if let cookie = converter.magicCookie, !cookie.isEmpty, !containsASC(cookie, asc: asc) {
      writer.cancel()
      throw AudiobookAudioError.inconsistentAudioConfig
    }
    return try writer.finalize(
      leadingFrames: Int(primeInfo.leadingFrames),
      trailingFrames: Int(primeInfo.trailingFrames),
      audioSpecificConfig: asc)
  }

  func cancel() {
    finished = true
    writer.cancel()
  }

  private func drain(end: Bool) throws {
    let framesPending = pendingBuffer.map { Int($0.frameLength) } ?? 0
    let packetCapacity = AVAudioPacketCount(max(framesPending / 1024 + 2, 8))
    let input = PendingInput(buffer: pendingBuffer, end: end)
    pendingBuffer = nil

    // Bounded like the one-shot encoder's guard: the converter must make
    // progress every iteration or something is wrong.
    var idleIterations = 0
    while true {
      let outputBuffer = AVAudioCompressedBuffer(
        format: converter.outputFormat,
        packetCapacity: packetCapacity,
        maximumPacketSize: max(converter.maximumOutputPacketSize, 1))

      var conversionError: NSError?
      let status = converter.convert(to: outputBuffer, error: &conversionError) {
        _, inputStatus in
        input.next(status: inputStatus)
      }

      try writePackets(from: outputBuffer)

      switch status {
      case .haveData:
        idleIterations = outputBuffer.packetCount == 0 ? idleIterations + 1 : 0
      case .inputRanDry:
        if !end { return }
        idleIterations += 1
      case .endOfStream:
        return
      case .error:
        throw AudiobookAudioError.converterFailed(
          conversionError?.localizedDescription ?? "unknown AVAudioConverter error")
      @unknown default:
        throw AudiobookAudioError.converterFailed("unknown AVAudioConverter status")
      }
      if idleIterations > 4 {
        throw AudiobookAudioError.converterFailed("encoder made no progress")
      }
    }
  }

  private func writePackets(from buffer: AVAudioCompressedBuffer) throws {
    guard buffer.packetCount > 0 else { return }
    guard let descriptions = buffer.packetDescriptions else {
      throw AudiobookAudioError.converterFailed("encoder omitted packet descriptions")
    }
    for index in 0..<Int(buffer.packetCount) {
      let description = descriptions[index]
      let offset = Int(description.mStartOffset)
      let size = Int(description.mDataByteSize)
      guard offset >= 0, size > 0, offset + size <= Int(buffer.byteLength) else {
        throw AudiobookAudioError.converterFailed("encoder returned an invalid packet")
      }
      try writer.appendPacket(Data(bytes: buffer.data.advanced(by: offset), count: size))
    }
  }

  private func containsASC(_ cookie: Data, asc: Data) -> Bool {
    guard !asc.isEmpty, cookie.count >= asc.count else { return false }
    return cookie.range(of: asc) != nil
  }
}

/// Supplies the pending PCM buffer to the converter's synchronous input
/// callback exactly once, then reports dry/end.
private final class PendingInput: @unchecked Sendable {
  private let lock = NSLock()
  private var buffer: AVAudioPCMBuffer?
  private let end: Bool

  init(buffer: AVAudioPCMBuffer?, end: Bool) {
    self.buffer = buffer
    self.end = end
  }

  func next(status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
    lock.lock()
    defer { lock.unlock() }
    if let pending = buffer {
      buffer = nil
      status.pointee = .haveData
      return pending
    }
    status.pointee = end ? .endOfStream : .noDataNow
    return nil
  }
}

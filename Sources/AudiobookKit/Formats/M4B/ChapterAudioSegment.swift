import CryptoKit
import Foundation

/// The per-chapter artifact container (`.aacseg`) used for resume.
///
/// Layout (all integers little-endian):
/// - 32-byte header: "CASG", u32 version, codec fourcc, u32 sampleRate,
///   u32 bitRate, u32 framesPerPacket, u8 channels, 7 reserved bytes;
/// - packet stream: repeated (u32 size, packet bytes);
/// - trailer: "CASE", u64 packetCount, u64 payloadByteCount, u32 leading
///   frames, u32 trailingFrames, u8 ascLength + AudioSpecificConfig,
///   32-byte settings fingerprint, 32-byte SHA-256 checksum,
///   u32 trailerLength, "CASX".
///
/// The fixed 8-byte tail (trailerLength + "CASX") makes completeness
/// detectable from EOF; a crash leaves a `.partial` file that never passes
/// validation.
enum ChapterSegment {
  static let headerMagic = Data("CASG".utf8)
  static let trailerMagic = Data("CASE".utf8)
  static let endMagic = Data("CASX".utf8)
  static let version: UInt32 = 2
  static let codec = Data("aac ".utf8)
  static let headerLength = 32
  static let fingerprintLength = 32

  static func validate(
    url: URL, settings: AACEncodingSettings, fingerprint: Data
  ) throws -> M4BChapterArtifact {
    let data: Data
    do {
      data = try Data(contentsOf: url, options: .mappedIfSafe)
    } catch {
      throw AudiobookAudioError.artifactIO(url, error.localizedDescription)
    }
    guard data.count > headerLength + 8 else {
      throw AudiobookAudioError.artifactCorrupt(url, reason: "truncated")
    }

    var reader = SegmentReader(data: data)
    guard reader.read(4) == headerMagic, reader.readUInt32() == version,
      reader.read(4) == codec
    else {
      throw AudiobookAudioError.artifactCorrupt(url, reason: "unrecognized header")
    }
    let sampleRate = reader.readUInt32()
    let bitRate = reader.readUInt32()
    let framesPerPacket = reader.readUInt32()
    let channels = reader.readUInt8()
    guard sampleRate == UInt32(settings.sampleRate), bitRate == UInt32(settings.bitRate),
      channels == UInt8(settings.channels)
    else {
      throw AudiobookAudioError.artifactSettingsMismatch(url)
    }

    // Locate the trailer from the fixed tail.
    let tail = data.suffix(8)
    guard tail.suffix(4) == endMagic else {
      throw AudiobookAudioError.artifactCorrupt(url, reason: "missing end marker")
    }
    let trailerLength = Int(
      tail.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
    let trailerStart = data.count - trailerLength
    guard trailerLength >= 4 + 8 + 8 + 4 + 4 + 1 + fingerprintLength + 32 + 4 + 4,
      trailerStart > headerLength
    else {
      throw AudiobookAudioError.artifactCorrupt(url, reason: "invalid trailer length")
    }

    var trailer = SegmentReader(data: data, offset: trailerStart)
    guard trailer.read(4) == trailerMagic else {
      throw AudiobookAudioError.artifactCorrupt(url, reason: "missing trailer marker")
    }
    // Every numeric field is untrusted: convert with Int(exactly:) and
    // range-check before any arithmetic so corruption throws, never traps.
    let rawPacketCount = trailer.readUInt64()
    let rawPayloadByteCount = trailer.readUInt64()
    let leadingFrames = trailer.readUInt32()
    let trailingFrames = trailer.readUInt32()
    let ascLength = Int(trailer.readUInt8())
    let asc = trailer.read(ascLength)
    let storedFingerprint = trailer.read(fingerprintLength)
    let checksumEnd = trailer.offset
    let storedChecksum = trailer.read(32)
    guard trailer.ok else {
      throw AudiobookAudioError.artifactCorrupt(url, reason: "truncated trailer")
    }
    guard storedFingerprint == fingerprint.prefix(fingerprintLength) else {
      throw AudiobookAudioError.artifactSettingsMismatch(url)
    }
    guard asc == AACChapterEncoder.audioSpecificConfig else {
      throw AudiobookAudioError.artifactCorrupt(url, reason: "unexpected AAC configuration")
    }
    guard let payloadByteCount = Int(exactly: rawPayloadByteCount),
      payloadByteCount == trailerStart - headerLength
    else {
      throw AudiobookAudioError.artifactCorrupt(url, reason: "payload length mismatch")
    }
    guard let packetCount = Int(exactly: rawPacketCount), packetCount >= 1,
      packetCount <= payloadByteCount
    else {
      throw AudiobookAudioError.artifactCorrupt(url, reason: "implausible packet count")
    }
    guard framesPerPacket == 1024 else {
      throw AudiobookAudioError.artifactCorrupt(url, reason: "unexpected frames per packet")
    }
    let totalFrames = packetCount * 1024
    guard Int(leadingFrames) + Int(trailingFrames) < totalFrames else {
      throw AudiobookAudioError.artifactCorrupt(url, reason: "implausible priming frames")
    }

    // Authenticate the header, packet stream, timing, AAC configuration, and
    // settings fingerprint. The checksum itself and fixed EOF marker are the
    // only bytes outside the digest.
    guard Data(SHA256.hash(data: data[..<checksumEnd])) == storedChecksum else {
      throw AudiobookAudioError.artifactCorrupt(url, reason: "checksum mismatch")
    }
    var walker = SegmentReader(data: data, offset: headerLength)
    var walked: UInt64 = 0
    while walker.offset < trailerStart {
      let size = Int(walker.readUInt32())
      guard walker.ok, size > 0, walker.offset + size <= trailerStart else {
        throw AudiobookAudioError.artifactCorrupt(url, reason: "broken packet framing")
      }
      walker.skip(size)
      walked += 1
    }
    guard walked == UInt64(packetCount) else {
      throw AudiobookAudioError.artifactCorrupt(url, reason: "packet count mismatch")
    }

    return M4BChapterArtifact(
      url: url,
      packetCount: packetCount,
      framesPerPacket: Int(framesPerPacket),
      leadingFrames: Int(leadingFrames),
      trailingFrames: Int(trailingFrames),
      payloadByteCount: payloadByteCount,
      audioSpecificConfig: Data(asc))
  }

  /// Packet sizes from the framing alone (no payload copies); the assembler
  /// needs the full size table before writing anything.
  static func packetSizes(of artifact: M4BChapterArtifact) throws -> [UInt32] {
    var sizes: [UInt32] = []
    sizes.reserveCapacity(artifact.packetCount)
    let data: Data
    do {
      data = try Data(contentsOf: artifact.url, options: .mappedIfSafe)
    } catch {
      throw AudiobookAudioError.artifactIO(artifact.url, error.localizedDescription)
    }
    let end = headerLength + artifact.payloadByteCount
    guard end <= data.count else {
      throw AudiobookAudioError.artifactCorrupt(artifact.url, reason: "payload out of bounds")
    }
    var reader = SegmentReader(data: data, offset: headerLength)
    while reader.offset < end {
      let size = reader.readUInt32()
      guard reader.ok, size > 0, reader.offset + Int(size) <= end else {
        throw AudiobookAudioError.artifactCorrupt(artifact.url, reason: "broken packet framing")
      }
      sizes.append(size)
      reader.skip(Int(size))
    }
    return sizes
  }

  /// Iterate packets without loading them all; used by the assembler.
  static func forEachPacket(
    in artifact: M4BChapterArtifact, _ body: (Data) throws -> Void
  ) throws {
    let data: Data
    do {
      data = try Data(contentsOf: artifact.url, options: .mappedIfSafe)
    } catch {
      throw AudiobookAudioError.artifactIO(artifact.url, error.localizedDescription)
    }
    let end = headerLength + artifact.payloadByteCount
    guard end <= data.count else {
      throw AudiobookAudioError.artifactCorrupt(artifact.url, reason: "payload out of bounds")
    }
    var reader = SegmentReader(data: data, offset: headerLength)
    while reader.offset < end {
      let size = Int(reader.readUInt32())
      guard reader.ok, size > 0, reader.offset + size <= end else {
        throw AudiobookAudioError.artifactCorrupt(artifact.url, reason: "broken packet framing")
      }
      try body(data.subdata(in: reader.offset..<(reader.offset + size)))
      reader.skip(size)
    }
  }
}
/// Streams packets into a `.partial` segment file; `finalize` writes the
/// trailer, fsyncs, and renames so a complete artifact is atomic.
final class ChapterSegmentWriter {
  private let finalURL: URL
  private let partialURL: URL
  private let settings: AACEncodingSettings
  private let fingerprint: Data
  private var handle: FileHandle?
  private var checksum = SHA256()
  private var packetCount: UInt64 = 0
  private var payloadByteCount: UInt64 = 0

  init(url: URL, settings: AACEncodingSettings, fingerprint: Data) throws {
    precondition(
      fingerprint.count == ChapterSegment.fingerprintLength,
      "settings fingerprint must be a SHA-256 digest")
    finalURL = url
    partialURL = url.appendingPathExtension("partial")
    self.settings = settings
    self.fingerprint = fingerprint

    if FileManager.default.fileExists(atPath: partialURL.path) {
      try FileManager.default.removeItem(at: partialURL)
    }
    guard FileManager.default.createFile(atPath: partialURL.path, contents: nil) else {
      throw AudiobookAudioError.artifactIO(partialURL, "could not create partial artifact")
    }
    do {
      let handle = try FileHandle(forWritingTo: partialURL)
      var header = Data()
      header.append(ChapterSegment.headerMagic)
      header.appendLittleEndian(ChapterSegment.version)
      header.append(ChapterSegment.codec)
      header.appendLittleEndian(UInt32(settings.sampleRate))
      header.appendLittleEndian(UInt32(settings.bitRate))
      header.appendLittleEndian(UInt32(1024))
      header.append(UInt8(settings.channels))
      header.append(Data(count: 7))
      assert(header.count == ChapterSegment.headerLength)
      try handle.write(contentsOf: header)
      checksum.update(data: header)
      self.handle = handle
    } catch {
      throw AudiobookAudioError.artifactIO(partialURL, error.localizedDescription)
    }
  }

  func appendPacket(_ packet: Data) throws {
    guard let handle else { throw AudiobookAudioError.artifactIO(partialURL, "writer is closed") }
    var frame = Data(capacity: packet.count + 4)
    frame.appendLittleEndian(UInt32(packet.count))
    frame.append(packet)
    do {
      try handle.write(contentsOf: frame)
    } catch {
      throw AudiobookAudioError.artifactIO(partialURL, error.localizedDescription)
    }
    checksum.update(data: frame)
    packetCount += 1
    payloadByteCount += UInt64(frame.count)
  }

  func finalize(leadingFrames: Int, trailingFrames: Int, audioSpecificConfig: Data) throws
    -> M4BChapterArtifact
  {
    guard let handle else { throw AudiobookAudioError.artifactIO(partialURL, "writer is closed") }
    guard packetCount > 0 else {
      cancel()
      throw AudiobookAudioError.emptyChapter
    }

    var trailer = Data()
    trailer.append(ChapterSegment.trailerMagic)
    trailer.appendLittleEndian(packetCount)
    trailer.appendLittleEndian(payloadByteCount)
    trailer.appendLittleEndian(UInt32(leadingFrames))
    trailer.appendLittleEndian(UInt32(trailingFrames))
    trailer.append(UInt8(audioSpecificConfig.count))
    trailer.append(audioSpecificConfig)
    trailer.append(fingerprint.prefix(ChapterSegment.fingerprintLength))
    var completedChecksum = checksum
    completedChecksum.update(data: trailer)
    trailer.append(Data(completedChecksum.finalize()))
    trailer.appendLittleEndian(UInt32(trailer.count + 8))
    trailer.append(ChapterSegment.endMagic)

    do {
      try handle.write(contentsOf: trailer)
      try handle.synchronize()
      try handle.close()
      self.handle = nil
      try DurableFileCommit.replace(finalURL, with: partialURL)
    } catch {
      cancel()
      throw AudiobookAudioError.artifactIO(finalURL, error.localizedDescription)
    }

    return M4BChapterArtifact(
      url: finalURL,
      packetCount: Int(packetCount),
      framesPerPacket: 1024,
      leadingFrames: leadingFrames,
      trailingFrames: trailingFrames,
      payloadByteCount: Int(payloadByteCount),
      audioSpecificConfig: audioSpecificConfig)
  }

  func cancel() {
    try? handle?.close()
    handle = nil
    try? FileManager.default.removeItem(at: partialURL)
  }
}

// MARK: - Byte helpers

private struct SegmentReader {
  let data: Data
  var offset: Int
  var ok = true

  init(data: Data, offset: Int = 0) {
    self.data = data
    self.offset = data.startIndex + offset
  }

  mutating func read(_ count: Int) -> Data {
    guard count >= 0, offset + count <= data.endIndex else {
      ok = false
      return Data()
    }
    defer { offset += count }
    return data.subdata(in: offset..<(offset + count))
  }

  mutating func skip(_ count: Int) {
    offset += count
  }

  mutating func readUInt8() -> UInt8 {
    let bytes = read(1)
    guard let byte = bytes.first else { return 0 }
    return byte
  }

  mutating func readUInt32() -> UInt32 {
    let bytes = read(4)
    guard bytes.count == 4 else { return 0 }
    return bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
  }

  mutating func readUInt64() -> UInt64 {
    let bytes = read(8)
    guard bytes.count == 8 else { return 0 }
    return bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.littleEndian
  }
}

extension Data {
  mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
    var littleEndian = value.littleEndian
    Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
  }
}

import Foundation

enum OggOpusMuxer {
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

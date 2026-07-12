import Foundation

/// Minimal ISO-BMFF walker for the atoms AVFoundation does not expose
/// (stik, pgap, chpl); used by `audiobook verify` and the round-trip tests.
package enum MP4BoxReader {
  package struct Box {
    package let type: String
    package let payload: Data
  }

  package static func topLevelBoxes(in data: Data) -> [Box] {
    boxes(in: data, range: data.startIndex..<data.endIndex)
  }

  package static func children(of box: Box) -> [Box] {
    boxes(in: box.payload, range: box.payload.startIndex..<box.payload.endIndex)
  }

  /// Follow a path like ["moov", "udta", "chpl"]; `meta` is a FullBox whose
  /// children start after its 4 version/flags bytes.
  package static func box(at path: [String], in data: Data) -> Box? {
    var current = topLevelBoxes(in: data)
    var found: Box?
    for component in path {
      guard let next = current.first(where: { $0.type == component }) else { return nil }
      found = next
      var payload = next.payload
      if component == "meta" { payload = payload.dropFirst(4) }
      current = boxes(in: payload, range: payload.startIndex..<payload.endIndex)
    }
    return found
  }

  private static func boxes(in data: Data, range: Range<Data.Index>) -> [Box] {
    var result: [Box] = []
    var offset = range.lowerBound
    while offset + 8 <= range.upperBound {
      let size32 = UInt32(bigEndianData: data[offset..<(offset + 4)])
      let type = String(decoding: data[(offset + 4)..<(offset + 8)], as: ISOLatin1.self)
      var headerSize = 8
      // Sizes come from untrusted files (`audiobook verify` accepts any
      // path): oversized 64-bit values must fall out of the loop, not trap.
      var boxSize = Int(size32)
      if size32 == 1 {
        guard offset + 16 <= range.upperBound else { break }
        let large = UInt64(bigEndianData: data[(offset + 8)..<(offset + 16)])
        guard let converted = Int(exactly: large) else { break }
        boxSize = converted
        headerSize = 16
      } else if size32 == 0 {
        boxSize = range.upperBound - offset
      }
      guard boxSize >= headerSize else { break }
      let (end, overflow) = offset.addingReportingOverflow(boxSize)
      guard !overflow, end <= range.upperBound else { break }
      result.append(Box(type: type, payload: data.subdata(in: (offset + headerSize)..<end)))
      offset = end
    }
    return result
  }

  /// The payload of an ilst entry's nested 'data' atom (skipping its 8-byte
  /// type/locale prefix).
  package static func ilstValue(_ item: Box) -> Data? {
    guard let dataBox = children(of: item).first(where: { $0.type == "data" }),
      dataBox.payload.count >= 8
    else { return nil }
    return dataBox.payload.dropFirst(8)
  }
}

/// File-backed top-level scanner used by `audiobook verify`. It seeks over
/// `mdat` and reads only the requested bounded metadata payload.
package enum MP4FileReader {
  package static func payload(
    ofTopLevelBox wantedType: String, at url: URL, maximumBytes: Int = 256 * 1024 * 1024
  ) throws -> Data? {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard let number = attributes[.size] as? NSNumber else { return nil }
    let fileSize = number.uint64Value
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var offset: UInt64 = 0
    while offset + 8 <= fileSize {
      try handle.seek(toOffset: offset)
      guard let base = try handle.read(upToCount: 16), base.count >= 8 else { return nil }
      let size32 = UInt32(bigEndianData: base.prefix(4))
      let type = String(decoding: base[4..<8], as: ISOLatin1.self)
      var headerSize: UInt64 = 8
      let boxSize: UInt64
      if size32 == 1 {
        guard base.count >= 16 else { return nil }
        boxSize = UInt64(bigEndianData: base[8..<16])
        headerSize = 16
      } else if size32 == 0 {
        boxSize = fileSize - offset
      } else {
        boxSize = UInt64(size32)
      }
      guard boxSize >= headerSize, boxSize <= fileSize - offset else { return nil }
      if type == wantedType {
        let payloadSize = boxSize - headerSize
        guard payloadSize <= UInt64(maximumBytes), let count = Int(exactly: payloadSize) else {
          throw CocoaError(.fileReadTooLarge)
        }
        try handle.seek(toOffset: offset + headerSize)
        guard let payload = try handle.read(upToCount: count), payload.count == count else {
          throw CocoaError(.fileReadCorruptFile)
        }
        return payload
      }
      offset += boxSize
    }
    return nil
  }
}

private enum ISOLatin1: Unicode.Encoding {
  typealias CodeUnit = UInt8
  typealias EncodedScalar = CollectionOfOne<UInt8>

  static var encodedReplacementCharacter: EncodedScalar { CollectionOfOne(0x3F) }

  static func decode(_ content: EncodedScalar) -> Unicode.Scalar {
    Unicode.Scalar(content.first!)
  }

  static func encode(_ content: Unicode.Scalar) -> EncodedScalar? {
    content.value < 0x100 ? CollectionOfOne(UInt8(content.value)) : nil
  }

  struct Parser: Unicode.Parser {
    typealias Encoding = ISOLatin1

    mutating func parseScalar<I: IteratorProtocol>(
      from input: inout I
    ) -> Unicode.ParseResult<EncodedScalar> where I.Element == UInt8 {
      guard let byte = input.next() else { return .emptyInput }
      return .valid(CollectionOfOne(byte))
    }
  }

  typealias ForwardParser = Parser
  typealias ReverseParser = Parser
}

extension UInt32 {
  init(bigEndianData data: Data) {
    self = data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.bigEndian
  }
}

extension UInt64 {
  init(bigEndianData data: Data) {
    self = data.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.bigEndian
  }
}

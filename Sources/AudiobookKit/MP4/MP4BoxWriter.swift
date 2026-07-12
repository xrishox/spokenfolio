import Foundation

/// Big-endian ISO-BMFF (MP4/M4B) box-building primitives.
///
/// Everything here is pure `Data` construction; the assembler decides where the
/// bytes land on disk. Box sizes always use the compact 32-bit form — the only
/// box that can outgrow it is `mdat`, whose header is emitted separately by
/// `M4BOffsetPlan` in the 64-bit largesize form when needed.
enum MP4BoxWriter {
  /// Wraps a payload in a plain box header: u32 size + fourcc.
  static func box(_ type: String, _ payload: Data) -> Data {
    precondition(payload.count <= Int(UInt32.max) - 8, "Box payload exceeds the compact size form")
    var data = Data(capacity: payload.count + 8)
    data.appendU32(UInt32(payload.count + 8))
    data.appendFourCC(type)
    data.append(payload)
    return data
  }

  /// Wraps a payload in a full box header: u32 size + fourcc + u8 version + u24 flags.
  static func fullBox(_ type: String, version: UInt8, flags: UInt32, _ payload: Data) -> Data {
    var full = Data(capacity: payload.count + 4)
    full.appendU8(version)
    full.appendU24(flags)
    full.append(payload)
    return box(type, full)
  }
}

extension Data {
  mutating func appendU8(_ value: UInt8) {
    append(value)
  }

  mutating func appendU16(_ value: UInt16) {
    appendBigEndianBytes(value)
  }

  /// Appends the low 24 bits big-endian; the high byte must be zero.
  mutating func appendU24(_ value: UInt32) {
    precondition(value <= 0xFF_FFFF, "Value does not fit in 24 bits")
    append(UInt8((value >> 16) & 0xFF))
    append(UInt8((value >> 8) & 0xFF))
    append(UInt8(value & 0xFF))
  }

  mutating func appendU32(_ value: UInt32) {
    appendBigEndianBytes(value)
  }

  mutating func appendU64(_ value: UInt64) {
    appendBigEndianBytes(value)
  }

  /// Appends exactly four bytes. Encoded as ISO Latin-1 so iTunes atom names
  /// like `©nam` stay single-byte (0xA9), not two-byte UTF-8.
  mutating func appendFourCC(_ type: String) {
    guard let bytes = type.data(using: .isoLatin1), bytes.count == 4 else {
      preconditionFailure("Invalid fourcc: \(type)")
    }
    append(bytes)
  }

  /// Appends UTF-8 truncated at a character boundary and zero-padded to
  /// exactly `length` bytes.
  mutating func appendFixedString(_ value: String, length: Int) {
    let bytes = value.utf8Truncated(to: length)
    append(bytes)
    if bytes.count < length {
      append(Data(count: length - bytes.count))
    }
  }

  private mutating func appendBigEndianBytes<T: FixedWidthInteger>(_ value: T) {
    var bigEndian = value.bigEndian
    Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
  }
}

extension String {
  /// UTF-8 bytes truncated to at most `maxBytes` without splitting a Character,
  /// so length-capped fields (chpl titles, text samples) never emit broken UTF-8.
  func utf8Truncated(to maxBytes: Int) -> Data {
    if utf8.count <= maxBytes { return Data(utf8) }
    var end = startIndex
    var used = 0
    while end < endIndex {
      let next = index(after: end)
      let width = self[end..<next].utf8.count
      if used + width > maxBytes { break }
      used += width
      end = next
    }
    return Data(self[startIndex..<end].utf8)
  }
}

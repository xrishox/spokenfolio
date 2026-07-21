import Compression
import Foundation

/// Rewrites a parsed, bounds-validated archive with substituted payloads for
/// selected paths, preserving entry order. Untouched entries keep their
/// stored compressed bytes verbatim (no recompress), so rewriting a large
/// container costs I/O proportional to its size, not CPU. Replaced entries
/// are deflated when that helps and stored otherwise, except the EPUB
/// `mimetype` entry, which must stay stored.
///
/// The source archive has already passed `ZIPArchive`'s validation, which
/// rejects ZIP64, multi-disk, and encrypted archives, and caps entry count
/// and sizes — so the classic 32-bit record format written here is always
/// sufficient for what was read.
package enum ZIPArchiveRewriter {
  /// Writes `archive` to `destination` atomically, substituting the payload
  /// of every path in `replacements`. Throws if a replacement path does not
  /// exist in the archive (a silent no-op would hide a caller bug).
  package static func rewrite(
    _ archive: ZIPArchive, replacing replacements: [String: Data], to destination: URL
  ) throws {
    var remaining = Set(replacements.keys.map(\.precomposedStringWithCanonicalMapping))
    var output = Data()
    var directory = Data()
    var written: [(entry: ZIPEntry, offset: Int, method: UInt16, crc: UInt32,
      compressedSize: Int, uncompressedSize: Int)] = []

    for entry in archive.entries {
      let offset = output.count
      let payload: Data
      let method: UInt16
      let crc: UInt32
      let uncompressedSize: Int
      if let replacement = replacements[entry.path] {
        remaining.remove(entry.path.precomposedStringWithCanonicalMapping)
        crc = ZIPCRC32.checksum(replacement)
        uncompressedSize = replacement.count
        if entry.path == "mimetype" {
          payload = replacement
          method = 0
        } else if let deflated = deflate(replacement), deflated.count < replacement.count {
          payload = deflated
          method = 8
        } else {
          payload = replacement
          method = 0
        }
      } else {
        payload = try archive.rawPayload(for: entry)
        method = entry.compressionMethod
        crc = entry.crc32
        uncompressedSize = entry.uncompressedSize
      }
      appendLocalHeader(
        to: &output, path: entry.path, method: method, crc: crc,
        compressedSize: payload.count, uncompressedSize: uncompressedSize)
      output.append(payload)
      written.append((entry, offset, method, crc, payload.count, uncompressedSize))
    }
    guard remaining.isEmpty else {
      throw ZIPError.unreadableArchive(
        path: destination.path,
        reason: "replacement paths missing from archive: \(remaining.sorted().joined(separator: ", "))")
    }

    for record in written {
      appendCentralHeader(
        to: &directory, path: record.entry.path, method: record.method, crc: record.crc,
        compressedSize: record.compressedSize, uncompressedSize: record.uncompressedSize,
        localHeaderOffset: record.offset)
    }
    let directoryOffset = output.count
    output.append(directory)
    appendEndOfCentralDirectory(
      to: &output, entryCount: written.count, directorySize: directory.count,
      directoryOffset: directoryOffset)
    try output.write(to: destination, options: .atomic)
  }

  // MARK: - Record encoding

  private static func nameBytes(_ path: String) -> (bytes: [UInt8], utf8Flag: UInt16) {
    let bytes = Array(path.utf8)
    let ascii = bytes.allSatisfy { $0 < 0x80 }
    return (bytes, ascii ? 0 : 0x0800)
  }

  private static func appendLocalHeader(
    to output: inout Data, path: String, method: UInt16, crc: UInt32,
    compressedSize: Int, uncompressedSize: Int
  ) {
    let name = nameBytes(path)
    appendUInt32(&output, 0x0403_4B50)
    appendUInt16(&output, 20)  // version needed
    appendUInt16(&output, name.utf8Flag)
    appendUInt16(&output, method)
    appendUInt16(&output, 0)  // DOS time
    appendUInt16(&output, 0x21)  // DOS date: 1980-01-01
    appendUInt32(&output, crc)
    appendUInt32(&output, UInt32(compressedSize))
    appendUInt32(&output, UInt32(uncompressedSize))
    appendUInt16(&output, UInt16(name.bytes.count))
    appendUInt16(&output, 0)  // extra length
    output.append(contentsOf: name.bytes)
  }

  private static func appendCentralHeader(
    to output: inout Data, path: String, method: UInt16, crc: UInt32,
    compressedSize: Int, uncompressedSize: Int, localHeaderOffset: Int
  ) {
    let name = nameBytes(path)
    appendUInt32(&output, 0x0201_4B50)
    appendUInt16(&output, 20)  // version made by
    appendUInt16(&output, 20)  // version needed
    appendUInt16(&output, name.utf8Flag)
    appendUInt16(&output, method)
    appendUInt16(&output, 0)  // DOS time
    appendUInt16(&output, 0x21)  // DOS date
    appendUInt32(&output, crc)
    appendUInt32(&output, UInt32(compressedSize))
    appendUInt32(&output, UInt32(uncompressedSize))
    appendUInt16(&output, UInt16(name.bytes.count))
    appendUInt16(&output, 0)  // extra length
    appendUInt16(&output, 0)  // comment length
    appendUInt16(&output, 0)  // disk number
    appendUInt16(&output, 0)  // internal attributes
    appendUInt32(&output, 0)  // external attributes
    appendUInt32(&output, UInt32(localHeaderOffset))
    output.append(contentsOf: name.bytes)
  }

  private static func appendEndOfCentralDirectory(
    to output: inout Data, entryCount: Int, directorySize: Int, directoryOffset: Int
  ) {
    appendUInt32(&output, 0x0605_4B50)
    appendUInt16(&output, 0)  // disk number
    appendUInt16(&output, 0)  // directory disk
    appendUInt16(&output, UInt16(entryCount))
    appendUInt16(&output, UInt16(entryCount))
    appendUInt32(&output, UInt32(directorySize))
    appendUInt32(&output, UInt32(directoryOffset))
    appendUInt16(&output, 0)  // comment length
  }

  private static func appendUInt16(_ output: inout Data, _ value: UInt16) {
    withUnsafeBytes(of: value.littleEndian) { output.append(contentsOf: $0) }
  }

  private static func appendUInt32(_ output: inout Data, _ value: UInt32) {
    withUnsafeBytes(of: value.littleEndian) { output.append(contentsOf: $0) }
  }

  /// Raw-deflate encode (Apple's ZLIB algorithm emits headerless DEFLATE,
  /// which is exactly ZIP method 8). Returns nil when encoding fails or
  /// yields no data; callers fall back to a stored entry.
  private static func deflate(_ data: Data) -> Data? {
    guard !data.isEmpty else { return nil }
    let capacity = data.count
    var destination = Data(count: capacity)
    let encoded = destination.withUnsafeMutableBytes { destinationBuffer in
      data.withUnsafeBytes { sourceBuffer in
        compression_encode_buffer(
          destinationBuffer.bindMemory(to: UInt8.self).baseAddress!, capacity,
          sourceBuffer.bindMemory(to: UInt8.self).baseAddress!, data.count,
          nil, COMPRESSION_ZLIB)
      }
    }
    guard encoded > 0 else { return nil }
    destination.removeSubrange(encoded..<destination.count)
    return destination
  }
}

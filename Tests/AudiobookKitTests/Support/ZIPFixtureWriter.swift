import Compression
import Foundation

/// Builds small in-memory ZIP archives for AudiobookKit tests.
///
/// Deliberately independent of the production reader (including its CRC-32)
/// so round-trip tests cross-check two implementations. Reusable beyond
/// ZIPReaderTests: an EPUB fixture builder can layer `addEntry` calls
/// (starting with a stored `mimetype`) on top of it.
///
/// The knobs below synthesize hostile or unusual archives; leave them at
/// their defaults for well-formed output.
struct ZIPFixtureWriter {
  /// Appended after the end-of-central-directory record.
  var archiveComment = Data()
  /// Writes data-descriptor-style entries: general-purpose flag bit 3 set,
  /// zeroed CRC/sizes in the local header, a trailing data descriptor after
  /// the payload, and real values only in the central directory.
  var useDataDescriptors = false
  /// Replaces the general-purpose flag on every entry (for example 0x0001
  /// to claim encryption).
  var generalPurposeFlagOverride: UInt16?
  /// Replaces every central-directory uncompressed size (for example to
  /// claim an entry larger than the reader's per-entry bound).
  var centralUncompressedSizeOverride: UInt32?
  /// Replaces every central-directory local-header offset (for example
  /// 0xFFFF_FFFF to plant a ZIP64 sentinel).
  var centralLocalHeaderOffsetOverride: UInt32?
  /// Replaces both entry-count fields in the end-of-central-directory
  /// record (for example to claim more entries than the reader allows).
  var entryCountOverride: UInt16?

  private struct PendingEntry {
    let pathBytes: Data
    let method: UInt16
    let crc32: UInt32
    let payload: Data
    let uncompressedSize: UInt32
  }

  private var pendingEntries: [PendingEntry] = []

  mutating func addEntry(path: String, data: Data, compress: Bool) {
    pendingEntries.append(
      PendingEntry(
        pathBytes: Data(path.utf8),
        method: compress ? 8 : 0,
        crc32: Self.crc32(data),
        payload: compress ? Self.deflate(data) : data,
        uncompressedSize: UInt32(data.count)))
  }

  func finish() -> Data {
    var archive = Data()
    var localHeaderOffsets: [UInt32] = []

    for entry in pendingEntries {
      localHeaderOffsets.append(UInt32(archive.count))
      archive.appendLE(UInt32(0x0403_4B50))  // local file header signature
      archive.appendLE(UInt16(20))  // version needed to extract
      archive.appendLE(flags)
      archive.appendLE(entry.method)
      archive.appendLE(UInt16(0))  // modification time
      archive.appendLE(UInt16(0))  // modification date
      if useDataDescriptors {
        archive.appendLE(UInt32(0))  // CRC-32 deferred to the descriptor
        archive.appendLE(UInt32(0))  // compressed size deferred
        archive.appendLE(UInt32(0))  // uncompressed size deferred
      } else {
        archive.appendLE(entry.crc32)
        archive.appendLE(UInt32(entry.payload.count))
        archive.appendLE(entry.uncompressedSize)
      }
      archive.appendLE(UInt16(entry.pathBytes.count))
      archive.appendLE(UInt16(0))  // extra field length
      archive.append(entry.pathBytes)
      archive.append(entry.payload)
      if useDataDescriptors {
        archive.appendLE(UInt32(0x0807_4B50))  // optional descriptor signature
        archive.appendLE(entry.crc32)
        archive.appendLE(UInt32(entry.payload.count))
        archive.appendLE(entry.uncompressedSize)
      }
    }

    let centralDirectoryOffset = UInt32(archive.count)
    for (index, entry) in pendingEntries.enumerated() {
      archive.appendLE(UInt32(0x0201_4B50))  // central directory header signature
      archive.appendLE(UInt16(20))  // version made by
      archive.appendLE(UInt16(20))  // version needed to extract
      archive.appendLE(flags)
      archive.appendLE(entry.method)
      archive.appendLE(UInt16(0))  // modification time
      archive.appendLE(UInt16(0))  // modification date
      archive.appendLE(entry.crc32)
      archive.appendLE(UInt32(entry.payload.count))
      archive.appendLE(centralUncompressedSizeOverride ?? entry.uncompressedSize)
      archive.appendLE(UInt16(entry.pathBytes.count))
      archive.appendLE(UInt16(0))  // extra field length
      archive.appendLE(UInt16(0))  // file comment length
      archive.appendLE(UInt16(0))  // disk number start
      archive.appendLE(UInt16(0))  // internal file attributes
      archive.appendLE(UInt32(0))  // external file attributes
      archive.appendLE(centralLocalHeaderOffsetOverride ?? localHeaderOffsets[index])
      archive.append(entry.pathBytes)
    }
    let centralDirectorySize = UInt32(archive.count) - centralDirectoryOffset

    let entryCount = entryCountOverride ?? UInt16(pendingEntries.count)
    archive.appendLE(UInt32(0x0605_4B50))  // end of central directory signature
    archive.appendLE(UInt16(0))  // disk number
    archive.appendLE(UInt16(0))  // disk with the central directory
    archive.appendLE(entryCount)  // entries on this disk
    archive.appendLE(entryCount)  // total entries
    archive.appendLE(centralDirectorySize)
    archive.appendLE(centralDirectoryOffset)
    archive.appendLE(UInt16(archiveComment.count))
    archive.append(archiveComment)
    return archive
  }

  private var flags: UInt16 {
    if let generalPurposeFlagOverride { return generalPurposeFlagOverride }
    var flags: UInt16 = 0x0800  // bit 11: UTF-8 path
    if useDataDescriptors { flags |= 0x0008 }  // bit 3: data descriptor
    return flags
  }

  /// Raw RFC 1951 deflate, matching ZIP compression method 8.
  private static func deflate(_ data: Data) -> Data {
    guard !data.isEmpty else { return Data([0x03, 0x00]) }  // empty deflate stream
    let capacity = data.count + data.count / 2 + 64
    var output = Data(count: capacity)
    let written = output.withUnsafeMutableBytes { destination in
      data.withUnsafeBytes { source in
        compression_encode_buffer(
          destination.bindMemory(to: UInt8.self).baseAddress!,
          capacity,
          source.bindMemory(to: UInt8.self).baseAddress!,
          data.count,
          nil,
          COMPRESSION_ZLIB)
      }
    }
    precondition(written > 0, "compression_encode_buffer failed while building a fixture")
    output.removeSubrange(written..<capacity)
    return output
  }

  /// Bitwise CRC-32 (reflected polynomial 0xEDB88320), kept independent of
  /// the production table-driven implementation on purpose.
  private static func crc32(_ data: Data) -> UInt32 {
    var crc: UInt32 = ~0
    for byte in data {
      crc ^= UInt32(byte)
      for _ in 0..<8 {
        crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
      }
    }
    return ~crc
  }
}

extension Data {
  fileprivate mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
    var littleEndian = value.littleEndian
    Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
  }
}

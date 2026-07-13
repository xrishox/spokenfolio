import Compression
import Foundation

/// Minimal, auditable reader for the subset of ZIP that EPUB files use.
///
/// macOS has no public zip-reading API, so AudiobookKit owns this reader
/// instead of adding a dependency. The central directory is the single
/// source of truth for paths, sizes, checksums, and offsets; each local
/// header is consulted only to locate its payload, because entries written
/// with data descriptors store zeros in the local size fields.
///
/// The archive is untrusted input: every offset and length is validated
/// with overflow-checked arithmetic before it is used, entry counts and
/// decompressed sizes are capped before any allocation, and every payload
/// is verified against the central directory's CRC-32. ZIP64, multi-disk,
/// and encrypted archives are rejected outright.
struct ZIPArchive {
  /// Bounds applied before allocating or trusting archive metadata. Sized
  /// for real-world EPUBs with generous headroom.
  static let maxEntryCount = 10_000
  static let maxEntryUncompressedSize = 64 << 20  // 64 MiB
  static let maxTotalUncompressedSize = 1_280 << 20  // 1.25 GiB

  /// Entries in central-directory order.
  let entries: [ZIPEntry]

  private let data: Data
  private let firstEntryIndexByPath: [String: Int]

  init(url: URL) throws {
    let mapped: Data
    do {
      mapped = try Data(contentsOf: url, options: .mappedIfSafe)
    } catch {
      throw ZIPError.unreadableArchive(path: url.path, reason: error.localizedDescription)
    }
    try self.init(data: mapped)
  }

  /// In-memory entry point; `init(url:)` maps the file and lands here.
  init(data: Data) throws {
    self.data = data
    let parsed = try Self.parseCentralDirectory(in: data)
    self.entries = parsed.entries
    self.firstEntryIndexByPath = parsed.index
  }

  /// Returns the first central-directory entry whose stored path matches
  /// `path` exactly. No case folding, Unicode normalization, or leading
  /// slash trimming is applied.
  func entry(at path: String) -> ZIPEntry? {
    firstEntryIndexByPath[path].map { entries[$0] }
  }

  /// Returns the decompressed, CRC-verified contents of `entry`.
  func data(for entry: ZIPEntry) throws -> Data {
    // Entries normally come from parseCentralDirectory, but re-check the
    // limits here so a hand-built entry cannot bypass the allocation caps.
    guard entry.compressedSize >= 0, entry.uncompressedSize >= 0 else {
      throw ZIPError.malformedLocalHeader(path: entry.path)
    }
    guard entry.uncompressedSize <= Self.maxEntryUncompressedSize else {
      throw ZIPError.entryTooLarge(path: entry.path, uncompressedSize: entry.uncompressedSize)
    }

    let payload = try payloadRange(for: entry)
    let base = data.startIndex
    let compressed = data[(base + payload.lowerBound)..<(base + payload.upperBound)]

    let decompressed: Data
    switch entry.compressionMethod {
    case 0:  // stored
      guard entry.compressedSize == entry.uncompressedSize else {
        throw ZIPError.storedSizeMismatch(
          path: entry.path,
          compressedSize: entry.compressedSize,
          uncompressedSize: entry.uncompressedSize)
      }
      decompressed = Data(compressed)
    case 8:  // deflate
      decompressed = try Self.inflate(
        compressed, expectedSize: entry.uncompressedSize, path: entry.path)
    default:
      throw ZIPError.unsupportedCompressionMethod(
        path: entry.path, method: entry.compressionMethod)
    }

    guard ZIPCRC32.checksum(decompressed) == entry.crc32 else {
      throw ZIPError.checksumMismatch(path: entry.path)
    }
    return decompressed
  }

  // MARK: - Local header

  /// Parses the entry's local header just far enough to locate the payload.
  /// Only the local name and extra-field lengths are read; sizes come from
  /// the central directory because data-descriptor entries store zeros here.
  private func payloadRange(for entry: ZIPEntry) throws -> Range<Int> {
    let malformed = ZIPError.malformedLocalHeader(path: entry.path)
    guard entry.localHeaderOffset >= 0 else { throw malformed }
    let headerEnd = try Self.checkedAdd(
      entry.localHeaderOffset, ZIPLayout.localHeaderFixedSize, or: malformed)
    guard headerEnd <= data.count else {
      throw ZIPError.truncatedArchive(
        context: "local header for \"\(entry.path)\" lies outside the file")
    }
    guard data.zipLEUInt32(at: entry.localHeaderOffset) == ZIPLayout.localHeaderSignature else {
      throw malformed
    }

    let nameLength = Int(data.zipLEUInt16(at: entry.localHeaderOffset + 26))
    let extraLength = Int(data.zipLEUInt16(at: entry.localHeaderOffset + 28))
    var payloadStart = try Self.checkedAdd(headerEnd, nameLength, or: malformed)
    payloadStart = try Self.checkedAdd(payloadStart, extraLength, or: malformed)
    let payloadEnd = try Self.checkedAdd(payloadStart, entry.compressedSize, or: malformed)
    guard payloadEnd <= data.count else {
      throw ZIPError.truncatedArchive(
        context: "payload for \"\(entry.path)\" lies outside the file")
    }
    return payloadStart..<payloadEnd
  }

  // MARK: - Central directory

  private static func parseCentralDirectory(
    in data: Data
  ) throws -> (entries: [ZIPEntry], index: [String: Int]) {
    let eocdOffset = try locateEndOfCentralDirectory(in: data)

    // A ZIP64 end-of-central-directory locator directly precedes the EOCD
    // record when present.
    if eocdOffset >= ZIPLayout.zip64LocatorSize,
      data.zipLEUInt32(at: eocdOffset - ZIPLayout.zip64LocatorSize)
        == ZIPLayout.zip64LocatorSignature
    {
      throw ZIPError.zip64ArchiveUnsupported(
        context: "a ZIP64 end-of-central-directory locator is present")
    }

    let diskNumber = data.zipLEUInt16(at: eocdOffset + 4)
    let centralDirectoryDisk = data.zipLEUInt16(at: eocdOffset + 6)
    let entriesOnDisk = data.zipLEUInt16(at: eocdOffset + 8)
    let totalEntries = data.zipLEUInt16(at: eocdOffset + 10)
    let centralDirectorySize = data.zipLEUInt32(at: eocdOffset + 12)
    let centralDirectoryOffset = data.zipLEUInt32(at: eocdOffset + 16)

    if totalEntries == 0xFFFF || entriesOnDisk == 0xFFFF
      || centralDirectorySize == 0xFFFF_FFFF || centralDirectoryOffset == 0xFFFF_FFFF
    {
      throw ZIPError.zip64ArchiveUnsupported(
        context: "the end-of-central-directory record carries a ZIP64 sentinel")
    }
    guard diskNumber == 0, centralDirectoryDisk == 0, entriesOnDisk == totalEntries else {
      throw ZIPError.multiDiskArchiveUnsupported
    }

    let entryCount = Int(totalEntries)
    guard entryCount <= maxEntryCount else {
      throw ZIPError.tooManyEntries(count: entryCount)
    }

    let directoryStart = Int(centralDirectoryOffset)
    let directoryEnd = try checkedAdd(
      directoryStart, Int(centralDirectorySize),
      or: .malformedCentralDirectory(context: "directory size overflows"))
    guard directoryEnd <= eocdOffset else {
      throw ZIPError.malformedCentralDirectory(
        context: "directory extends past the end-of-central-directory record")
    }

    var entries: [ZIPEntry] = []
    entries.reserveCapacity(entryCount)  // bounded by maxEntryCount above
    var index: [String: Int] = [:]
    var totalUncompressedSize = 0
    var cursor = directoryStart

    for entryNumber in 0..<entryCount {
      let entryError: (String) -> ZIPError = {
        .malformedCentralDirectory(context: "entry \(entryNumber) \($0)")
      }
      let fixedEnd = try checkedAdd(
        cursor, ZIPLayout.centralHeaderFixedSize, or: entryError("header offset overflows"))
      guard fixedEnd <= directoryEnd else {
        throw ZIPError.truncatedArchive(
          context: "central directory ends inside entry \(entryNumber)")
      }
      guard data.zipLEUInt32(at: cursor) == ZIPLayout.centralHeaderSignature else {
        throw entryError("has an invalid header signature")
      }

      let flags = data.zipLEUInt16(at: cursor + 8)
      let method = data.zipLEUInt16(at: cursor + 10)
      let crc32 = data.zipLEUInt32(at: cursor + 16)
      let compressedSize = data.zipLEUInt32(at: cursor + 20)
      let uncompressedSize = data.zipLEUInt32(at: cursor + 24)
      let nameLength = Int(data.zipLEUInt16(at: cursor + 28))
      let extraLength = Int(data.zipLEUInt16(at: cursor + 30))
      let commentLength = Int(data.zipLEUInt16(at: cursor + 32))
      let diskNumberStart = data.zipLEUInt16(at: cursor + 34)
      let localHeaderOffset = data.zipLEUInt32(at: cursor + 42)

      let nameEnd = try checkedAdd(fixedEnd, nameLength, or: entryError("name length overflows"))
      var entryEnd = try checkedAdd(nameEnd, extraLength, or: entryError("extra length overflows"))
      entryEnd = try checkedAdd(
        entryEnd, commentLength, or: entryError("comment length overflows"))
      guard entryEnd <= directoryEnd else {
        throw ZIPError.truncatedArchive(
          context: "central directory ends inside entry \(entryNumber)")
      }

      let path = decodePath(data[(data.startIndex + fixedEnd)..<(data.startIndex + nameEnd)])

      guard flags & 0x0001 == 0 else {
        throw ZIPError.encryptedEntryUnsupported(path: path)
      }
      if compressedSize == 0xFFFF_FFFF || uncompressedSize == 0xFFFF_FFFF
        || localHeaderOffset == 0xFFFF_FFFF || diskNumberStart == 0xFFFF
      {
        throw ZIPError.zip64ArchiveUnsupported(
          context: "entry \"\(path)\" carries a ZIP64 size or offset sentinel")
      }
      guard diskNumberStart == 0 else { throw ZIPError.multiDiskArchiveUnsupported }

      guard Int(uncompressedSize) <= maxEntryUncompressedSize else {
        throw ZIPError.entryTooLarge(path: path, uncompressedSize: Int(uncompressedSize))
      }
      totalUncompressedSize = try checkedAdd(
        totalUncompressedSize, Int(uncompressedSize), or: entryError("total size overflows"))
      guard totalUncompressedSize <= maxTotalUncompressedSize else {
        throw ZIPError.archiveContentsTooLarge(totalUncompressedSize: totalUncompressedSize)
      }

      let entry = ZIPEntry(
        path: path,
        compressionMethod: method,
        compressedSize: Int(compressedSize),
        uncompressedSize: Int(uncompressedSize),
        crc32: crc32,
        localHeaderOffset: Int(localHeaderOffset))
      if index[path] == nil { index[path] = entries.count }
      entries.append(entry)
      cursor = entryEnd
    }

    return (entries, index)
  }

  /// Scans backward from EOF for the end-of-central-directory record within
  /// the last 22 + 65,535 bytes (the fixed record plus the largest possible
  /// archive comment). A candidate only counts when its own comment length
  /// reaches exactly to EOF, and the scan keeps going after a match: a
  /// spurious signature embedded in the archive comment always sits after
  /// the true record, so the last valid candidate found while scanning
  /// backward (the lowest offset) is the real one.
  private static func locateEndOfCentralDirectory(in data: Data) throws -> Int {
    guard data.count >= ZIPLayout.eocdFixedSize else {
      throw ZIPError.truncatedArchive(
        context: "the file is smaller than an end-of-central-directory record")
    }

    let highestCandidate = data.count - ZIPLayout.eocdFixedSize
    let lowestCandidate = max(0, highestCandidate - ZIPLayout.maxCommentLength)
    var lastValidCandidate: Int?
    var offset = highestCandidate
    while offset >= lowestCandidate {
      if data.zipLEUInt32(at: offset) == ZIPLayout.eocdSignature {
        let commentLength = Int(data.zipLEUInt16(at: offset + 20))
        if offset + ZIPLayout.eocdFixedSize + commentLength == data.count {
          lastValidCandidate = offset
        }
      }
      offset -= 1
    }

    guard let lastValidCandidate else { throw ZIPError.endOfCentralDirectoryNotFound }
    return lastValidCandidate
  }

  /// ZIP predates Unicode names; general-purpose flag bit 11 marks UTF-8.
  /// Every EPUB producer we care about writes UTF-8 whether or not it sets
  /// the flag, so decode UTF-8 first and fall back to Latin-1 (which cannot
  /// fail) so a legacy name never aborts parsing the whole archive.
  private static func decodePath(_ nameBytes: Data) -> String {
    String(data: nameBytes, encoding: .utf8)
      ?? String(data: nameBytes, encoding: .isoLatin1)
      ?? ""
  }

  // MARK: - Deflate

  private static func inflate(_ compressed: Data, expectedSize: Int, path: String) throws -> Data {
    guard expectedSize > 0 else { return Data() }
    guard !compressed.isEmpty else { throw ZIPError.decompressionFailed(path: path) }

    // expectedSize comes from the central directory and is already capped
    // at maxEntryUncompressedSize before this allocation.
    var output = Data(count: expectedSize)
    let decodedCount = output.withUnsafeMutableBytes { destination in
      compressed.withUnsafeBytes { source -> Int in
        guard let destinationBase = destination.baseAddress,
          let sourceBase = source.baseAddress
        else { return 0 }
        // Apple's COMPRESSION_ZLIB is raw RFC 1951 deflate — exactly the
        // payload format of ZIP compression method 8 (no zlib wrapper).
        return compression_decode_buffer(
          destinationBase.assumingMemoryBound(to: UInt8.self),
          destination.count,
          sourceBase.assumingMemoryBound(to: UInt8.self),
          source.count,
          nil,
          COMPRESSION_ZLIB)
      }
    }

    guard decodedCount == expectedSize else {
      if decodedCount == 0 { throw ZIPError.decompressionFailed(path: path) }
      throw ZIPError.decompressedSizeMismatch(
        path: path, expected: expectedSize, actual: decodedCount)
    }
    return output
  }

  // MARK: - Checked arithmetic

  private static func checkedAdd(
    _ lhs: Int, _ rhs: Int, or error: @autoclosure () -> ZIPError
  ) throws -> Int {
    let (sum, overflow) = lhs.addingReportingOverflow(rhs)
    guard !overflow else { throw error() }
    return sum
  }
}

/// One central-directory entry. All values are taken from the central
/// directory, never from the entry's local header.
struct ZIPEntry: Sendable {
  /// Path as stored in the archive, with forward slashes, decoded as UTF-8
  /// (general-purpose flag bit 11 or fallback).
  let path: String
  /// 0 = stored, 8 = deflate. Other methods are rejected on read.
  let compressionMethod: UInt16
  let compressedSize: Int
  let uncompressedSize: Int
  let crc32: UInt32
  let localHeaderOffset: Int
}

enum ZIPError: Error, LocalizedError {
  case unreadableArchive(path: String, reason: String)
  case truncatedArchive(context: String)
  case endOfCentralDirectoryNotFound
  case multiDiskArchiveUnsupported
  case zip64ArchiveUnsupported(context: String)
  case encryptedEntryUnsupported(path: String)
  case tooManyEntries(count: Int)
  case entryTooLarge(path: String, uncompressedSize: Int)
  case archiveContentsTooLarge(totalUncompressedSize: Int)
  case malformedCentralDirectory(context: String)
  case malformedLocalHeader(path: String)
  case unsupportedCompressionMethod(path: String, method: UInt16)
  case storedSizeMismatch(path: String, compressedSize: Int, uncompressedSize: Int)
  case decompressionFailed(path: String)
  case decompressedSizeMismatch(path: String, expected: Int, actual: Int)
  case checksumMismatch(path: String)

  var errorDescription: String? {
    switch self {
    case .unreadableArchive(let path, let reason):
      "Cannot read the archive at \(path): \(reason)"
    case .truncatedArchive(let context):
      "The ZIP archive is truncated or corrupt: \(context)."
    case .endOfCentralDirectoryNotFound:
      "No valid end-of-central-directory record was found; "
        + "the file is not a ZIP archive or its tail is missing."
    case .multiDiskArchiveUnsupported:
      "Multi-disk (spanned) ZIP archives are not supported; "
        + "re-create the archive as a single file."
    case .zip64ArchiveUnsupported(let context):
      "ZIP64 archives are not supported (\(context)); "
        + "re-create the archive in the classic 32-bit ZIP format."
    case .encryptedEntryUnsupported(let path):
      "Entry \"\(path)\" is encrypted; encrypted archives are not supported. "
        + "Re-create the archive without a password."
    case .tooManyEntries(let count):
      "The archive declares \(count) entries, above the limit of "
        + "\(ZIPArchive.maxEntryCount)."
    case .entryTooLarge(let path, let uncompressedSize):
      "Entry \"\(path)\" declares \(uncompressedSize) uncompressed bytes, above "
        + "the per-entry limit of \(ZIPArchive.maxEntryUncompressedSize)."
    case .archiveContentsTooLarge(let totalUncompressedSize):
      "The archive declares \(totalUncompressedSize) total uncompressed bytes, "
        + "above the limit of \(ZIPArchive.maxTotalUncompressedSize)."
    case .malformedCentralDirectory(let context):
      "The ZIP central directory is malformed: \(context)."
    case .malformedLocalHeader(let path):
      "The local header for entry \"\(path)\" is malformed."
    case .unsupportedCompressionMethod(let path, let method):
      "Entry \"\(path)\" uses unsupported compression method \(method); "
        + "only stored (0) and deflate (8) are supported."
    case .storedSizeMismatch(let path, let compressedSize, let uncompressedSize):
      "Stored entry \"\(path)\" declares \(compressedSize) compressed but "
        + "\(uncompressedSize) uncompressed bytes; a stored entry must declare equal sizes."
    case .decompressionFailed(let path):
      "Entry \"\(path)\" does not contain a valid deflate stream."
    case .decompressedSizeMismatch(let path, let expected, let actual):
      "Entry \"\(path)\" decompressed to \(actual) bytes but the central "
        + "directory declares \(expected)."
    case .checksumMismatch(let path):
      "Entry \"\(path)\" failed CRC-32 verification; the archive is corrupt."
    }
  }
}

/// Table-driven CRC-32 with the standard reflected polynomial 0xEDB88320,
/// the checksum ZIP stores for every entry. SiriTTSCore's bitwise `oggCRC`
/// is the table-free precedent; this one is table-driven for throughput on
/// multi-megabyte EPUB payloads.
enum ZIPCRC32 {
  private static let table: [UInt32] = {
    var table = [UInt32](repeating: 0, count: 256)
    for index in 0..<256 {
      var value = UInt32(index)
      for _ in 0..<8 {
        value = (value & 1) != 0 ? (value >> 1) ^ 0xEDB8_8320 : value >> 1
      }
      table[index] = value
    }
    return table
  }()

  static func checksum(_ data: Data) -> UInt32 {
    var crc: UInt32 = ~0
    data.withUnsafeBytes { buffer in
      for byte in buffer {
        crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
      }
    }
    return ~crc
  }
}

/// Signatures and fixed sizes from APPNOTE.TXT, the ZIP format specification.
private enum ZIPLayout {
  static let eocdSignature: UInt32 = 0x0605_4B50  // PK\x05\x06
  static let zip64LocatorSignature: UInt32 = 0x0706_4B50  // PK\x06\x07
  static let centralHeaderSignature: UInt32 = 0x0201_4B50  // PK\x01\x02
  static let localHeaderSignature: UInt32 = 0x0403_4B50  // PK\x03\x04

  static let eocdFixedSize = 22
  static let maxCommentLength = 65_535
  static let zip64LocatorSize = 20
  static let centralHeaderFixedSize = 46
  static let localHeaderFixedSize = 30
}

extension Data {
  /// Callers must bounds-check `offset + 2 <= count` first.
  fileprivate func zipLEUInt16(at offset: Int) -> UInt16 {
    let index = startIndex + offset
    return UInt16(self[index]) | UInt16(self[index + 1]) << 8
  }

  /// Callers must bounds-check `offset + 4 <= count` first.
  fileprivate func zipLEUInt32(at offset: Int) -> UInt32 {
    let index = startIndex + offset
    return UInt32(self[index]) | UInt32(self[index + 1]) << 8
      | UInt32(self[index + 2]) << 16 | UInt32(self[index + 3]) << 24
  }
}

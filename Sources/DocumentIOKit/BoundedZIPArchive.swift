import Compression
import Foundation

/// Minimal, auditable reader for the subset of ZIP used by publication containers.
///
/// macOS has no public zip-reading API, so DocumentIOKit owns this reader
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
package struct ZIPArchive: Sendable {
  package struct Limits: Sendable, Equatable {
    package var maximumEntryCount: Int
    package var maximumEntryUncompressedSize: Int
    package var maximumTotalUncompressedSize: Int
    package var maximumArchiveFileSize: Int

    package init(
      maximumEntryCount: Int, maximumEntryUncompressedSize: Int,
      maximumTotalUncompressedSize: Int, maximumArchiveFileSize: Int
    ) {
      self.maximumEntryCount = maximumEntryCount
      self.maximumEntryUncompressedSize = maximumEntryUncompressedSize
      self.maximumTotalUncompressedSize = maximumTotalUncompressedSize
      self.maximumArchiveFileSize = maximumArchiveFileSize
    }

    /// Ordinary publication parsing remains deliberately tighter than the
    /// opt-in ReadAloud profile.
    package static let publication = Limits(
      maximumEntryCount: 10_000,
      maximumEntryUncompressedSize: 64 << 20,
      maximumTotalUncompressedSize: 1_280 << 20,
      maximumArchiveFileSize: 1_536 << 20)

    /// ReadAloud EPUBs legitimately contain many hours of compressed audio.
    /// This profile changes only size budgets; path, CRC, encryption, ZIP64,
    /// and compression-method validation remain identical. A single-chapter
    /// book keeps its whole narration in one embedded track (synthesis runs
    /// forbid stalign's 120-minute re-chunking), so one entry can hold ~10
    /// hours of Opus — Huckleberry Finn's 9.5-hour single chapter measured
    /// 128.05 MiB, just over the previous 128 MiB entry cap.
    package static let readAloud = Limits(
      maximumEntryCount: 10_000,
      maximumEntryUncompressedSize: 512 << 20,
      maximumTotalUncompressedSize: 2_048 << 20,
      maximumArchiveFileSize: 2_048 << 20)
  }

  // Compatibility constants used by existing tests and diagnostics.
  package static let maxEntryCount = Limits.publication.maximumEntryCount
  package static let maxEntryUncompressedSize = Limits.publication.maximumEntryUncompressedSize
  package static let maxTotalUncompressedSize = Limits.publication.maximumTotalUncompressedSize
  package static let maxArchiveFileSize = Limits.publication.maximumArchiveFileSize

  /// Entries in central-directory order.
  package let entries: [ZIPEntry]

  private let data: Data
  private let limits: Limits
  private let firstEntryIndexByPath: [String: Int]

  package init(url: URL, limits: Limits = .publication) throws {
    let values: URLResourceValues
    do {
      values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    } catch {
      throw ZIPError.unreadableArchive(path: url.path, reason: error.localizedDescription)
    }
    guard values.isRegularFile == true, let size = values.fileSize,
      size <= limits.maximumArchiveFileSize
    else { throw ZIPError.archiveFileTooLarge(path: url.path) }
    let mapped: Data
    do {
      mapped = try Data(contentsOf: url, options: .mappedIfSafe)
    } catch {
      throw ZIPError.unreadableArchive(path: url.path, reason: error.localizedDescription)
    }
    try self.init(data: mapped, limits: limits)
  }

  /// In-memory entry point; `init(url:)` maps the file and lands here.
  package init(data: Data, limits: Limits = .publication) throws {
    guard data.count <= limits.maximumArchiveFileSize else {
      throw ZIPError.archiveFileTooLarge(path: "<memory>")
    }
    self.data = data
    self.limits = limits
    let parsed = try Self.parseCentralDirectory(in: data, limits: limits)
    self.entries = parsed.entries
    self.firstEntryIndexByPath = parsed.index
  }

  /// Returns the central-directory entry for a safe canonical path. Unicode
  /// normalization is applied consistently with central-directory indexing;
  /// case folding and path rewriting are not.
  package func entry(at path: String) -> ZIPEntry? {
    firstEntryIndexByPath[path.precomposedStringWithCanonicalMapping].map { entries[$0] }
  }

  /// Returns the decompressed, CRC-verified contents of `entry`.
  package func data(for entry: ZIPEntry) throws -> Data {
    // Entries normally come from parseCentralDirectory, but re-check the
    // limits here so a hand-built entry cannot bypass the allocation caps.
    guard entry.compressedSize >= 0, entry.uncompressedSize >= 0 else {
      throw ZIPError.malformedLocalHeader(path: entry.path)
    }
    guard entry.uncompressedSize <= limits.maximumEntryUncompressedSize else {
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

  /// Returns `entry`'s compressed payload bytes exactly as stored, for
  /// re-emitting an entry without a decompress/recompress round trip. The
  /// declared method/sizes/CRC still come from the central directory, and
  /// the payload span is bounds-checked like every read.
  package func rawPayload(for entry: ZIPEntry) throws -> Data {
    guard entry.compressedSize >= 0, entry.uncompressedSize >= 0,
      entry.uncompressedSize <= limits.maximumEntryUncompressedSize
    else {
      throw ZIPError.entryTooLarge(path: entry.path, uncompressedSize: entry.uncompressedSize)
    }
    let payload = try payloadRange(for: entry)
    let base = data.startIndex
    return Data(data[(base + payload.lowerBound)..<(base + payload.upperBound)])
  }

  /// Writes one entry through a bounded decoder and verifies its CRC before
  /// atomically exposing the destination. Peak decoded memory is one chunk,
  /// not the entry's declared uncompressed size.
  package func extract(_ entry: ZIPEntry, to destination: URL) throws {
    guard entry.compressedSize >= 0, entry.uncompressedSize >= 0,
      entry.uncompressedSize <= limits.maximumEntryUncompressedSize
    else {
      throw ZIPError.entryTooLarge(path: entry.path, uncompressedSize: entry.uncompressedSize)
    }

    let fm = FileManager.default
    try fm.createDirectory(
      at: destination.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let temporary = destination.deletingLastPathComponent().appendingPathComponent(
      ".\(destination.lastPathComponent).\(UUID().uuidString).partial")
    defer { try? fm.removeItem(at: temporary) }
    guard
      fm.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600])
    else {
      throw ZIPError.unreadableArchive(path: destination.path, reason: "cannot create output")
    }
    let handle = try FileHandle(forWritingTo: temporary)
    defer { try? handle.close() }

    let payload = try payloadRange(for: entry)
    let compressed = data[
      (data.startIndex + payload.lowerBound)..<(data.startIndex + payload.upperBound)]
    var checksum = ZIPCRC32.Accumulator()
    var written = 0

    func write(_ bytes: UnsafeRawBufferPointer) throws {
      guard !bytes.isEmpty else { return }
      let next = written.addingReportingOverflow(bytes.count)
      guard !next.overflow, next.partialValue <= entry.uncompressedSize else {
        throw ZIPError.decompressedSizeMismatch(
          path: entry.path, expected: entry.uncompressedSize, actual: next.partialValue)
      }
      let chunk = Data(bytes)
      checksum.update(chunk)
      try handle.write(contentsOf: chunk)
      written = next.partialValue
    }

    switch entry.compressionMethod {
    case 0:
      guard entry.compressedSize == entry.uncompressedSize else {
        throw ZIPError.storedSizeMismatch(
          path: entry.path, compressedSize: entry.compressedSize,
          uncompressedSize: entry.uncompressedSize)
      }
      try compressed.withUnsafeBytes { source in
        var offset = 0
        while offset < source.count {
          let count = min(1 << 20, source.count - offset)
          try write(UnsafeRawBufferPointer(rebasing: source[offset..<(offset + count)]))
          offset += count
        }
      }
    case 8:
      let initialDestination = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
      let initialSource = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
      defer {
        initialDestination.deallocate()
        initialSource.deallocate()
      }
      var stream = compression_stream(
        dst_ptr: initialDestination, dst_size: 0,
        src_ptr: UnsafePointer(initialSource), src_size: 0, state: nil)
      guard
        compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
          != COMPRESSION_STATUS_ERROR
      else { throw ZIPError.decompressionFailed(path: entry.path) }
      defer { compression_stream_destroy(&stream) }
      var output = [UInt8](repeating: 0, count: 1 << 20)
      try compressed.withUnsafeBytes { source in
        guard let sourceBase = source.bindMemory(to: UInt8.self).baseAddress else {
          if entry.compressedSize == 0 { return }
          throw ZIPError.decompressionFailed(path: entry.path)
        }
        stream.src_ptr = sourceBase
        stream.src_size = source.count
        var finished = false
        while !finished {
          let status: compression_status = output.withUnsafeMutableBytes { destination in
            stream.dst_ptr = destination.bindMemory(to: UInt8.self).baseAddress!
            stream.dst_size = destination.count
            return compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
          }
          let produced = output.count - stream.dst_size
          if produced > 0 {
            try output.withUnsafeBytes {
              try write(UnsafeRawBufferPointer(rebasing: $0[..<produced]))
            }
          }
          switch status {
          case COMPRESSION_STATUS_END: finished = true
          case COMPRESSION_STATUS_OK:
            guard produced > 0 || stream.src_size > 0 else {
              throw ZIPError.decompressionFailed(path: entry.path)
            }
          default: throw ZIPError.decompressionFailed(path: entry.path)
          }
        }
        guard stream.src_size == 0 else { throw ZIPError.decompressionFailed(path: entry.path) }
      }
    default:
      throw ZIPError.unsupportedCompressionMethod(path: entry.path, method: entry.compressionMethod)
    }

    guard written == entry.uncompressedSize else {
      throw ZIPError.decompressedSizeMismatch(
        path: entry.path, expected: entry.uncompressedSize, actual: written)
    }
    guard checksum.value == entry.crc32 else { throw ZIPError.checksumMismatch(path: entry.path) }
    try handle.synchronize()
    try handle.close()
    if fm.fileExists(atPath: destination.path) {
      _ = try fm.replaceItemAt(destination, withItemAt: temporary)
    } else {
      try fm.moveItem(at: temporary, to: destination)
    }
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
    in data: Data, limits: Limits
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
    guard entryCount <= limits.maximumEntryCount else {
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
      let normalizedPath = try validateArchivePath(path)

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

      guard Int(uncompressedSize) <= limits.maximumEntryUncompressedSize else {
        throw ZIPError.entryTooLarge(path: path, uncompressedSize: Int(uncompressedSize))
      }
      totalUncompressedSize = try checkedAdd(
        totalUncompressedSize, Int(uncompressedSize), or: entryError("total size overflows"))
      guard totalUncompressedSize <= limits.maximumTotalUncompressedSize else {
        throw ZIPError.archiveContentsTooLarge(totalUncompressedSize: totalUncompressedSize)
      }

      let entry = ZIPEntry(
        path: path,
        compressionMethod: method,
        compressedSize: Int(compressedSize),
        uncompressedSize: Int(uncompressedSize),
        crc32: crc32,
        localHeaderOffset: Int(localHeaderOffset))
      guard index[normalizedPath] == nil else { throw ZIPError.duplicateEntryPath(path: path) }
      index[normalizedPath] = entries.count
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

  /// Archive paths are URL-like, never filesystem paths. Canonical Unicode
  /// normalization prevents two entries from becoming the same path when an
  /// EPUB is later copied to a normal macOS filesystem.
  private static func validateArchivePath(_ path: String) throws -> String {
    guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"),
      !path.unicodeScalars.contains(where: {
        $0.value == 0 || CharacterSet.controlCharacters.contains($0)
      })
    else { throw ZIPError.unsafeEntryPath(path: path) }

    let normalized = path.precomposedStringWithCanonicalMapping
    var components = normalized.split(separator: "/", omittingEmptySubsequences: false)
    if normalized.hasSuffix("/") { components.removeLast() }
    guard !components.isEmpty,
      components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
      !(components.first?.contains(":") ?? false)
    else { throw ZIPError.unsafeEntryPath(path: path) }
    return normalized
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
package struct ZIPEntry: Sendable {
  /// Path as stored in the archive, with forward slashes, decoded as UTF-8
  /// (general-purpose flag bit 11 or fallback).
  package let path: String
  /// 0 = stored, 8 = deflate. Other methods are rejected on read.
  package let compressionMethod: UInt16
  package let compressedSize: Int
  package let uncompressedSize: Int
  package let crc32: UInt32
  package let localHeaderOffset: Int
}

package enum ZIPError: Error, LocalizedError {
  case unreadableArchive(path: String, reason: String)
  case archiveFileTooLarge(path: String)
  case truncatedArchive(context: String)
  case endOfCentralDirectoryNotFound
  case multiDiskArchiveUnsupported
  case zip64ArchiveUnsupported(context: String)
  case encryptedEntryUnsupported(path: String)
  case unsafeEntryPath(path: String)
  case duplicateEntryPath(path: String)
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

  package var errorDescription: String? {
    switch self {
    case .unreadableArchive(let path, let reason):
      "Cannot read the archive at \(path): \(reason)"
    case .archiveFileTooLarge(let path):
      "The archive at \(path) is not a regular file or exceeds the compressed-size limit of "
        + "\(ZIPArchive.maxArchiveFileSize) bytes."
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
    case .unsafeEntryPath(let path):
      "Entry \"\(path)\" has an unsafe or non-canonical archive path."
    case .duplicateEntryPath(let path):
      "The archive contains duplicate path \"\(path)\"."
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
package enum ZIPCRC32 {
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

  package static func checksum(_ data: Data) -> UInt32 {
    var accumulator = Accumulator()
    accumulator.update(data)
    return accumulator.value
  }

  package struct Accumulator {
    private var crc: UInt32 = ~0

    package init() {}

    package mutating func update(_ data: Data) {
      data.withUnsafeBytes { buffer in
        for byte in buffer {
          crc = ZIPCRC32.table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
      }
    }

    package var value: UInt32 { ~crc }
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

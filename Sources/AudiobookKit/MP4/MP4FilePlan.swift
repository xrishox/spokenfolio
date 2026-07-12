import Foundation

/// Declarative description of the single AAC audio track of one M4B file.
/// All timeline values derive from these integers (plan: cumulative packet
/// counts × frames per packet), so the chpl, chap, and stts chapter systems
/// can never disagree.
struct M4BAudioTrackPlan {
  var totalPackets: Int
  /// One entry per AAC packet, in file (chapter) order.
  var packetSizes: [UInt32]
  var framesPerPacket = 1024
  var sampleRate = 48_000
  var bitRate: Int
  var audioSpecificConfig: Data
  /// Encoder priming frames of chapter 0, trimmed by the movie edit list.
  var leadingFrames: Int
  /// Trailing pad frames of the final chapter.
  var trailingFrames: Int
  /// Packet count per chapter; audio chunks never span these boundaries.
  var chapterPacketCounts: [Int]

  var totalFrames: Int { totalPackets * framesPerPacket }

  /// Frames audible after the edit list trims the global lead and tail.
  var presentedFrames: Int { totalFrames - leadingFrames - trailingFrames }

  /// Media-timescale chapter starts: prefix sums of per-chapter frames.
  var chapterStartFrames: [Int] {
    var starts: [Int] = []
    starts.reserveCapacity(chapterPacketCounts.count)
    var start = 0
    for packets in chapterPacketCounts {
      starts.append(start)
      start += packets * framesPerPacket
    }
    return starts
  }

  /// Chapter starts on the post-edit-list timeline: max(0, start − leading).
  var presentedChapterStartFrames: [Int] {
    chapterStartFrames.map { max(0, $0 - leadingFrames) }
  }
}

/// One chapter mark: its title and the bytes of its text-track sample.
struct M4BChapterPlan {
  var title: String

  /// UTF-8 text-encoding marker box appended to every chapter title sample.
  /// Copied verbatim from ffmpeg movenc.c mov_create_chapter_track (identical
  /// in mp4v2); Apple Books expects it after the Pascal-style title.
  static let encdBox = Data([
    0x00, 0x00, 0x00, 0x0C,
    0x65, 0x6E, 0x63, 0x64,  // 'encd'
    0x00, 0x00, 0x01, 0x00,
  ])

  /// u16 BE title length + UTF-8 title (truncated at a character boundary to
  /// fit the length prefix) + the 'encd' marker.
  var samplePayload: Data {
    let titleBytes = title.utf8Truncated(to: Int(UInt16.max))
    var payload = Data(capacity: titleBytes.count + 14)
    payload.appendU16(UInt16(titleBytes.count))
    payload.append(titleBytes)
    payload.append(Self.encdBox)
    return payload
  }
}

/// iTunes-style book metadata destined for moov/udta/meta/ilst.
struct M4BMetadataPlan {
  enum CoverFormat {
    case jpeg
    case png
  }

  struct Cover {
    var data: Data
    var format: CoverFormat
  }

  var title: String
  var author: String? = nil
  var narrator: String? = nil
  var writer: String? = nil
  var genre: String? = nil
  var day: String? = nil
  var description: String? = nil
  var cover: Cover? = nil

  /// iTunes gapless-playback string: priming, trailing pad, and presented
  /// frame count in the standard fixed-width hex layout with eight reserved
  /// zero groups, as read by foobar2000/ffmpeg.
  static func iTunSMPB(leadingFrames: Int, trailingFrames: Int, presentedFrames: UInt64) -> String {
    String(
      format: " 00000000 %08X %08X %016llX"
        + " 00000000 00000000 00000000 00000000 00000000 00000000 00000000 00000000",
      UInt32(leadingFrames), UInt32(trailingFrames), presentedFrames)
  }
}

/// Byte layout of the file up to (and excluding) the trailing moov box.
/// Computed before any packet is written, so mdat needs no backpatching and
/// the stco-vs-co64 decision is made upfront.
struct M4BOffsetPlan {
  var ftypSize: Int
  var usesLargeMdat: Bool
  /// Text samples block + all audio packet bytes.
  var mdatPayloadSize: UInt64
  /// Absolute file offset of the first text sample: ftyp + mdat header.
  var textBlockOffset: UInt64
  /// Absolute file offset of each chapter's text sample.
  var textSampleOffsets: [UInt64]
  /// Absolute file offset of each audio chunk, in file order.
  var chunkOffsets: [UInt64]
  /// Packets in each chunk; runs of ≤ 50 that never span a chapter boundary.
  var chunkPacketCounts: [Int]
  var usesCO64: Bool
  var fileSizeExcludingMoov: UInt64

  var mdatHeaderSize: Int { usesLargeMdat ? 16 : 8 }

  /// mdat header bytes: compact u32 size, or size=1 + u64 largesize when the
  /// whole box (header included) would not fit a u32.
  var mdatHeader: Data {
    var header = Data(capacity: mdatHeaderSize)
    if usesLargeMdat {
      header.appendU32(1)
      header.appendFourCC("mdat")
      header.appendU64(16 + mdatPayloadSize)
    } else {
      header.appendU32(UInt32(8 + mdatPayloadSize))
      header.appendFourCC("mdat")
    }
    return header
  }
}

/// Pure integer layout planning: no I/O, no packet data — only sizes.
enum OffsetPlanner {
  /// Matches the Ogg page grouping precedent and bounds stsc entry count.
  static let packetsPerChunk = 50

  /// M4A-major ftyp with the M4B compatible brand, fixed for every file.
  static func ftyp() -> Data {
    var payload = Data()
    payload.appendFourCC("M4A ")
    payload.appendU32(0)  // minor version
    for brand in ["M4A ", "M4B ", "mp42", "isom"] {
      payload.appendFourCC(brand)
    }
    return MP4BoxWriter.box("ftyp", payload)
  }

  static func plan(audio: M4BAudioTrackPlan, chapters: [M4BChapterPlan]) -> M4BOffsetPlan {
    precondition(!chapters.isEmpty, "An audiobook needs at least one chapter")
    precondition(audio.packetSizes.count == audio.totalPackets, "Packet size table is incomplete")
    precondition(
      audio.chapterPacketCounts.count == chapters.count,
      "Chapter plans and packet counts must align")
    precondition(
      audio.chapterPacketCounts.allSatisfy { $0 > 0 },
      "Every chapter must contain audio packets")
    precondition(
      audio.chapterPacketCounts.reduce(0, +) == audio.totalPackets,
      "Chapter packet counts must sum to the packet total")

    let ftypSize = ftyp().count
    let textSampleSizes = chapters.map { $0.samplePayload.count }
    let textBlockSize = textSampleSizes.reduce(0, +)
    var audioBytes: UInt64 = 0
    for size in audio.packetSizes {
      audioBytes += UInt64(size)
    }

    let mdatPayloadSize = UInt64(textBlockSize) + audioBytes
    let usesLargeMdat = mdatPayloadSize + 8 > UInt64(UInt32.max)
    let mdatHeaderSize = usesLargeMdat ? 16 : 8
    let textBlockOffset = UInt64(ftypSize + mdatHeaderSize)

    var textSampleOffsets: [UInt64] = []
    textSampleOffsets.reserveCapacity(chapters.count)
    var position = textBlockOffset
    for size in textSampleSizes {
      textSampleOffsets.append(position)
      position += UInt64(size)
    }

    var chunkOffsets: [UInt64] = []
    var chunkPacketCounts: [Int] = []
    var packetIndex = 0
    for chapterPackets in audio.chapterPacketCounts {
      var remaining = chapterPackets
      while remaining > 0 {
        let run = min(remaining, packetsPerChunk)
        chunkOffsets.append(position)
        chunkPacketCounts.append(run)
        for _ in 0..<run {
          position += UInt64(audio.packetSizes[packetIndex])
          packetIndex += 1
        }
        remaining -= run
      }
    }

    return M4BOffsetPlan(
      ftypSize: ftypSize,
      usesLargeMdat: usesLargeMdat,
      mdatPayloadSize: mdatPayloadSize,
      textBlockOffset: textBlockOffset,
      textSampleOffsets: textSampleOffsets,
      chunkOffsets: chunkOffsets,
      chunkPacketCounts: chunkPacketCounts,
      // Offsets are monotonic, so the last chunk decides stco vs co64.
      usesCO64: (chunkOffsets.last ?? 0) > UInt64(UInt32.max),
      fileSizeExcludingMoov: UInt64(ftypSize + mdatHeaderSize) + mdatPayloadSize
    )
  }
}

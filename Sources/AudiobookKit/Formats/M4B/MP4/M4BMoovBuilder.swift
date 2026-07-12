import Foundation

/// Builds the complete trailing `moov` box for an M4B audiobook: movie header,
/// AAC audio track, Apple-style chapter text track, Nero chpl, and iTunes
/// metadata. Pure `Data` construction from the plans; the assembler writes it
/// after mdat.
enum M4BMoovBuilder {
  static let movieTimescale = 1000
  static let audioTrackID: UInt32 = 1
  static let chapterTrackID: UInt32 = 2

  // MARK: - Whole moov

  static func build(
    audio: M4BAudioTrackPlan,
    chapters: [M4BChapterPlan],
    metadata: M4BMetadataPlan,
    offsets: M4BOffsetPlan
  ) -> Data {
    precondition(!chapters.isEmpty, "An audiobook needs at least one chapter")
    precondition(chapters.count == audio.chapterPacketCounts.count, "Chapter plans must align")
    precondition(offsets.textSampleOffsets.count == chapters.count, "Offset plan is stale")
    precondition(offsets.chunkOffsets.count == offsets.chunkPacketCounts.count)

    let presentedMovieDuration = ceilingMovieDuration(
      frames: audio.presentedFrames, sampleRate: audio.sampleRate)

    var payload = mvhd(timescale: movieTimescale, duration: presentedMovieDuration, nextTrackID: 3)
    payload.append(
      audioTrak(audio: audio, offsets: offsets, presentedMovieDuration: presentedMovieDuration))
    payload.append(
      chapterTrak(
        audio: audio, chapters: chapters, offsets: offsets,
        presentedMovieDuration: presentedMovieDuration))
    payload.append(udta(audio: audio, chapters: chapters, metadata: metadata))
    return MP4BoxWriter.box("moov", payload)
  }

  // MARK: - Headers (auto version 1 when a duration overflows UInt32)

  static func mvhd(timescale: Int, duration: UInt64, nextTrackID: UInt32) -> Data {
    let version: UInt8 = duration > UInt64(UInt32.max) ? 1 : 0
    var payload = Data()
    if version == 1 {
      payload.appendU64(0)  // creation time
      payload.appendU64(0)  // modification time
      payload.appendU32(UInt32(timescale))
      payload.appendU64(duration)
    } else {
      payload.appendU32(0)
      payload.appendU32(0)
      payload.appendU32(UInt32(timescale))
      payload.appendU32(UInt32(duration))
    }
    payload.appendU32(0x0001_0000)  // rate 1.0
    payload.appendU16(0x0100)  // volume 1.0
    payload.appendU16(0)  // reserved
    payload.appendU32(0)
    payload.appendU32(0)
    appendIdentityMatrix(to: &payload)
    for _ in 0..<6 {
      payload.appendU32(0)  // pre_defined
    }
    payload.appendU32(nextTrackID)
    return MP4BoxWriter.fullBox("mvhd", version: version, flags: 0, payload)
  }

  static func tkhd(trackID: UInt32, flags: UInt32, duration: UInt64, volume: UInt16) -> Data {
    let version: UInt8 = duration > UInt64(UInt32.max) ? 1 : 0
    var payload = Data()
    if version == 1 {
      payload.appendU64(0)  // creation time
      payload.appendU64(0)  // modification time
      payload.appendU32(trackID)
      payload.appendU32(0)  // reserved
      payload.appendU64(duration)
    } else {
      payload.appendU32(0)
      payload.appendU32(0)
      payload.appendU32(trackID)
      payload.appendU32(0)
      payload.appendU32(UInt32(duration))
    }
    payload.appendU32(0)
    payload.appendU32(0)
    payload.appendU16(0)  // layer
    payload.appendU16(0)  // alternate group
    payload.appendU16(volume)
    payload.appendU16(0)  // reserved
    appendIdentityMatrix(to: &payload)
    payload.appendU32(0)  // width
    payload.appendU32(0)  // height
    return MP4BoxWriter.fullBox("tkhd", version: version, flags: flags, payload)
  }

  static func mdhd(timescale: Int, duration: UInt64) -> Data {
    let version: UInt8 = duration > UInt64(UInt32.max) ? 1 : 0
    var payload = Data()
    if version == 1 {
      payload.appendU64(0)
      payload.appendU64(0)
      payload.appendU32(UInt32(timescale))
      payload.appendU64(duration)
    } else {
      payload.appendU32(0)
      payload.appendU32(0)
      payload.appendU32(UInt32(timescale))
      payload.appendU32(UInt32(duration))
    }
    payload.appendU16(0x55C4)  // packed ISO-639-2 'und'
    payload.appendU16(0)  // pre_defined
    return MP4BoxWriter.fullBox("mdhd", version: version, flags: 0, payload)
  }

  /// Single-entry edit list: the gapless trim of the encoder's global
  /// priming (media_time) and trailing pad (segment duration stops early).
  static func elst(segmentDuration: UInt64, mediaTime: UInt32) -> Data {
    let version: UInt8 = segmentDuration > UInt64(UInt32.max) ? 1 : 0
    var payload = Data()
    payload.appendU32(1)  // entry count
    if version == 1 {
      payload.appendU64(segmentDuration)
      payload.appendU64(UInt64(mediaTime))
    } else {
      payload.appendU32(UInt32(segmentDuration))
      payload.appendU32(mediaTime)
    }
    payload.appendU32(0x0001_0000)  // media rate 1.0
    return MP4BoxWriter.fullBox("elst", version: version, flags: 0, payload)
  }

  static func hdlr(handlerType: String, name: String) -> Data {
    var payload = Data()
    payload.appendU32(0)  // pre_defined
    payload.appendFourCC(handlerType)
    payload.appendU32(0)
    payload.appendU32(0)
    payload.appendU32(0)
    payload.append(Data(name.utf8))
    payload.appendU8(0)  // MP4-style C-string terminator
    return MP4BoxWriter.fullBox("hdlr", version: 0, flags: 0, payload)
  }

  // MARK: - Sample tables

  static func stts(_ entries: [(count: Int, delta: Int)]) -> Data {
    var payload = Data()
    payload.appendU32(UInt32(entries.count))
    for entry in entries {
      payload.appendU32(UInt32(entry.count))
      payload.appendU32(UInt32(entry.delta))
    }
    return MP4BoxWriter.fullBox("stts", version: 0, flags: 0, payload)
  }

  /// Chunk map from per-chunk packet counts; consecutive equal counts merge
  /// into one entry. Chunk numbers are 1-based per ISO 14496-12.
  static func stsc(chunkPacketCounts: [Int]) -> Data {
    var entries: [(firstChunk: Int, samplesPerChunk: Int)] = []
    for (index, count) in chunkPacketCounts.enumerated()
    where entries.last?.samplesPerChunk != count {
      entries.append((firstChunk: index + 1, samplesPerChunk: count))
    }
    var payload = Data()
    payload.appendU32(UInt32(entries.count))
    for entry in entries {
      payload.appendU32(UInt32(entry.firstChunk))
      payload.appendU32(UInt32(entry.samplesPerChunk))
      payload.appendU32(1)  // sample description index
    }
    return MP4BoxWriter.fullBox("stsc", version: 0, flags: 0, payload)
  }

  static func stsz(sizes: [UInt32]) -> Data {
    var payload = Data(capacity: sizes.count * 4 + 8)
    payload.appendU32(0)  // sample_size 0: per-sample table follows
    payload.appendU32(UInt32(sizes.count))
    for size in sizes {
      payload.appendU32(size)
    }
    return MP4BoxWriter.fullBox("stsz", version: 0, flags: 0, payload)
  }

  static func chunkOffsetBox(_ offsets: [UInt64], useCO64: Bool) -> Data {
    var payload = Data(capacity: offsets.count * 8 + 4)
    payload.appendU32(UInt32(offsets.count))
    if useCO64 {
      for offset in offsets {
        payload.appendU64(offset)
      }
      return MP4BoxWriter.fullBox("co64", version: 0, flags: 0, payload)
    }
    for offset in offsets {
      precondition(offset <= UInt64(UInt32.max), "stco offset overflow; plan should choose co64")
      payload.appendU32(UInt32(offset))
    }
    return MP4BoxWriter.fullBox("stco", version: 0, flags: 0, payload)
  }

  /// Text-track sample durations at the media timescale (plan §5): each
  /// chapter runs to the next chapter's start; the last runs to the presented
  /// end. Consecutive equal durations merge.
  static func textSTTSEntries(audio: M4BAudioTrackPlan) -> [(count: Int, delta: Int)] {
    // The text track has no edit list, so its media timeline IS the movie
    // timeline: durations must come from the presented (post-elst) starts or
    // every mark after chapter 1 lands late by the trimmed priming.
    let presentedStarts = audio.presentedChapterStartFrames
    var entries: [(count: Int, delta: Int)] = []
    for index in presentedStarts.indices {
      let duration =
        index < presentedStarts.count - 1
        ? presentedStarts[index + 1] - presentedStarts[index]
        : audio.presentedFrames - presentedStarts[index]
      if let last = entries.last, last.delta == duration {
        entries[entries.count - 1].count += 1
      } else {
        entries.append((count: 1, delta: duration))
      }
    }
    return entries
  }

  // MARK: - Audio track

  static func esds(audioSpecificConfig: Data, bitRate: Int, channels: Int = 1) -> Data {
    var decoderConfig = Data()
    decoderConfig.appendU8(0x40)  // objectTypeIndication: MPEG-4 Audio
    decoderConfig.appendU8(0x15)  // streamType 5 (audio) << 2 | upStream 0 | reserved 1
    decoderConfig.appendU24(UInt32(6144 / 8 * channels))  // bufferSizeDB
    decoderConfig.appendU32(UInt32(bitRate))  // maxBitrate
    decoderConfig.appendU32(UInt32(bitRate))  // avgBitrate (CBR: equal)
    decoderConfig.append(descriptor(tag: 0x05, payload: audioSpecificConfig))

    var esDescriptor = Data()
    esDescriptor.appendU16(UInt16(audioTrackID))  // ES_ID
    esDescriptor.appendU8(0)  // no stream dependency, URL, or OCR
    esDescriptor.append(descriptor(tag: 0x04, payload: decoderConfig))
    esDescriptor.append(descriptor(tag: 0x06, payload: Data([0x02])))  // SLConfig: MP4 reserved

    return MP4BoxWriter.fullBox(
      "esds", version: 0, flags: 0, descriptor(tag: 0x03, payload: esDescriptor))
  }

  /// MPEG-4 descriptor: tag byte + expandable minimal-form length
  /// (ISO 14496-1 §8.3.3: 7 bits per byte, high bit marks continuation).
  private static func descriptor(tag: UInt8, payload: Data) -> Data {
    var data = Data()
    data.appendU8(tag)
    var remaining = payload.count >> 7
    var groups: [UInt8] = [UInt8(payload.count & 0x7F)]
    while remaining > 0 {
      groups.append(UInt8(remaining & 0x7F) | 0x80)
      remaining >>= 7
    }
    for group in groups.reversed() {
      data.appendU8(group)
    }
    data.append(payload)
    return data
  }

  static func mp4aSampleEntry(audio: M4BAudioTrackPlan) -> Data {
    precondition(audio.sampleRate <= Int(UInt16.max), "mp4a sample rate is 16.16 fixed point")
    var entry = Data()
    entry.append(Data(count: 6))  // reserved
    entry.appendU16(1)  // data reference index
    entry.append(Data(count: 8))  // version, revision, vendor
    entry.appendU16(1)  // channel count (mono contract)
    entry.appendU16(16)  // sample size
    entry.appendU32(0)  // pre_defined + reserved
    entry.appendU32(UInt32(audio.sampleRate) << 16)
    entry.append(esds(audioSpecificConfig: audio.audioSpecificConfig, bitRate: audio.bitRate))
    return MP4BoxWriter.box("mp4a", entry)
  }

  private static func audioTrak(
    audio: M4BAudioTrackPlan,
    offsets: M4BOffsetPlan,
    presentedMovieDuration: UInt64
  ) -> Data {
    var trak = tkhd(
      trackID: audioTrackID, flags: 0x3, duration: presentedMovieDuration, volume: 0x0100)
    trak.append(
      MP4BoxWriter.box(
        "edts",
        elst(segmentDuration: presentedMovieDuration, mediaTime: UInt32(audio.leadingFrames))))
    // Chapter-list reference from the enabled audio track to the text track,
    // per Apple QTFF "Chapter Lists".
    var chap = Data()
    chap.appendU32(chapterTrackID)
    trak.append(MP4BoxWriter.box("tref", MP4BoxWriter.box("chap", chap)))

    var stsdPayload = Data()
    stsdPayload.appendU32(1)
    stsdPayload.append(mp4aSampleEntry(audio: audio))
    var stbl = MP4BoxWriter.fullBox("stsd", version: 0, flags: 0, stsdPayload)
    stbl.append(stts([(count: audio.totalPackets, delta: audio.framesPerPacket)]))
    stbl.append(stsc(chunkPacketCounts: offsets.chunkPacketCounts))
    stbl.append(stsz(sizes: audio.packetSizes))
    stbl.append(chunkOffsetBox(offsets.chunkOffsets, useCO64: offsets.usesCO64))

    var minf = smhd
    minf.append(dinf)
    minf.append(MP4BoxWriter.box("stbl", stbl))

    var mdia = mdhd(timescale: audio.sampleRate, duration: UInt64(audio.totalFrames))
    mdia.append(hdlr(handlerType: "soun", name: "SoundHandler"))
    mdia.append(MP4BoxWriter.box("minf", minf))
    trak.append(MP4BoxWriter.box("mdia", mdia))
    return MP4BoxWriter.box("trak", trak)
  }

  static var smhd: Data {
    var payload = Data()
    payload.appendU16(0)  // balance
    payload.appendU16(0)  // reserved
    return MP4BoxWriter.fullBox("smhd", version: 0, flags: 0, payload)
  }

  static var dinf: Data {
    var drefPayload = Data()
    drefPayload.appendU32(1)  // entry count
    drefPayload.append(MP4BoxWriter.fullBox("url ", version: 0, flags: 1, Data()))  // self-contained
    return MP4BoxWriter.box(
      "dinf", MP4BoxWriter.fullBox("dref", version: 0, flags: 0, drefPayload))
  }

  // MARK: - Chapter text track

  /// Classic QuickTime TextSampleEntry (not tx3g): 6 reserved bytes and data
  /// reference index 1, then ffmpeg's stub_header from movenc.c
  /// mov_create_chapter_track verbatim — displayFlags 1, empty box and style
  /// records, and a one-entry ftab with font ID 1 and an empty name. This is
  /// the form Apple Books and QuickTime accept for chapter tracks.
  static let textSampleEntry: Data = {
    var entry = Data(count: 6)
    entry.appendU16(1)  // data reference index
    entry.append(
      Data([
        0x00, 0x00, 0x00, 0x01,  // displayFlags
        0x00, 0x00,  // horizontal + vertical justification
        0x00, 0x00, 0x00, 0x00,  // background colour
        0x00, 0x00, 0x00, 0x00,  // default text box top/left
        0x00, 0x00, 0x00, 0x00,  // default text box bottom/right
        0x00, 0x00, 0x00, 0x00,  // style: start + end char
        0x00, 0x01,  // style: font ID
        0x00, 0x00,  // style: face flags + size
        0x00, 0x00, 0x00, 0x00,  // style: foreground colour
        0x00, 0x00, 0x00, 0x0D,  // ftab box size
        0x66, 0x74, 0x61, 0x62,  // 'ftab'
        0x00, 0x01,  // font entry count
        0x00, 0x01,  // font ID
        0x00,  // font name length
      ]))
    return MP4BoxWriter.box("text", entry)
  }()

  /// gmin plus the undocumented 'text' media-information atom. ffmpeg's
  /// movenc.c mov_write_gmhd_tag copies those bytes verbatim and marks them
  /// "required for Apple Quicktime chapters"; reproduced here exactly.
  static let gmhd: Data = {
    var gmin = Data()
    gmin.appendU32(0)  // version + flags
    gmin.appendU16(0x40)  // graphics mode
    gmin.appendU16(0x8000)  // opColor red
    gmin.appendU16(0x8000)  // opColor green
    gmin.appendU16(0x8000)  // opColor blue
    gmin.appendU16(0)  // balance
    gmin.appendU16(0)  // reserved

    var text = Data()
    text.appendU16(0x01)
    text.appendU32(0)
    text.appendU32(0)
    text.appendU32(0)
    text.appendU32(0x01)
    text.appendU32(0)
    text.appendU32(0)
    text.appendU32(0)
    text.appendU32(0x0000_4000)
    text.appendU16(0)

    var payload = MP4BoxWriter.box("gmin", gmin)
    payload.append(MP4BoxWriter.box("text", text))
    return MP4BoxWriter.box("gmhd", payload)
  }()

  private static func chapterTrak(
    audio: M4BAudioTrackPlan,
    chapters: [M4BChapterPlan],
    offsets: M4BOffsetPlan,
    presentedMovieDuration: UInt64
  ) -> Data {
    // Flags 0x2: in-movie but disabled — Apple requires the chapter list
    // track not be enabled for normal playback.
    var trak = tkhd(
      trackID: chapterTrackID, flags: 0x2, duration: presentedMovieDuration, volume: 0)

    var stsdPayload = Data()
    stsdPayload.appendU32(1)
    stsdPayload.append(textSampleEntry)
    var stbl = MP4BoxWriter.fullBox("stsd", version: 0, flags: 0, stsdPayload)
    stbl.append(stts(textSTTSEntries(audio: audio)))
    stbl.append(stsc(chunkPacketCounts: [chapters.count]))  // all samples in one chunk
    stbl.append(stsz(sizes: chapters.map { UInt32($0.samplePayload.count) }))
    stbl.append(chunkOffsetBox([offsets.textBlockOffset], useCO64: false))

    var minf = gmhd
    minf.append(dinf)
    minf.append(MP4BoxWriter.box("stbl", stbl))

    var mdia = mdhd(timescale: audio.sampleRate, duration: UInt64(audio.presentedFrames))
    mdia.append(hdlr(handlerType: "text", name: "ChapterHandler"))
    mdia.append(MP4BoxWriter.box("minf", minf))
    trak.append(MP4BoxWriter.box("mdia", mdia))
    return MP4BoxWriter.box("trak", trak)
  }

  // MARK: - udta: chpl + iTunes metadata

  /// Nero chapter list in ffmpeg's v1 layout (verified against movenc.c
  /// mov_write_chpl_tag): version 1, u32 reserved, u8 entry count capped at
  /// 255, then per chapter a u64 start in 100 ns units on the post-edit-list
  /// timeline and a Pascal-style UTF-8 title. Chapters beyond 255 are still
  /// carried by the chap text track.
  static func chpl(audio: M4BAudioTrackPlan, chapters: [M4BChapterPlan]) -> Data {
    let presentedStarts = audio.presentedChapterStartFrames
    let count = min(chapters.count, 255)
    var payload = Data()
    payload.appendU32(0)  // reserved
    payload.appendU8(UInt8(count))
    for index in 0..<count {
      payload.appendU64(UInt64(presentedStarts[index]) * 10_000_000 / UInt64(audio.sampleRate))
      let titleBytes = chapters[index].title.utf8Truncated(to: 255)
      payload.appendU8(UInt8(titleBytes.count))
      payload.append(titleBytes)
    }
    return MP4BoxWriter.fullBox("chpl", version: 1, flags: 0, payload)
  }

  /// ffmpeg's fixed 33-byte iTunes metadata handler (mov_write_itunes_hdlr_tag):
  /// subtype 'mdir', manufacturer 'appl', single NUL name byte.
  static let itunesHdlr: Data = {
    var payload = Data()
    payload.appendU32(0)  // pre_defined
    payload.appendFourCC("mdir")
    payload.appendFourCC("appl")
    payload.appendU32(0)
    payload.appendU32(0)
    payload.appendU8(0)
    return MP4BoxWriter.fullBox("hdlr", version: 0, flags: 0, payload)
  }()

  static func ilstStringItem(code: String, value: String) -> Data {
    MP4BoxWriter.box(code, dataAtom(typeCode: 1, payload: Data(value.utf8)))
  }

  static func ilstInt8Item(code: String, value: UInt8) -> Data {
    MP4BoxWriter.box(code, dataAtom(typeCode: 21, payload: Data([value])))
  }

  static func ilstCoverItem(_ cover: M4BMetadataPlan.Cover) -> Data {
    let typeCode: UInt32 = cover.format == .jpeg ? 13 : 14
    return MP4BoxWriter.box("covr", dataAtom(typeCode: typeCode, payload: cover.data))
  }

  /// Reverse-DNS atom in ffmpeg's layout (mov_write_freeform_tag): 'mean' and
  /// 'name' boxes each carry four zero flag bytes before their string.
  static func ilstFreeformItem(mean: String, name: String, value: String) -> Data {
    var meanPayload = Data()
    meanPayload.appendU32(0)
    meanPayload.append(Data(mean.utf8))
    var namePayload = Data()
    namePayload.appendU32(0)
    namePayload.append(Data(name.utf8))
    var payload = MP4BoxWriter.box("mean", meanPayload)
    payload.append(MP4BoxWriter.box("name", namePayload))
    payload.append(dataAtom(typeCode: 1, payload: Data(value.utf8)))
    return MP4BoxWriter.box("----", payload)
  }

  private static func udta(
    audio: M4BAudioTrackPlan,
    chapters: [M4BChapterPlan],
    metadata: M4BMetadataPlan
  ) -> Data {
    var metaPayload = itunesHdlr
    metaPayload.append(ilst(audio: audio, metadata: metadata))
    var payload = chpl(audio: audio, chapters: chapters)
    payload.append(MP4BoxWriter.fullBox("meta", version: 0, flags: 0, metaPayload))
    return MP4BoxWriter.box("udta", payload)
  }

  private static func ilst(audio: M4BAudioTrackPlan, metadata: M4BMetadataPlan) -> Data {
    var payload = ilstStringItem(code: "©nam", value: metadata.title)
    if let author = metadata.author {
      payload.append(ilstStringItem(code: "©alb", value: author))
    }
    if let narrator = metadata.narrator {
      payload.append(ilstStringItem(code: "©ART", value: narrator))
    }
    if let writer = metadata.writer {
      payload.append(ilstStringItem(code: "©wrt", value: writer))
    }
    if let genre = metadata.genre {
      payload.append(ilstStringItem(code: "©gen", value: genre))
    }
    if let day = metadata.day {
      payload.append(ilstStringItem(code: "©day", value: day))
    }
    if let description = metadata.description {
      payload.append(ilstStringItem(code: "desc", value: description))
    }
    payload.append(ilstInt8Item(code: "stik", value: 2))  // media kind: audiobook
    payload.append(ilstInt8Item(code: "pgap", value: 1))  // gapless
    if let cover = metadata.cover {
      payload.append(ilstCoverItem(cover))
    }
    payload.append(
      ilstFreeformItem(
        mean: "com.apple.iTunes",
        name: "iTunSMPB",
        value: M4BMetadataPlan.iTunSMPB(
          leadingFrames: audio.leadingFrames,
          trailingFrames: audio.trailingFrames,
          presentedFrames: UInt64(audio.presentedFrames))))
    return MP4BoxWriter.box("ilst", payload)
  }

  // MARK: - Shared pieces

  private static func dataAtom(typeCode: UInt32, payload: Data) -> Data {
    var data = Data()
    data.appendU32(typeCode)
    data.appendU32(0)  // locale
    data.append(payload)
    return MP4BoxWriter.box("data", data)
  }

  /// Movie-timescale durations round up so no track outlives the movie.
  private static func ceilingMovieDuration(frames: Int, sampleRate: Int) -> UInt64 {
    UInt64((frames * movieTimescale + sampleRate - 1) / sampleRate)
  }

  private static func appendIdentityMatrix(to data: inout Data) {
    let matrix: [UInt32] = [
      0x0001_0000, 0, 0,
      0, 0x0001_0000, 0,
      0, 0, 0x4000_0000,
    ]
    for value in matrix {
      data.appendU32(value)
    }
  }
}

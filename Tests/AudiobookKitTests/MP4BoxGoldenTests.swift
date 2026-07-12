import XCTest

@testable import AudiobookKit

/// Golden-byte tests: every expected array is hand-computed from the ISO
/// 14496-12 field layout and the ffmpeg movenc.c verbatim structures.
final class MP4BoxGoldenTests: XCTestCase {

  // MARK: - Primitives

  func testBoxAndFullBoxHeaders() {
    XCTAssertEqual(
      Array(MP4BoxWriter.box("free", Data([0xAB, 0xCD]))),
      [0x00, 0x00, 0x00, 0x0A, 0x66, 0x72, 0x65, 0x65, 0xAB, 0xCD])
    XCTAssertEqual(
      Array(MP4BoxWriter.fullBox("test", version: 2, flags: 0x000102, Data([0xFF]))),
      [0x00, 0x00, 0x00, 0x0D, 0x74, 0x65, 0x73, 0x74, 0x02, 0x00, 0x01, 0x02, 0xFF])
  }

  func testBigEndianPrimitives() {
    var data = Data()
    data.appendU8(0x7F)
    data.appendU16(0x0102)
    data.appendU24(0x030405)
    data.appendU32(0x0607_0809)
    data.appendU64(0x0A0B_0C0D_0E0F_1011)
    data.appendFourCC("©nam")  // must stay single-byte Latin-1, not UTF-8
    data.appendFixedString("Hi", length: 4)
    data.appendFixedString("Hello", length: 4)
    XCTAssertEqual(
      Array(data),
      [
        0x7F,
        0x01, 0x02,
        0x03, 0x04, 0x05,
        0x06, 0x07, 0x08, 0x09,
        0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10, 0x11,
        0xA9, 0x6E, 0x61, 0x6D,
        0x48, 0x69, 0x00, 0x00,
        0x48, 0x65, 0x6C, 0x6C,
      ])
  }

  // MARK: - Chapter samples

  func testChapterSamplePayload() {
    // u16 BE length + "Hi" + verbatim ffmpeg 'encd' UTF-8 marker.
    XCTAssertEqual(
      Array(M4BChapterPlan(title: "Hi").samplePayload),
      [
        0x00, 0x02, 0x48, 0x69,
        0x00, 0x00, 0x00, 0x0C, 0x65, 0x6E, 0x63, 0x64, 0x00, 0x00, 0x01, 0x00,
      ])
  }

  func testChapterSamplePayloadTruncatesLongTitleAtCharacterBoundary() {
    // 40,000 × 'é' is 80,000 UTF-8 bytes; the u16 length prefix caps the
    // title at 65,535, and the character boundary rounds down to 65,534.
    let payload = M4BChapterPlan(title: String(repeating: "é", count: 40_000)).samplePayload
    XCTAssertEqual(payload.count, 2 + 65_534 + 12)
    XCTAssertEqual(Array(payload.prefix(2)), [0xFF, 0xFE])
    XCTAssertEqual(payload[2 + 65_533], 0xA9)  // last title byte completes 'é' (C3 A9)
  }

  // MARK: - chpl

  func testChplTwoChapters() {
    // Chapters at packets [96, 96] × 1024 frames, leading 2112:
    // presented starts are 0 and 96·1024 − 2112 = 96,192 frames
    // = 96,192 × 10⁷ / 48,000 = 20,040,000 hundred-ns units = 0x0131C940.
    let audio = makeAudioPlan(chapterPacketCounts: [96, 96])
    let chpl = M4BMoovBuilder.chpl(
      audio: audio,
      chapters: [M4BChapterPlan(title: "Intro"), M4BChapterPlan(title: "Chapter 1")])
    let expected: [UInt8] =
      [0x00, 0x00, 0x00, 0x31, 0x63, 0x68, 0x70, 0x6C]  // size 49, 'chpl'
      + [0x01, 0x00, 0x00, 0x00]  // version 1, flags 0
      + [0x00, 0x00, 0x00, 0x00]  // reserved
      + [0x02]  // entry count
      + [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]  // start 0
      + [0x05, 0x49, 0x6E, 0x74, 0x72, 0x6F]  // "Intro"
      + [0x00, 0x00, 0x00, 0x00, 0x01, 0x31, 0xC9, 0x40]  // start 20,040,000
      + [0x09, 0x43, 0x68, 0x61, 0x70, 0x74, 0x65, 0x72, 0x20, 0x31]  // "Chapter 1"
    XCTAssertEqual(Array(chpl), expected)
  }

  func testChplCapsAt255Entries() {
    let audio = makeAudioPlan(chapterPacketCounts: Array(repeating: 1, count: 300))
    let chapters = (0..<300).map { M4BChapterPlan(title: "C\($0)") }
    let chpl = M4BMoovBuilder.chpl(audio: audio, chapters: chapters)
    XCTAssertEqual(chpl[12 + 4], 255)  // entry count byte after header + reserved
  }

  // MARK: - ilst items

  func testIlstStringItem() {
    let expected: [UInt8] =
      [0x00, 0x00, 0x00, 0x1C, 0xA9, 0x6E, 0x61, 0x6D]  // size 28, '©nam'
      + [0x00, 0x00, 0x00, 0x14, 0x64, 0x61, 0x74, 0x61]  // size 20, 'data'
      + [0x00, 0x00, 0x00, 0x01]  // type 1: UTF-8
      + [0x00, 0x00, 0x00, 0x00]  // locale
      + [0x42, 0x6F, 0x6F, 0x6B]  // "Book"
    XCTAssertEqual(Array(M4BMoovBuilder.ilstStringItem(code: "©nam", value: "Book")), expected)
  }

  func testIlstStikAndPgap() {
    let stik: [UInt8] =
      [0x00, 0x00, 0x00, 0x19, 0x73, 0x74, 0x69, 0x6B]  // size 25, 'stik'
      + [0x00, 0x00, 0x00, 0x11, 0x64, 0x61, 0x74, 0x61]  // size 17, 'data'
      + [0x00, 0x00, 0x00, 0x15]  // type 21: signed integer
      + [0x00, 0x00, 0x00, 0x00]
      + [0x02]  // audiobook
    XCTAssertEqual(Array(M4BMoovBuilder.ilstInt8Item(code: "stik", value: 2)), stik)

    let pgap: [UInt8] =
      [0x00, 0x00, 0x00, 0x19, 0x70, 0x67, 0x61, 0x70]
      + [0x00, 0x00, 0x00, 0x11, 0x64, 0x61, 0x74, 0x61]
      + [0x00, 0x00, 0x00, 0x15]
      + [0x00, 0x00, 0x00, 0x00]
      + [0x01]
    XCTAssertEqual(Array(M4BMoovBuilder.ilstInt8Item(code: "pgap", value: 1)), pgap)
  }

  func testIlstCoverJPEGAndPNG() {
    let jpegBytes: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0]
    let jpeg: [UInt8] =
      [0x00, 0x00, 0x00, 0x1C, 0x63, 0x6F, 0x76, 0x72]  // size 28, 'covr'
      + [0x00, 0x00, 0x00, 0x14, 0x64, 0x61, 0x74, 0x61]
      + [0x00, 0x00, 0x00, 0x0D]  // type 13: JPEG
      + [0x00, 0x00, 0x00, 0x00]
      + jpegBytes
    XCTAssertEqual(
      Array(
        M4BMoovBuilder.ilstCoverItem(
          M4BMetadataPlan.Cover(data: Data(jpegBytes), format: .jpeg))),
      jpeg)

    let pngBytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
    let png: [UInt8] =
      [0x00, 0x00, 0x00, 0x1C, 0x63, 0x6F, 0x76, 0x72]
      + [0x00, 0x00, 0x00, 0x14, 0x64, 0x61, 0x74, 0x61]
      + [0x00, 0x00, 0x00, 0x0E]  // type 14: PNG
      + [0x00, 0x00, 0x00, 0x00]
      + pngBytes
    XCTAssertEqual(
      Array(
        M4BMoovBuilder.ilstCoverItem(
          M4BMetadataPlan.Cover(data: Data(pngBytes), format: .png))),
      png)
  }

  func testIlstFreeformAtom() {
    let item = M4BMoovBuilder.ilstFreeformItem(
      mean: "com.apple.iTunes", name: "iTunSMPB", value: "GAP")
    let expected: [UInt8] =
      [0x00, 0x00, 0x00, 0x4B, 0x2D, 0x2D, 0x2D, 0x2D]  // size 75, '----'
      + [0x00, 0x00, 0x00, 0x1C, 0x6D, 0x65, 0x61, 0x6E]  // size 28, 'mean'
      + [0x00, 0x00, 0x00, 0x00]  // flags
      + Array("com.apple.iTunes".utf8)
      + [0x00, 0x00, 0x00, 0x14, 0x6E, 0x61, 0x6D, 0x65]  // size 20, 'name'
      + [0x00, 0x00, 0x00, 0x00]
      + Array("iTunSMPB".utf8)
      + [0x00, 0x00, 0x00, 0x13, 0x64, 0x61, 0x74, 0x61]  // size 19, 'data'
      + [0x00, 0x00, 0x00, 0x01]
      + [0x00, 0x00, 0x00, 0x00]
      + [0x47, 0x41, 0x50]  // "GAP"
    XCTAssertEqual(Array(item), expected)
  }

  func testITunSMPBString() {
    // 2112 = 0x840, 576 = 0x240, 146,592 = 0x23CA0.
    XCTAssertEqual(
      M4BMetadataPlan.iTunSMPB(leadingFrames: 2112, trailingFrames: 576, presentedFrames: 146_592),
      " 00000000 00000840 00000240 0000000000023CA0"
        + " 00000000 00000000 00000000 00000000 00000000 00000000 00000000 00000000")
  }

  // MARK: - ffmpeg-verbatim chapter track structures

  func testTextSampleEntryMatchesFFmpegStub() {
    // 8-byte box header + 6 reserved + dref index + the 43-byte stub_header
    // from movenc.c mov_create_chapter_track = 59 bytes.
    let expected: [UInt8] =
      [0x00, 0x00, 0x00, 0x3B, 0x74, 0x65, 0x78, 0x74]  // size 59, 'text'
      + [0x00, 0x00, 0x00, 0x00, 0x00, 0x00]  // reserved
      + [0x00, 0x01]  // data reference index
      + [0x00, 0x00, 0x00, 0x01]  // displayFlags
      + [0x00, 0x00]  // justification
      + [0x00, 0x00, 0x00, 0x00]  // background colour
      + [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]  // default text box
      + [0x00, 0x00, 0x00, 0x00]  // style: start + end char
      + [0x00, 0x01]  // style: font ID
      + [0x00, 0x00]  // style: face flags + size
      + [0x00, 0x00, 0x00, 0x00]  // style: foreground colour
      + [0x00, 0x00, 0x00, 0x0D, 0x66, 0x74, 0x61, 0x62]  // ftab, size 13
      + [0x00, 0x01]  // entry count
      + [0x00, 0x01]  // font ID
      + [0x00]  // font name length
    XCTAssertEqual(Array(M4BMoovBuilder.textSampleEntry), expected)
  }

  func testGmhdMatchesFFmpegVerbatimAtom() {
    let expected: [UInt8] =
      [0x00, 0x00, 0x00, 0x4C, 0x67, 0x6D, 0x68, 0x64]  // size 76, 'gmhd'
      + [0x00, 0x00, 0x00, 0x18, 0x67, 0x6D, 0x69, 0x6E]  // size 24, 'gmin'
      + [0x00, 0x00, 0x00, 0x00]  // version + flags
      + [0x00, 0x40]  // graphics mode
      + [0x80, 0x00, 0x80, 0x00, 0x80, 0x00]  // opColor
      + [0x00, 0x00]  // balance
      + [0x00, 0x00]  // reserved
      + [0x00, 0x00, 0x00, 0x2C, 0x74, 0x65, 0x78, 0x74]  // size 44, 'text'
      + [0x00, 0x01]
      + [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
      + [0x00, 0x00, 0x00, 0x01]
      + [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
      + [0x00, 0x00, 0x40, 0x00]
      + [0x00, 0x00]
    XCTAssertEqual(Array(M4BMoovBuilder.gmhd), expected)
  }

  // MARK: - esds and elst

  func testEsdsFor48kMonoLCAt256kbps() {
    // ES(tag 3, len 25) ⊃ DecoderConfig(tag 4, len 17: OTI 0x40, streamType
    // 0x15, bufferSizeDB 768, max = avg = 256,000 = 0x3E800) ⊃ ASC 11 88,
    // then SLConfig(tag 6) = 02. All descriptor lengths minimal-form.
    let expected: [UInt8] =
      [0x00, 0x00, 0x00, 0x27, 0x65, 0x73, 0x64, 0x73]  // size 39, 'esds'
      + [0x00, 0x00, 0x00, 0x00]  // version + flags
      + [0x03, 0x19]  // ES_Descriptor
      + [0x00, 0x01, 0x00]  // ES_ID 1, no flags
      + [0x04, 0x11]  // DecoderConfigDescriptor
      + [0x40, 0x15, 0x00, 0x03, 0x00]  // OTI, streamType, bufferSizeDB
      + [0x00, 0x03, 0xE8, 0x00]  // maxBitrate
      + [0x00, 0x03, 0xE8, 0x00]  // avgBitrate
      + [0x05, 0x02, 0x11, 0x88]  // DecoderSpecificInfo: ASC
      + [0x06, 0x01, 0x02]  // SLConfigDescriptor
    XCTAssertEqual(
      Array(M4BMoovBuilder.esds(audioSpecificConfig: Data([0x11, 0x88]), bitRate: 256_000)),
      expected)
  }

  func testElst() {
    // Presented duration 60,000 movie units, trimming 2112 priming frames.
    let expected: [UInt8] =
      [0x00, 0x00, 0x00, 0x1C, 0x65, 0x6C, 0x73, 0x74]  // size 28, 'elst'
      + [0x00, 0x00, 0x00, 0x00]  // version 0, flags 0
      + [0x00, 0x00, 0x00, 0x01]  // entry count
      + [0x00, 0x00, 0xEA, 0x60]  // segment duration 60,000
      + [0x00, 0x00, 0x08, 0x40]  // media time 2112
      + [0x00, 0x01, 0x00, 0x00]  // media rate 1.0
    XCTAssertEqual(Array(M4BMoovBuilder.elst(segmentDuration: 60_000, mediaTime: 2112)), expected)
  }

  func testElstUsesVersionOneForLongDurations() {
    let data = M4BMoovBuilder.elst(segmentDuration: UInt64(UInt32.max) + 1, mediaTime: 2_112)
    XCTAssertEqual(data[8], 1, "full-box version")
    XCTAssertEqual(data.count, 36)
  }

  // MARK: - Sample tables

  func testAudioSttsSingleEntry() {
    let expected: [UInt8] =
      [0x00, 0x00, 0x00, 0x18, 0x73, 0x74, 0x74, 0x73]
      + [0x00, 0x00, 0x00, 0x00]
      + [0x00, 0x00, 0x00, 0x01]  // entry count
      + [0x00, 0x00, 0x00, 0xC0]  // 192 packets
      + [0x00, 0x00, 0x04, 0x00]  // 1024 frames each
    XCTAssertEqual(Array(M4BMoovBuilder.stts([(count: 192, delta: 1024)])), expected)
  }

  func testTextSttsUsesPresentedTimeline() {
    // Chapters of [10, 10, 5] packets with 2,112 priming frames: the first
    // chapter's presented duration is 10,240 − 2,112 = 8,128 (the text track
    // has no edit list, so its samples live on the post-elst timeline), then
    // 10,240, then 23,388 − 18,368 = 5,020. Durations sum to the presented
    // total, keeping chap-track marks aligned with what the listener hears.
    let audio = makeAudioPlan(chapterPacketCounts: [10, 10, 5], trailingFrames: 100)
    let entries = M4BMoovBuilder.textSTTSEntries(audio: audio)
    XCTAssertEqual(entries.map { $0.count }, [1, 1, 1])
    XCTAssertEqual(entries.map { $0.delta }, [8_128, 10_240, 5_020])
    XCTAssertEqual(
      entries.reduce(0) { $0 + $1.count * $1.delta }, audio.presentedFrames)

    let expected: [UInt8] =
      [0x00, 0x00, 0x00, 0x28, 0x73, 0x74, 0x74, 0x73]  // size 40, 'stts'
      + [0x00, 0x00, 0x00, 0x00]
      + [0x00, 0x00, 0x00, 0x03]  // entry count
      + [0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x1F, 0xC0]  // 1 × 8,128
      + [0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x28, 0x00]  // 1 × 10,240
      + [0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x13, 0x9C]  // 1 × 5,020
    XCTAssertEqual(Array(M4BMoovBuilder.stts(entries)), expected)
  }

  func testTextSttsRunMergingWithoutPriming() {
    let audio = makeAudioPlan(
      chapterPacketCounts: [10, 10, 5], leadingFrames: 0, trailingFrames: 100)
    let entries = M4BMoovBuilder.textSTTSEntries(audio: audio)
    XCTAssertEqual(entries.map { $0.count }, [2, 1])
    XCTAssertEqual(entries.map { $0.delta }, [10_240, 5_120 - 100])
  }

  func testStscRunMergingAcrossChapters() {
    // Chapters of 120 and 100 packets chunk as 50/50/20 then 50/50; the 20
    // never merges across the chapter boundary, the two 50-runs around it do
    // not join, and equal consecutive runs collapse.
    let expected: [UInt8] =
      [0x00, 0x00, 0x00, 0x34, 0x73, 0x74, 0x73, 0x63]  // size 52, 'stsc'
      + [0x00, 0x00, 0x00, 0x00]
      + [0x00, 0x00, 0x00, 0x03]  // entry count
      + [0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x32, 0x00, 0x00, 0x00, 0x01]  // 1: 50
      + [0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x14, 0x00, 0x00, 0x00, 0x01]  // 3: 20
      + [0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x32, 0x00, 0x00, 0x00, 0x01]  // 4: 50
    XCTAssertEqual(Array(M4BMoovBuilder.stsc(chunkPacketCounts: [50, 50, 20, 50, 50])), expected)
  }

  func testStszAndChunkOffsetBoxes() {
    let stsz: [UInt8] =
      [0x00, 0x00, 0x00, 0x20, 0x73, 0x74, 0x73, 0x7A]
      + [0x00, 0x00, 0x00, 0x00]
      + [0x00, 0x00, 0x00, 0x00]  // sample_size 0: per-sample table
      + [0x00, 0x00, 0x00, 0x03]
      + [0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x03]
    XCTAssertEqual(Array(M4BMoovBuilder.stsz(sizes: [1, 2, 3])), stsz)

    let stco: [UInt8] =
      [0x00, 0x00, 0x00, 0x18, 0x73, 0x74, 0x63, 0x6F]
      + [0x00, 0x00, 0x00, 0x00]
      + [0x00, 0x00, 0x00, 0x02]
      + [0x00, 0x00, 0x00, 0x40, 0x00, 0x01, 0x00, 0x00]
    XCTAssertEqual(
      Array(M4BMoovBuilder.chunkOffsetBox([0x40, 0x1_0000], useCO64: false)), stco)

    let co64: [UInt8] =
      [0x00, 0x00, 0x00, 0x20, 0x63, 0x6F, 0x36, 0x34]
      + [0x00, 0x00, 0x00, 0x00]
      + [0x00, 0x00, 0x00, 0x02]
      + [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x40]
      + [0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00]
    XCTAssertEqual(
      Array(M4BMoovBuilder.chunkOffsetBox([0x40, 0x1_0000_0000], useCO64: true)), co64)
  }

  // MARK: - Header boxes and the version-1 switch

  func testMvhdVersionSwitch() {
    let v0: [UInt8] =
      [0x00, 0x00, 0x00, 0x6C, 0x6D, 0x76, 0x68, 0x64]  // size 108, 'mvhd'
      + [0x00, 0x00, 0x00, 0x00]  // version 0, flags 0
      + [0x00, 0x00, 0x00, 0x00]  // creation time
      + [0x00, 0x00, 0x00, 0x00]  // modification time
      + [0x00, 0x00, 0x03, 0xE8]  // timescale 1000
      + [0x00, 0x01, 0xE2, 0x40]  // duration 123,456
      + [0x00, 0x01, 0x00, 0x00]  // rate 1.0
      + [0x01, 0x00]  // volume 1.0
      + [0x00, 0x00]  // reserved
      + [UInt8](repeating: 0, count: 8)  // reserved
      + identityMatrixBytes
      + [UInt8](repeating: 0, count: 24)  // pre_defined
      + [0x00, 0x00, 0x00, 0x03]  // nextTrackID
    XCTAssertEqual(
      Array(M4BMoovBuilder.mvhd(timescale: 1000, duration: 123_456, nextTrackID: 3)), v0)

    let v1: [UInt8] =
      [0x00, 0x00, 0x00, 0x78, 0x6D, 0x76, 0x68, 0x64]  // size 120
      + [0x01, 0x00, 0x00, 0x00]  // version 1
      + [UInt8](repeating: 0, count: 16)  // creation + modification
      + [0x00, 0x00, 0x03, 0xE8]
      + [0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01]  // duration 2³² + 1
      + [0x00, 0x01, 0x00, 0x00]
      + [0x01, 0x00]
      + [0x00, 0x00]
      + [UInt8](repeating: 0, count: 8)
      + identityMatrixBytes
      + [UInt8](repeating: 0, count: 24)
      + [0x00, 0x00, 0x00, 0x03]
    XCTAssertEqual(
      Array(M4BMoovBuilder.mvhd(timescale: 1000, duration: 0x1_0000_0001, nextTrackID: 3)), v1)
  }

  func testMdhdVersionSwitch() {
    let v0: [UInt8] =
      [0x00, 0x00, 0x00, 0x20, 0x6D, 0x64, 0x68, 0x64]  // size 32, 'mdhd'
      + [0x00, 0x00, 0x00, 0x00]
      + [0x00, 0x00, 0x00, 0x00]
      + [0x00, 0x00, 0x00, 0x00]
      + [0x00, 0x00, 0xBB, 0x80]  // timescale 48,000
      + [0xFF, 0xFF, 0xFF, 0xFF]  // duration 2³² − 1: still version 0
      + [0x55, 0xC4]  // language 'und'
      + [0x00, 0x00]  // pre_defined
    XCTAssertEqual(Array(M4BMoovBuilder.mdhd(timescale: 48_000, duration: 0xFFFF_FFFF)), v0)

    let v1: [UInt8] =
      [0x00, 0x00, 0x00, 0x2C, 0x6D, 0x64, 0x68, 0x64]  // size 44
      + [0x01, 0x00, 0x00, 0x00]
      + [UInt8](repeating: 0, count: 16)
      + [0x00, 0x00, 0xBB, 0x80]
      + [0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00]  // duration 2³²
      + [0x55, 0xC4]
      + [0x00, 0x00]
    XCTAssertEqual(Array(M4BMoovBuilder.mdhd(timescale: 48_000, duration: 0x1_0000_0000)), v1)
  }

  func testTkhdGolden() {
    let expected: [UInt8] =
      [0x00, 0x00, 0x00, 0x5C, 0x74, 0x6B, 0x68, 0x64]  // size 92, 'tkhd'
      + [0x00, 0x00, 0x00, 0x03]  // version 0, flags enabled | in-movie
      + [0x00, 0x00, 0x00, 0x00]  // creation time
      + [0x00, 0x00, 0x00, 0x00]  // modification time
      + [0x00, 0x00, 0x00, 0x01]  // trackID
      + [0x00, 0x00, 0x00, 0x00]  // reserved
      + [0x00, 0x00, 0xEA, 0x60]  // duration 60,000
      + [UInt8](repeating: 0, count: 8)  // reserved
      + [0x00, 0x00]  // layer
      + [0x00, 0x00]  // alternate group
      + [0x01, 0x00]  // volume
      + [0x00, 0x00]  // reserved
      + identityMatrixBytes
      + [UInt8](repeating: 0, count: 8)  // width + height
    XCTAssertEqual(
      Array(M4BMoovBuilder.tkhd(trackID: 1, flags: 0x3, duration: 60_000, volume: 0x0100)),
      expected)
  }

  func testHdlrGolden() {
    let sound: [UInt8] =
      [0x00, 0x00, 0x00, 0x2D, 0x68, 0x64, 0x6C, 0x72]  // size 45, 'hdlr'
      + [0x00, 0x00, 0x00, 0x00]
      + [0x00, 0x00, 0x00, 0x00]  // pre_defined
      + [0x73, 0x6F, 0x75, 0x6E]  // 'soun'
      + [UInt8](repeating: 0, count: 12)  // reserved
      + Array("SoundHandler".utf8)
      + [0x00]
    XCTAssertEqual(Array(M4BMoovBuilder.hdlr(handlerType: "soun", name: "SoundHandler")), sound)

    // ffmpeg's fixed 33-byte iTunes metadata handler.
    let itunes: [UInt8] =
      [0x00, 0x00, 0x00, 0x21, 0x68, 0x64, 0x6C, 0x72]  // size 33
      + [0x00, 0x00, 0x00, 0x00]
      + [0x00, 0x00, 0x00, 0x00]
      + [0x6D, 0x64, 0x69, 0x72]  // 'mdir'
      + [0x61, 0x70, 0x70, 0x6C]  // 'appl'
      + [0x00, 0x00, 0x00, 0x00]
      + [0x00, 0x00, 0x00, 0x00]
      + [0x00]
    XCTAssertEqual(Array(M4BMoovBuilder.itunesHdlr), itunes)
  }

  func testSmhdAndDinfGolden() {
    XCTAssertEqual(
      Array(M4BMoovBuilder.smhd),
      [
        0x00, 0x00, 0x00, 0x10, 0x73, 0x6D, 0x68, 0x64,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      ])
    let dinf: [UInt8] =
      [0x00, 0x00, 0x00, 0x24, 0x64, 0x69, 0x6E, 0x66]  // size 36, 'dinf'
      + [0x00, 0x00, 0x00, 0x1C, 0x64, 0x72, 0x65, 0x66]  // size 28, 'dref'
      + [0x00, 0x00, 0x00, 0x00]
      + [0x00, 0x00, 0x00, 0x01]  // entry count
      + [0x00, 0x00, 0x00, 0x0C, 0x75, 0x72, 0x6C, 0x20]  // size 12, 'url '
      + [0x00, 0x00, 0x00, 0x01]  // flags: self-contained
    XCTAssertEqual(Array(M4BMoovBuilder.dinf), dinf)
  }

  // MARK: - Whole moov structure

  func testBuildProducesWellFormedMoov() {
    let audio = makeAudioPlan(chapterPacketCounts: [3, 2, 1])
    let chapters = ["A", "B", "C"].map { M4BChapterPlan(title: $0) }
    let metadata = M4BMetadataPlan(
      title: "Book",
      author: "Author",
      narrator: "Voice",
      writer: "Writer",
      genre: "Genre",
      day: "2026",
      description: "Desc",
      cover: M4BMetadataPlan.Cover(data: Data([0xFF, 0xD8, 0xFF, 0xE0]), format: .jpeg))
    let offsets = OffsetPlanner.plan(audio: audio, chapters: chapters)
    let moov = M4BMoovBuilder.build(
      audio: audio, chapters: chapters, metadata: metadata, offsets: offsets)

    let top = childBoxes(in: moov, range: 0..<moov.count)
    XCTAssertEqual(top.map { $0.type }, ["moov"])

    let children = childBoxes(in: moov, range: top[0].payload)
    XCTAssertEqual(children.map { $0.type }, ["mvhd", "trak", "trak", "udta"])

    let audioTrak = childBoxes(in: moov, range: children[1].payload)
    XCTAssertEqual(audioTrak.map { $0.type }, ["tkhd", "edts", "tref", "mdia"])

    let textTrak = childBoxes(in: moov, range: children[2].payload)
    XCTAssertEqual(textTrak.map { $0.type }, ["tkhd", "mdia"])

    let udta = childBoxes(in: moov, range: children[3].payload)
    XCTAssertEqual(udta.map { $0.type }, ["chpl", "meta"])
  }

  // MARK: - Helpers

  private let identityMatrixBytes: [UInt8] =
    [0x00, 0x01, 0x00, 0x00] + [UInt8](repeating: 0, count: 8)
    + [UInt8](repeating: 0, count: 4) + [0x00, 0x01, 0x00, 0x00]
    + [UInt8](repeating: 0, count: 4)
    + [UInt8](repeating: 0, count: 8) + [0x40, 0x00, 0x00, 0x00]

  private func makeAudioPlan(
    chapterPacketCounts: [Int],
    leadingFrames: Int = 2112,
    trailingFrames: Int = 576
  ) -> M4BAudioTrackPlan {
    let totalPackets = chapterPacketCounts.reduce(0, +)
    return M4BAudioTrackPlan(
      totalPackets: totalPackets,
      packetSizes: [UInt32](repeating: 400, count: totalPackets),
      bitRate: 256_000,
      audioSpecificConfig: Data([0x11, 0x88]),
      leadingFrames: leadingFrames,
      trailingFrames: trailingFrames,
      chapterPacketCounts: chapterPacketCounts)
  }

  /// Minimal box walker: asserts sizes tile the range exactly.
  private func childBoxes(
    in data: Data, range: Range<Int>
  ) -> [(type: String, payload: Range<Int>)] {
    var children: [(type: String, payload: Range<Int>)] = []
    var offset = range.lowerBound
    while offset + 8 <= range.upperBound {
      let size = data.subdata(in: offset..<offset + 4).reduce(0) { ($0 << 8) | Int($1) }
      let type = String(decoding: data.subdata(in: offset + 4..<offset + 8), as: UTF8.self)
      XCTAssertGreaterThanOrEqual(size, 8, "Undersized box \(type)")
      XCTAssertLessThanOrEqual(offset + size, range.upperBound, "Box \(type) overruns parent")
      children.append((type: type, payload: offset + 8..<offset + size))
      offset += size
    }
    XCTAssertEqual(offset, range.upperBound, "Boxes do not tile the parent payload")
    return children
  }
}

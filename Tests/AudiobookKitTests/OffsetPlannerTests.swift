import XCTest

@testable import AudiobookKit

final class OffsetPlannerTests: XCTestCase {

  func testFtypGolden() {
    let expected: [UInt8] =
      [0x00, 0x00, 0x00, 0x20, 0x66, 0x74, 0x79, 0x70]  // size 32, 'ftyp'
      + [0x4D, 0x34, 0x41, 0x20]  // major 'M4A '
      + [0x00, 0x00, 0x00, 0x00]  // minor version
      + [0x4D, 0x34, 0x41, 0x20]  // 'M4A '
      + [0x4D, 0x34, 0x42, 0x20]  // 'M4B '
      + [0x6D, 0x70, 0x34, 0x32]  // 'mp42'
      + [0x69, 0x73, 0x6F, 0x6D]  // 'isom'
    XCTAssertEqual(Array(OffsetPlanner.ftyp()), expected)
  }

  func testThreeChapterPlanOffsets() {
    // Titles "A"/"B"/"C" produce 15-byte text samples (2 + 1 + 12), so the
    // text block is 45 bytes; audio is 10+20+30 | 40+50 | 60 = 210 bytes.
    let audio = makeAudioPlan(
      chapterPacketCounts: [3, 2, 1],
      packetSizes: [10, 20, 30, 40, 50, 60])
    let chapters = ["A", "B", "C"].map { M4BChapterPlan(title: $0) }
    let plan = OffsetPlanner.plan(audio: audio, chapters: chapters)

    XCTAssertEqual(plan.ftypSize, 32)
    XCTAssertEqual(plan.ftypSize, OffsetPlanner.ftyp().count)
    XCTAssertFalse(plan.usesLargeMdat)
    XCTAssertEqual(plan.mdatHeaderSize, 8)
    XCTAssertEqual(plan.mdatPayloadSize, 255)
    XCTAssertEqual(plan.textBlockOffset, 40)
    XCTAssertEqual(plan.textBlockOffset, UInt64(plan.ftypSize + plan.mdatHeaderSize))
    XCTAssertEqual(plan.textSampleOffsets, [40, 55, 70])
    XCTAssertEqual(plan.chunkOffsets, [85, 145, 235])
    XCTAssertEqual(plan.chunkPacketCounts, [3, 2, 1])
    XCTAssertFalse(plan.usesCO64)
    XCTAssertEqual(plan.fileSizeExcludingMoov, 295)

    // Compact mdat header: u32 size 8 + 255 = 263 = 0x107.
    XCTAssertEqual(
      Array(plan.mdatHeader),
      [0x00, 0x00, 0x01, 0x07, 0x6D, 0x64, 0x61, 0x74])
  }

  func testChunksNeverSpanChapterBoundaries() {
    // 120 + 100 packets of 2 bytes chunk as 50/50/20 | 50/50: the third chunk
    // is cut short at the chapter boundary instead of borrowing packets.
    let audio = makeAudioPlan(
      chapterPacketCounts: [120, 100],
      packetSizes: [UInt32](repeating: 2, count: 220))
    let chapters = ["A", "B"].map { M4BChapterPlan(title: $0) }
    let plan = OffsetPlanner.plan(audio: audio, chapters: chapters)

    XCTAssertEqual(plan.chunkPacketCounts, [50, 50, 20, 50, 50])
    // Text block is 30 bytes, so audio starts at 32 + 8 + 30 = 70; chunks of
    // 50 packets are 100 bytes and the 20-packet chunk is 40.
    XCTAssertEqual(plan.textSampleOffsets, [40, 55])
    XCTAssertEqual(plan.chunkOffsets, [70, 170, 270, 310, 410])
    XCTAssertEqual(plan.mdatPayloadSize, 470)
    XCTAssertEqual(plan.fileSizeExcludingMoov, 510)
  }

  func testLargeBookSelectsCO64AndLargesizeMdat() {
    // 3 × 1,500,000 packets of 1,000 bytes = 4.5 GB of audio: only sizes are
    // materialized, never packet data. Text samples: 17 + 17 + 19 = 53 bytes.
    let packetsPerChapter = 1_500_000
    let audio = makeAudioPlan(
      chapterPacketCounts: [Int](repeating: packetsPerChapter, count: 3),
      packetSizes: [UInt32](repeating: 1000, count: 3 * packetsPerChapter))
    let chapters = ["One", "Two", "Three"].map { M4BChapterPlan(title: $0) }
    let plan = OffsetPlanner.plan(audio: audio, chapters: chapters)

    XCTAssertTrue(plan.usesLargeMdat)
    XCTAssertEqual(plan.mdatHeaderSize, 16)
    XCTAssertEqual(plan.mdatPayloadSize, 4_500_000_053)
    XCTAssertEqual(plan.textBlockOffset, 48)
    XCTAssertEqual(plan.textBlockOffset, UInt64(plan.ftypSize + plan.mdatHeaderSize))
    XCTAssertEqual(plan.textSampleOffsets, [48, 65, 82])

    // 30,000 uniform 50-packet chunks per chapter, 50,000 bytes apart,
    // starting right after the 53-byte text block.
    XCTAssertEqual(plan.chunkOffsets.count, 90_000)
    XCTAssertEqual(plan.chunkPacketCounts.count, 90_000)
    XCTAssertTrue(plan.chunkPacketCounts.allSatisfy { $0 == 50 })
    XCTAssertEqual(plan.chunkOffsets[0], 101)
    XCTAssertEqual(plan.chunkOffsets[1], 50_101)
    XCTAssertEqual(plan.chunkOffsets[30_000], 1_500_000_101)  // chapter 2 start
    XCTAssertEqual(plan.chunkOffsets[85_899], 4_294_950_101)  // last chunk below 2³²
    XCTAssertEqual(plan.chunkOffsets[85_900], 4_295_000_101)  // first chunk above 2³²
    XCTAssertEqual(plan.chunkOffsets[89_999], 4_499_950_101)
    XCTAssertTrue(plan.usesCO64)
    XCTAssertEqual(plan.fileSizeExcludingMoov, 4_500_000_101)

    // Largesize mdat header: size = 1, then u64 16 + 4,500,000,053
    // = 4,500,000,069 = 0x1_0C38_8D45.
    XCTAssertEqual(
      Array(plan.mdatHeader),
      [
        0x00, 0x00, 0x00, 0x01, 0x6D, 0x64, 0x61, 0x74,
        0x00, 0x00, 0x00, 0x01, 0x0C, 0x38, 0x8D, 0x45,
      ])
  }

  func testCompactMdatStaysCompactAtBoundary() {
    // 8 + payload = exactly 2³² − 1 still fits the compact u32 form.
    let plan = M4BOffsetPlan(
      ftypSize: 32,
      usesLargeMdat: false,
      mdatPayloadSize: UInt64(UInt32.max) - 8,
      textBlockOffset: 40,
      textSampleOffsets: [40],
      chunkOffsets: [55],
      chunkPacketCounts: [1],
      usesCO64: false,
      fileSizeExcludingMoov: UInt64(UInt32.max) + 32)
    XCTAssertEqual(
      Array(plan.mdatHeader),
      [0xFF, 0xFF, 0xFF, 0xFF, 0x6D, 0x64, 0x61, 0x74])
  }

  private func makeAudioPlan(
    chapterPacketCounts: [Int],
    packetSizes: [UInt32]
  ) -> M4BAudioTrackPlan {
    M4BAudioTrackPlan(
      totalPackets: packetSizes.count,
      packetSizes: packetSizes,
      bitRate: 256_000,
      audioSpecificConfig: Data([0x11, 0x88]),
      leadingFrames: 2112,
      trailingFrames: 576,
      chapterPacketCounts: chapterPacketCounts)
  }
}

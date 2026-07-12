import AVFoundation
import XCTest
import PublicationKit

@testable import AudiobookKit

/// End-to-end: tone PCM → streaming AAC chapters → assembled .m4b →
/// verified through AVFoundation (the same stack Apple Books uses) plus a
/// raw box walk for the atoms AVFoundation does not expose.
final class M4BRoundTripTests: XCTestCase {
  private var workRoot: URL!
  private var outputURL: URL!

  override func setUp() {
    super.setUp()
    workRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("m4b-roundtrip-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: workRoot, withIntermediateDirectories: true)
    outputURL = workRoot.appendingPathComponent("book.m4b")
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: workRoot)
    super.tearDown()
  }

  private func tonePCM(seconds: Double, frequency: Double) -> Data {
    let frames = Int(48_000 * seconds)
    var data = Data(capacity: frames * 2)
    for frame in 0..<frames {
      var value = Int16(sin(2 * .pi * frequency * Double(frame) / 48_000) * 10_000).littleEndian
      withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }
    return data
  }

  func testAssembledAudiobookReadsBackCorrectly() async throws {
    let settings = AACEncodingSettings(bitRate: 64_000)
    let fingerprint = Data(repeating: 5, count: 32)
    let writer = M4BAudiobookWriter(settings: settings, fingerprint: fingerprint)

    // Three chapters of distinct tones, 2 s each.
    let titles = ["One: Departure", "Two: The Crossing — 旅", "Three"]
    var chapters: [(title: String, artifact: M4BChapterArtifact)] = []
    for (index, title) in titles.enumerated() {
      let encoder = try writer.makeChapterEncoder(
        artifactURL: workRoot.appendingPathComponent("ch\(index).aacseg"))
      try encoder.append(pcm16: tonePCM(seconds: 2, frequency: 220 * Double(index + 1)))
      chapters.append((title, try encoder.finish()))
    }

    let cover = PublicationCover(data: EPUBFixture.pngPixel, kind: .png)
    try writer.assemble(
      chapters: chapters,
      metadata: AudiobookMetadata(
        title: "Round Trip", author: "An Author", narrator: "Nora (Natural)",
        genre: "Fiction", date: "2026", bookDescription: "A test book."),
      cover: cover,
      to: outputURL,
      progress: nil)

    // --- AVFoundation readback ---
    let asset = AVURLAsset(url: outputURL)
    let duration = try await asset.load(.duration)
    let expectedSeconds = 6.0  // trimmed timeline: priming/pad handled by elst
    XCTAssertEqual(duration.seconds, expectedSeconds, accuracy: 0.1)

    let locales = try await asset.load(.availableChapterLocales)
    XCTAssertFalse(locales.isEmpty, "chapter track must be discoverable")
    let groups = try await asset.loadChapterMetadataGroups(
      withTitleLocale: locales.first ?? Locale(identifier: "en"), containingItemsWithCommonKeys: [])
    XCTAssertEqual(groups.count, 3)
    var readTitles: [String] = []
    var starts: [Double] = []
    for group in groups {
      if let item = group.items.first(where: { $0.commonKey == .commonKeyTitle }) {
        readTitles.append(try await item.load(.stringValue) ?? "")
      }
      starts.append(group.timeRange.start.seconds)
    }
    XCTAssertEqual(readTitles, titles)
    // Expected starts: cumulative artifact frames on the presented (post-
    // edit-list) timeline — the drift-free property that actually matters.
    let leading = chapters[0].artifact.leadingFrames
    var cumulative = 0
    for (index, chapter) in chapters.enumerated() {
      let expected = Double(max(0, cumulative - leading)) / 48_000
      XCTAssertEqual(starts[index], expected, accuracy: 0.005, "chapter \(index) start")
      cumulative += chapter.artifact.totalFrames
    }

    let metadata = try await asset.load(.metadata)
    func stringValue(_ identifier: AVMetadataIdentifier) async throws -> String? {
      guard let item = AVMetadataItem.metadataItems(
        from: metadata, filteredByIdentifier: identifier).first
      else { return nil }
      return try await item.load(.stringValue)
    }
    let title = try await stringValue(.iTunesMetadataSongName)
    XCTAssertEqual(title, "Round Trip")
    let artist = try await stringValue(.iTunesMetadataArtist)
    XCTAssertEqual(artist, "Nora (Natural)")
    let album = try await stringValue(.iTunesMetadataAlbum)
    XCTAssertEqual(album, "An Author")
    let genre = try await stringValue(.iTunesMetadataUserGenre)
    XCTAssertEqual(genre, "Fiction")
    // The audiobook synopsis lives in the iTunes 'desc' atom; AVFoundation's
    // .iTunesMetadataDescription constant maps to '©des' instead, so build
    // the identifier for the real key.
    let descIdentifier = try XCTUnwrap(
      AVMetadataItem.identifier(forKey: "desc", keySpace: .iTunes))
    let description = try await stringValue(descIdentifier)
    XCTAssertEqual(description, "A test book.")
    let coverItem = AVMetadataItem.metadataItems(
      from: metadata, filteredByIdentifier: .iTunesMetadataCoverArt).first
    let loadedCover = try await coverItem?.load(.dataValue)
    let coverData = try XCTUnwrap(loadedCover)
    // The cover policy may re-encode (e.g. alpha PNGs are flattened), so
    // assert a decodable PNG rather than byte identity.
    XCTAssertTrue(coverData.starts(with: [0x89, 0x50, 0x4E, 0x47]))

    // Full decode through AVAudioFile: playable audio end to end.
    let file = try AVAudioFile(forReading: outputURL)
    XCTAssertEqual(file.processingFormat.channelCount, 1)
    XCTAssertEqual(file.processingFormat.sampleRate, 48_000)
    XCTAssertEqual(Double(file.length) / 48_000, expectedSeconds, accuracy: 0.1)
    let decodedBuffer = try XCTUnwrap(
      AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_384))
    var decodedFrames: AVAudioFramePosition = 0
    while file.framePosition < file.length {
      try file.read(into: decodedBuffer, frameCount: decodedBuffer.frameCapacity)
      XCTAssertGreaterThan(decodedBuffer.frameLength, 0)
      decodedFrames += AVAudioFramePosition(decodedBuffer.frameLength)
    }
    XCTAssertEqual(decodedFrames, file.length)

    // --- Raw box assertions for atoms AVFoundation hides ---
    let bytes = try Data(contentsOf: outputURL)
    let stik = try XCTUnwrap(
      MP4BoxReader.box(at: ["moov", "udta", "meta", "ilst", "stik"], in: bytes))
    XCTAssertEqual(MP4BoxReader.ilstValue(stik), Data([0x02]), "stik must mark an audiobook")
    let pgap = try XCTUnwrap(
      MP4BoxReader.box(at: ["moov", "udta", "meta", "ilst", "pgap"], in: bytes))
    XCTAssertEqual(MP4BoxReader.ilstValue(pgap), Data([0x01]))

    let chpl = try XCTUnwrap(MP4BoxReader.box(at: ["moov", "udta", "chpl"], in: bytes))
    // version 1 + flags, u32 reserved, u8 count.
    XCTAssertEqual(chpl.payload[chpl.payload.startIndex], 0x01)
    XCTAssertEqual(chpl.payload[chpl.payload.startIndex + 8], 3, "three Nero chapter entries")

    // ftyp brands.
    let ftyp = try XCTUnwrap(MP4BoxReader.topLevelBoxes(in: bytes).first(where: { $0.type == "ftyp" }))
    XCTAssertTrue(String(decoding: ftyp.payload.prefix(4), as: UTF8.self) == "M4A ")
  }

  /// `audiobook verify` walks arbitrary files: hostile box sizes must end the
  /// walk, never trap.
  func testBoxWalkerSurvivesHostileSizes() {
    var data = Data()
    data.append(contentsOf: [0, 0, 0, 12])
    data.append(Data("free".utf8))
    data.append(Data(count: 4))
    // Largesize box claiming 2^64-1 bytes.
    data.append(contentsOf: [0, 0, 0, 1])
    data.append(Data("moov".utf8))
    data.append(Data(repeating: 0xFF, count: 8))

    XCTAssertEqual(MP4BoxReader.topLevelBoxes(in: data).map(\.type), ["free"])

    // Truncated header and undersized declared size.
    XCTAssertTrue(MP4BoxReader.topLevelBoxes(in: Data([0, 0, 0])).isEmpty)
    var undersized = Data()
    undersized.append(contentsOf: [0, 0, 0, 4])
    undersized.append(Data("mdat".utf8))
    XCTAssertTrue(MP4BoxReader.topLevelBoxes(in: undersized).isEmpty)
  }

  func testAssemblyRejectsMixedSettingsArtifacts() throws {
    let fingerprintA = Data(repeating: 1, count: 32)
    let writerA = M4BAudiobookWriter(
      settings: AACEncodingSettings(bitRate: 64_000), fingerprint: fingerprintA)

    let encoder = try writerA.makeChapterEncoder(
      artifactURL: workRoot.appendingPathComponent("a.aacseg"))
    try encoder.append(pcm16: tonePCM(seconds: 0.5, frequency: 440))
    let artifact = try encoder.finish()

    // Same artifact twice is fine; a doctored ASC must be rejected.
    let mismatched = M4BChapterArtifact(
      url: artifact.url, packetCount: artifact.packetCount,
      framesPerPacket: artifact.framesPerPacket, leadingFrames: artifact.leadingFrames,
      trailingFrames: artifact.trailingFrames, payloadByteCount: artifact.payloadByteCount,
      audioSpecificConfig: Data([0x12, 0x10]))
    XCTAssertThrowsError(
      try writerA.assemble(
        chapters: [("A", artifact), ("B", mismatched)],
        metadata: AudiobookMetadata(title: "X"), cover: nil,
        to: workRoot.appendingPathComponent("x.m4b"), progress: nil)
    ) { error in
      guard case AudiobookAudioError.inconsistentAudioConfig = error else {
        return XCTFail("unexpected: \(error)")
      }
    }
  }

  func testNoClobberPolicyPreservesDestinationThatAppearsBeforeCommit() throws {
    let settings = AACEncodingSettings(bitRate: 64_000)
    let fingerprint = Data(repeating: 9, count: 32)
    let writer = M4BAudiobookWriter(settings: settings, fingerprint: fingerprint)
    let encoder = try writer.makeChapterEncoder(
      artifactURL: workRoot.appendingPathComponent("race.aacseg"))
    try encoder.append(pcm16: tonePCM(seconds: 0.2, frequency: 440))
    let artifact = try encoder.finish()
    let sentinel = Data("do not replace".utf8)
    try sentinel.write(to: outputURL)

    XCTAssertThrowsError(
      try writer.assemble(
        chapters: [("One", artifact)], metadata: AudiobookMetadata(title: "Race"),
        cover: nil, to: outputURL, progress: nil)) { error in
          guard case AudiobookAudioError.outputAlreadyExists = error else {
            return XCTFail("unexpected error: \(error)")
          }
        }
    XCTAssertEqual(try Data(contentsOf: outputURL), sentinel)
  }

  func testFileBackedBoxReaderSkipsSparseLargeMdat() throws {
    let url = workRoot.appendingPathComponent("sparse-large.m4b")
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    let mdatSize = UInt64(UInt32.max) + 1_024
    var header = Data()
    header.appendU32(1)
    header.appendFourCC("mdat")
    header.appendU64(mdatSize)
    try handle.write(contentsOf: header)
    try handle.seek(toOffset: mdatSize)
    try handle.write(contentsOf: MP4BoxWriter.box("moov", Data([1, 2, 3])))
    try handle.close()

    XCTAssertEqual(
      try MP4FileReader.payload(ofTopLevelBox: "moov", at: url), Data([1, 2, 3]))
  }
}

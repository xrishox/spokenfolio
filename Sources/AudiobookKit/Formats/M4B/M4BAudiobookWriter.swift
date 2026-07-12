import Foundation
import PublicationKit

/// The M4B/AAC audiobook container: per-chapter `.aacseg` artifacts plus a
/// single-pass ISO-BMFF assembly with both chapter systems (Apple's chap
/// text track and Nero chpl), iTunes metadata, cover art, and gapless trims.
package struct M4BAudiobookWriter: M4BWriting {
  package let formatIdentifier = "m4b-aac-v2"
  package let fileExtension = "m4b"

  private let settings: AACEncodingSettings
  private let fingerprint: Data
  private let overwriteExisting: Bool

  /// `fingerprint` is the 32-byte job digest; artifacts carry it so segments
  /// from different settings are never mixed.
  package init(
    settings: AACEncodingSettings, fingerprint: Data, overwriteExisting: Bool = false
  ) {
    self.settings = settings
    self.fingerprint = fingerprint
    self.overwriteExisting = overwriteExisting
  }

  package func makeChapterEncoder(artifactURL: URL) throws -> any M4BChapterEncoding {
    try AACChapterEncoder(artifactURL: artifactURL, settings: settings, fingerprint: fingerprint)
  }

  package func validateArtifact(at url: URL) throws -> M4BChapterArtifact {
    try ChapterSegment.validate(url: url, settings: settings, fingerprint: fingerprint)
  }

  package func assemble(
    chapters: [(title: String, artifact: M4BChapterArtifact)],
    metadata: AudiobookMetadata,
    cover: PublicationCover?,
    to outputURL: URL,
    progress: (@Sendable (Double) -> Void)?
  ) throws {
    guard !chapters.isEmpty else { throw AudiobookAudioError.emptyChapter }
    let artifacts = chapters.map(\.artifact)
    guard Set(artifacts.map(\.audioSpecificConfig)).count == 1,
      Set(artifacts.map(\.framesPerPacket)).count == 1
    else {
      throw AudiobookAudioError.inconsistentAudioConfig
    }

    var packetSizes: [UInt32] = []
    for artifact in artifacts {
      packetSizes.append(contentsOf: try ChapterSegment.packetSizes(of: artifact))
    }

    let audio = M4BAudioTrackPlan(
      totalPackets: packetSizes.count,
      packetSizes: packetSizes,
      framesPerPacket: artifacts[0].framesPerPacket,
      sampleRate: settings.sampleRate,
      bitRate: settings.bitRate,
      audioSpecificConfig: artifacts[0].audioSpecificConfig,
      leadingFrames: artifacts[0].leadingFrames,
      trailingFrames: artifacts[artifacts.count - 1].trailingFrames,
      chapterPacketCounts: artifacts.map(\.packetCount))
    let chapterPlans = chapters.map { M4BChapterPlan(title: $0.title) }
    let metadataPlan = M4BMetadataPlan(
      title: metadata.title,
      author: metadata.author,
      narrator: metadata.narrator,
      writer: metadata.author,
      genre: metadata.genre,
      day: metadata.date,
      description: metadata.bookDescription,
      cover: cover.map(CoverPolicy.prepare))

    let offsets = OffsetPlanner.plan(audio: audio, chapters: chapterPlans)
    let moov = M4BMoovBuilder.build(
      audio: audio, chapters: chapterPlans, metadata: metadataPlan, offsets: offsets)
    let expectedFileSize = offsets.fileSizeExcludingMoov + UInt64(moov.count)

    let partialURL = outputURL.deletingLastPathComponent()
      .appendingPathComponent(".\(outputURL.lastPathComponent).\(UUID().uuidString).partial")
    FileManager.default.createFile(atPath: partialURL.path, contents: nil)
    let handle: FileHandle
    do {
      handle = try FileHandle(forWritingTo: partialURL)
    } catch {
      throw AudiobookAudioError.outputWriteFailed(partialURL, error.localizedDescription)
    }

    var closed = false
    defer {
      if !closed {
        try? handle.close()
        try? FileManager.default.removeItem(at: partialURL)
      }
    }

    var written: UInt64 = 0
    let totalToWrite = Double(expectedFileSize)
    func write(_ data: Data) throws {
      do {
        try handle.write(contentsOf: data)
      } catch {
        throw AudiobookAudioError.outputWriteFailed(partialURL, error.localizedDescription)
      }
      written += UInt64(data.count)
      progress?(min(1, Double(written) / totalToWrite))
    }

    try write(OffsetPlanner.ftyp())
    try write(offsets.mdatHeader)
    for plan in chapterPlans { try write(plan.samplePayload) }

    // Stream audio packets per chapter, batched to keep syscalls and memory
    // bounded (~1 MiB buffers). Assembly runs on the pipeline's producer
    // task, so honor its cancellation between chapters.
    for artifact in artifacts {
      try Task.checkCancellation()
      var batch = Data(capacity: 1 << 20)
      try ChapterSegment.forEachPacket(in: artifact) { packet in
        batch.append(packet)
        if batch.count >= 1 << 20 {
          try write(batch)
          batch.removeAll(keepingCapacity: true)
        }
      }
      if !batch.isEmpty { try write(batch) }
    }

    guard written == offsets.fileSizeExcludingMoov else {
      throw AudiobookAudioError.assemblySizeMismatch(
        expected: Int(offsets.fileSizeExcludingMoov), actual: Int(written))
    }
    try write(moov)
    guard written == expectedFileSize else {
      throw AudiobookAudioError.assemblySizeMismatch(
        expected: Int(expectedFileSize), actual: Int(written))
    }

    do {
      try handle.synchronize()
      try handle.close()
      closed = true
      let actualSize = try FileManager.default.attributesOfItem(atPath: partialURL.path)[.size]
        as? NSNumber
      guard actualSize?.uint64Value == expectedFileSize else {
        throw AudiobookAudioError.assemblySizeMismatch(
          expected: Int(expectedFileSize), actual: Int(actualSize?.uint64Value ?? 0))
      }
      if overwriteExisting {
        try DurableFileCommit.replace(outputURL, with: partialURL)
      } else {
        do {
          try DurableFileCommit.publishWithoutClobber(partialURL, to: outputURL)
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
          throw AudiobookAudioError.outputAlreadyExists(outputURL)
        }
      }
    } catch let error as AudiobookAudioError {
      try? FileManager.default.removeItem(at: partialURL)
      throw error
    } catch {
      try? FileManager.default.removeItem(at: partialURL)
      throw AudiobookAudioError.outputWriteFailed(outputURL, error.localizedDescription)
    }
  }
}

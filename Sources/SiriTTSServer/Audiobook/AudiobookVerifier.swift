import AVFoundation
import AudiobookKit
import Foundation

/// Reads an audiobook back through AVFoundation (the stack Apple Books uses)
/// plus a raw box walk for stik/pgap/chpl, and prints a human report. Used
/// by `audiobook verify` and the smoke script.
enum AudiobookVerifier {
  enum VerificationError: Error, LocalizedError {
    case invalid(String)
    var errorDescription: String? {
      if case .invalid(let message) = self { return "Audiobook verification failed: \(message)" }
      return nil
    }
  }

  static func printReport(for url: URL, decodeAudio: Bool = true) async throws {
    let asset = AVURLAsset(url: url)
    let duration = try await asset.load(.duration)
    print("File:      \(url.path)")
    print("Duration:  \(format(duration.seconds))")

    let metadata = try await asset.load(.metadata)
    func value(_ key: String) async -> String? {
      guard
        let identifier = AVMetadataItem.identifier(forKey: key, keySpace: .iTunes),
        let item = AVMetadataItem.metadataItems(
          from: metadata, filteredByIdentifier: identifier).first
      else { return nil }
      return try? await item.load(.stringValue)
    }
    if let title = await value("\u{A9}nam") { print("Title:     \(title)") }
    if let author = await value("\u{A9}alb") { print("Author:    \(author)") }
    if let narrator = await value("\u{A9}ART") { print("Narrator:  \(narrator)") }
    if let genre = await value("\u{A9}gen") { print("Genre:     \(genre)") }
    if let day = await value("\u{A9}day") { print("Date:      \(day)") }

    let coverIdentifier = AVMetadataItem.identifier(forKey: "covr", keySpace: .iTunes)
    if let coverIdentifier,
      let coverItem = AVMetadataItem.metadataItems(
        from: metadata, filteredByIdentifier: coverIdentifier).first,
      let coverData = try? await coverItem.load(.dataValue)
    {
      let kind = coverData.starts(with: [0xFF, 0xD8]) ? "JPEG" : "PNG"
      print("Cover:     \(coverData.count) bytes (\(kind))")
    } else {
      print("Cover:     none")
    }

    // Atoms AVFoundation does not expose. The file scanner seeks over mdat so
    // verification remains bounded even for multi-gigabyte books.
    guard let moov = try MP4FileReader.payload(ofTopLevelBox: "moov", at: url) else {
      throw VerificationError.invalid("missing moov box")
    }
    let stik = MP4BoxReader.box(at: ["udta", "meta", "ilst", "stik"], in: moov)
      .flatMap(MP4BoxReader.ilstValue)
    guard stik?.first == 2 else { throw VerificationError.invalid("missing stik=2") }
    print("stik:      2 (audiobook)")
    let pgap = MP4BoxReader.box(at: ["udta", "meta", "ilst", "pgap"], in: moov)
      .flatMap(MP4BoxReader.ilstValue)
    guard pgap?.first == 1 else { throw VerificationError.invalid("missing pgap=1") }
    print("pgap:      1 (gapless)")

    var nero = 0
    if let chpl = MP4BoxReader.box(at: ["udta", "chpl"], in: moov),
      chpl.payload.count > 8
    {
      nero = Int(chpl.payload[chpl.payload.startIndex + 8])
    }

    let locales = try await asset.load(.availableChapterLocales)
    var appleChapters: [(String, Double)] = []
    if let locale = locales.first {
      let groups = try await asset.loadChapterMetadataGroups(
        withTitleLocale: locale, containingItemsWithCommonKeys: [])
      for group in groups {
        let title = group.items.first(where: { $0.commonKey == .commonKeyTitle })
        let text = (try? await title?.load(.stringValue)) ?? nil
        appleChapters.append((text ?? "(untitled)", group.timeRange.start.seconds))
      }
    }
    guard !appleChapters.isEmpty else {
      throw VerificationError.invalid("Apple chapter track is missing or empty")
    }
    guard nero == min(255, appleChapters.count) else {
      throw VerificationError.invalid(
        "chapter systems disagree (Apple \(appleChapters.count), Nero \(nero))")
    }
    print("Chapters:  \(appleChapters.count) (Apple chapter track), \(nero) (Nero chpl)")
    for (index, chapter) in appleChapters.enumerated() {
      print(String(format: "  %3d  %@  %@", index + 1, format(chapter.1), chapter.0))
    }

    if decodeAudio {
      let file = try AVAudioFile(forReading: url)
      guard file.processingFormat.channelCount == 1,
        file.processingFormat.sampleRate == 48_000,
        let buffer = AVAudioPCMBuffer(
          pcmFormat: file.processingFormat, frameCapacity: 65_536)
      else { throw VerificationError.invalid("audio is not mono 48 kHz") }
      var decoded: AVAudioFramePosition = 0
      while file.framePosition < file.length {
        try file.read(into: buffer, frameCount: buffer.frameCapacity)
        guard buffer.frameLength > 0 else {
          throw VerificationError.invalid("decoder stopped before end of audio")
        }
        decoded += AVAudioFramePosition(buffer.frameLength)
      }
      guard decoded > 0 else { throw VerificationError.invalid("decoded audio is empty") }
      print("Decoded:   \(decoded) PCM frames (mono, 48000 Hz)")
    } else {
      print("Decoded:   skipped (--no-decode)")
    }
  }

  private static func format(_ seconds: Double) -> String {
    guard seconds.isFinite else { return "?" }
    let total = Int(seconds.rounded())
    return String(format: "%d:%02d:%02d", total / 3_600, (total / 60) % 60, total % 60)
  }
}

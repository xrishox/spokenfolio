import Foundation

package struct StalignTimelineEntry: Codable, Sendable, Equatable {
  package var type: String
  package var text: String
  package var startTime: Double
  package var endTime: Double
  package var startOffsetUtf16: Int
  package var endOffsetUtf16: Int
  package var startOffsetUtf32: Int
  package var endOffsetUtf32: Int
  package var confidence: Double?

  package init(
    type: String, text: String, startTime: Double, endTime: Double,
    startOffsetUtf16: Int = 0, endOffsetUtf16: Int = 0,
    startOffsetUtf32: Int = 0, endOffsetUtf32: Int = 0,
    confidence: Double? = nil
  ) {
    self.type = type
    self.text = text
    self.startTime = startTime
    self.endTime = endTime
    self.startOffsetUtf16 = startOffsetUtf16
    self.endOffsetUtf16 = endOffsetUtf16
    self.startOffsetUtf32 = startOffsetUtf32
    self.endOffsetUtf32 = endOffsetUtf32
    self.confidence = confidence
  }
}

package struct StalignTranscript: Codable, Sendable, Equatable {
  package var transcript: String
  package var timeline: [StalignTimelineEntry]

  package init(transcript: String, timeline: [StalignTimelineEntry]) {
    self.transcript = transcript
    self.timeline = timeline
  }

  package init(timedEntries: [StalignTimelineEntry]) {
    var text = ""
    var entries = timedEntries
    for index in entries.indices {
      if !text.isEmpty { text.append(" ") }
      entries[index].startOffsetUtf16 = text.utf16.count
      entries[index].startOffsetUtf32 = text.unicodeScalars.count
      text.append(entries[index].text)
      entries[index].endOffsetUtf16 = text.utf16.count
      entries[index].endOffsetUtf32 = text.unicodeScalars.count
    }
    transcript = text
    timeline = entries
  }
}

package enum StalignTranscriptValidator {
  package static let maximumFileSize = 16 << 20
  package static let maximumTrackCount = 4_096
  package static let durationTolerance = 1.0

  /// `enforceDurationCeiling` applies to transcripts this app authors (the
  /// Apple Speech adapter), where timing past the audio end means our adapter
  /// is broken. stalign's own Whisper transcripts legitimately overshoot the
  /// audio end (whisper.cpp segment tails; measured 20.9s past EOF on a
  /// healthy track), and stalign consumes its own output as-is — rejecting it
  /// would impose a stricter contract than the aligner itself uses, so
  /// stalign-produced transcripts validate structure only.
  package static func validate(
    _ value: StalignTranscript, audioDuration: Double,
    enforceDurationCeiling: Bool = true
  ) throws {
    guard audioDuration.isFinite, audioDuration >= 0 else {
      throw ReadAloudError.invalidArtifact("transcript audio duration is invalid")
    }
    guard value.transcript.isEmpty == value.timeline.isEmpty else {
      throw ReadAloudError.invalidArtifact("empty transcript and timeline do not agree")
    }
    var previousStart = 0.0
    var previousEnd = 0.0
    var previousUTF16 = 0
    var previousUTF32 = 0
    for entry in value.timeline {
      guard ["word", "segment"].contains(entry.type), !entry.text.isEmpty,
        entry.startTime.isFinite, entry.endTime.isFinite,
        entry.startTime >= -0.001, entry.endTime + 0.001 >= entry.startTime,
        entry.startTime + 0.001 >= previousStart, entry.endTime + 0.001 >= previousEnd,
        !enforceDurationCeiling || entry.endTime <= audioDuration + durationTolerance,
        entry.startOffsetUtf16 >= previousUTF16,
        entry.endOffsetUtf16 >= entry.startOffsetUtf16,
        entry.startOffsetUtf32 >= previousUTF32,
        entry.endOffsetUtf32 >= entry.startOffsetUtf32
      else { throw ReadAloudError.invalidArtifact("transcript timeline is not monotonic") }
      if let confidence = entry.confidence {
        guard confidence.isFinite, (0...1).contains(confidence) else {
          throw ReadAloudError.invalidArtifact("transcript confidence is invalid")
        }
      }
      guard sliceUTF16(
        value.transcript, entry.startOffsetUtf16, entry.endOffsetUtf16) == entry.text,
        sliceUTF32(value.transcript, entry.startOffsetUtf32, entry.endOffsetUtf32) == entry.text
      else { throw ReadAloudError.invalidArtifact("transcript offsets do not identify entry text") }
      previousStart = entry.startTime
      previousEnd = entry.endTime
      previousUTF16 = entry.endOffsetUtf16
      previousUTF32 = entry.endOffsetUtf32
    }
  }

  package static func decode(_ url: URL) throws -> StalignTranscript {
    let values = try url.resourceValues(forKeys: [
      .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
    ])
    guard values.isRegularFile == true, values.isSymbolicLink != true,
      let size = values.fileSize, size > 0, size <= maximumFileSize
    else { throw ReadAloudError.invalidArtifact("transcript is not a bounded regular file") }
    do {
      return try JSONDecoder().decode(
        StalignTranscript.self, from: Data(contentsOf: url, options: [.mappedIfSafe]))
    } catch {
      throw ReadAloudError.invalidArtifact("transcript JSON does not match the stalign schema")
    }
  }

  private static func sliceUTF16(_ text: String, _ lower: Int, _ upper: Int) -> String? {
    guard lower >= 0, upper >= lower,
      let start16 = text.utf16.index(text.utf16.startIndex, offsetBy: lower,
        limitedBy: text.utf16.endIndex),
      let end16 = text.utf16.index(text.utf16.startIndex, offsetBy: upper,
        limitedBy: text.utf16.endIndex),
      let start = start16.samePosition(in: text), let end = end16.samePosition(in: text)
    else { return nil }
    return String(text[start..<end])
  }

  private static func sliceUTF32(_ text: String, _ lower: Int, _ upper: Int) -> String? {
    let scalars = text.unicodeScalars
    guard lower >= 0, upper >= lower,
      let start32 = scalars.index(scalars.startIndex, offsetBy: lower, limitedBy: scalars.endIndex),
      let end32 = scalars.index(scalars.startIndex, offsetBy: upper, limitedBy: scalars.endIndex),
      let start = start32.samePosition(in: text), let end = end32.samePosition(in: text)
    else { return nil }
    return String(text[start..<end])
  }
}

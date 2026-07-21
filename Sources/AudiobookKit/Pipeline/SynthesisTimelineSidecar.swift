import Foundation

/// Assembles per-chapter synthesis timelines into the digest-bound sidecar
/// next to the finished M4B, rebasing chapter-relative frames onto the final
/// audiobook timeline with the same packet arithmetic the M4B chapter track
/// uses (prefix packet sums minus first-chapter encoder priming).
package enum SynthesisTimelineSidecar {
  package static let framesPerPacket = 1_024

  package static func write(
    jobKey: String,
    fingerprintHex: String,
    artifacts: [(title: String, artifact: M4BChapterArtifact)],
    artifactURLs: [URL],
    outputURL: URL,
    sampleRate: Int
  ) throws -> Double {
    var chapters: [BookSynthesisTimeline.Chapter] = []
    var covered = 0
    var startFrame = 0
    let leadingFrames = artifacts.first?.artifact.leadingFrames ?? 0
    for (index, entry) in artifacts.enumerated() {
      let presentedStart = max(0, startFrame - leadingFrames)
      let frames = entry.artifact.packetCount * framesPerPacket
      defer { startFrame += frames }
      let timelineURL = AudiobookSynthesizer.timelineURL(forArtifact: artifactURLs[index])
      guard let data = try? Data(contentsOf: timelineURL),
        let timeline = try? JSONDecoder().decode(ChapterSynthesisTimeline.self, from: data),
        timeline.artifactSHA256 == (try? ChapterSynthesisTimeline.sha256(of: artifactURLs[index]))
      else {
        // A reused chapter from a run that predates timelines, or a stale
        // timeline whose artifact changed: recorded as uncovered rather
        // than trusted.
        chapters.append(
          BookSynthesisTimeline.Chapter(
            index: index, title: entry.title, artifactSHA256: "",
            startFrame: presentedStart,
            presentedFrames: frames,
            leadingFrames: entry.artifact.leadingFrames,
            sourceDocuments: [],
            sentences: []))
        continue
      }
      covered += 1
      chapters.append(
        BookSynthesisTimeline.Chapter(
          index: index, title: entry.title,
          artifactSHA256: timeline.artifactSHA256,
          startFrame: presentedStart,
          presentedFrames: frames,
          leadingFrames: entry.artifact.leadingFrames,
          sourceDocuments: timeline.sourceDocuments,
          sentences: timeline.sentences))
    }
    let coverage = artifacts.isEmpty ? 0 : Double(covered) / Double(artifacts.count)
    let sidecar = BookSynthesisTimeline(
      jobKey: jobKey,
      fingerprint: fingerprintHex,
      m4bSHA256: try ChapterSynthesisTimeline.sha256(of: outputURL),
      sampleRate: sampleRate,
      timelineCoverage: coverage,
      chapters: chapters)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(sidecar)
      .write(to: BookSynthesisTimeline.sidecarURL(for: outputURL), options: .atomic)
    return coverage
  }
}

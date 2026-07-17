import DocumentIOKit
import Foundation

package enum ReadAloudVerifier {
  private static let maximumAudioCount = 4_096
  private static let maximumExtractedAudioBytes = ZIPArchive.Limits.readAloud.maximumTotalUncompressedSize

  package static func verifyPublished(
    epub: URL, ffprobe: URL,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) async throws -> ReadAloudVerificationReport {
    let archive = try validatedArchive(epub)
    let audioEntries = archive.entries.filter { $0.path.lowercased().hasSuffix(".mp4") }
    try validateAudioBounds(audioEntries)

    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent("readaloud-verify-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    var extracted: [String: URL] = [:]
    extracted.reserveCapacity(audioEntries.count)
    for (index, entry) in audioEntries.enumerated() {
      let url = temporary.appendingPathComponent("\(index).mp4")
      try archive.extract(entry, to: url)
      extracted[entry.path] = url
    }
    return try await verify(
      archive: archive, audioFilesByPath: extracted, ffprobe: ffprobe, environment: environment)
  }

  package static func verify(
    epub: URL, processedAudio: URL, ffprobe: URL,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) async throws -> ReadAloudVerificationReport {
    let archive = try validatedArchive(epub)
    let processed = try FileManager.default.contentsOfDirectory(
      at: processedAudio, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
    )
    .filter {
      $0.pathExtension.lowercased() == "mp4"
        && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }
    let audioEntries = archive.entries.filter { $0.path.lowercased().hasSuffix(".mp4") }
    guard processed.count == audioEntries.count else {
      throw ReadAloudError.invalidArtifact("processed and embedded audio counts do not match")
    }
    let processedByName = Dictionary(grouping: processed, by: \.lastPathComponent)
    var mapped: [String: URL] = [:]
    for entry in audioEntries {
      guard let matches = processedByName[URL(fileURLWithPath: entry.path).lastPathComponent],
        matches.count == 1, let file = matches.first
      else {
        throw ReadAloudError.invalidArtifact(
          "processed audio does not map uniquely to embedded audio")
      }
      mapped[entry.path] = file
    }
    return try await verify(
      archive: archive, audioFilesByPath: mapped, ffprobe: ffprobe, environment: environment)
  }

  private static func verify(
    archive: ZIPArchive, audioFilesByPath: [String: URL], ffprobe: URL,
    environment: [String: String]
  ) async throws -> ReadAloudVerificationReport {
    let smilEntries = archive.entries.filter { $0.path.lowercased().hasSuffix(".smil") }
    let audioEntries = archive.entries.filter { $0.path.lowercased().hasSuffix(".mp4") }
    guard !smilEntries.isEmpty, !audioEntries.isEmpty else {
      throw ReadAloudError.invalidArtifact("EPUB has no Media Overlays or embedded audio")
    }
    try validateAudioBounds(audioEntries)

    let audioPaths = Set(audioEntries.map(\.path))
    let publicationPaths = Set(archive.entries.map(\.path))
    var referencedAudio = Set<String>()
    var maxClipEnd: [String: Double] = [:]
    var textIdentifiers: [String: Set<String>] = [:]
    for entry in smilEntries {
      // Clip ordering is a per-overlay-document property. Audio tracks are
      // split by duration, not by chapter, so one track legitimately spans
      // several overlay documents — and archive entry order is lexicographic,
      // not narrative, so cross-document accumulation rejects healthy books
      // (measured: 1984's track 19 spans two chapters whose SMIL names
      // enumerate out of story order).
      var lastClipEndInDocument: [String: Double] = [:]
      let document: XMLDocument
      do {
        document = try BoundedXMLDocument.parse(
          archive.data(for: entry),
          limits: .init(
            maximumInputBytes: 8 << 20, maximumTidyInputBytes: 0,
            maximumDepth: 128, maximumNodes: 100_000,
            maximumAttributes: 250_000, maximumTextBytes: 8 << 20),
          allowTidy: false)
      } catch {
        throw ReadAloudError.invalidArtifact("invalid SMIL XML \(entry.path)")
      }
      let audioNodes = try document.nodes(forXPath: "//*[local-name()='audio']")
      // stalign emits an empty overlay document for a spine item where no
      // sentence aligned. That is a coverage question (the quality gate
      // judges unaligned sections), not a structural defect; an empty
      // overlay is functionally identical to no overlay, which is legal.
      if audioNodes.isEmpty { continue }
      for case let audio as XMLElement in audioNodes {
        guard let source = audio.attribute(forName: "src")?.stringValue,
          let beginText = audio.attribute(forName: "clipBegin")?.stringValue,
          let endText = audio.attribute(forName: "clipEnd")?.stringValue,
          let begin = clockSeconds(beginText), let end = clockSeconds(endText),
          begin >= 0, end > begin,
          let audioPath = resolveReference(source, relativeTo: entry.path),
          audioPaths.contains(audioPath)
        else { throw ReadAloudError.invalidArtifact("invalid audio clip in \(entry.path)") }
        if let previous = lastClipEndInDocument[audioPath], begin + 0.001 < previous {
          throw ReadAloudError.invalidArtifact("SMIL audio clips are out of order in \(entry.path)")
        }
        lastClipEndInDocument[audioPath] = end
        maxClipEnd[audioPath] = max(maxClipEnd[audioPath] ?? 0, end)
        referencedAudio.insert(audioPath)

        guard let parent = audio.parent as? XMLElement,
          let text = parent.children?.compactMap({ $0 as? XMLElement }).first(where: {
            $0.localName == "text" || $0.name == "text"
          }),
          let textSource = text.attribute(forName: "src")?.stringValue,
          let textPath = resolveReference(textSource, relativeTo: entry.path),
          publicationPaths.contains(textPath),
          let fragment = referenceFragment(textSource), !fragment.isEmpty
        else { throw ReadAloudError.invalidArtifact("audio clip has no valid text target") }
        let identifiers: Set<String>
        if let cached = textIdentifiers[textPath] {
          identifiers = cached
        } else {
          guard let textEntry = archive.entry(at: textPath) else {
            throw ReadAloudError.invalidArtifact("SMIL text target is missing")
          }
          let textDocument: XMLDocument
          do { textDocument = try BoundedXMLDocument.parse(archive.data(for: textEntry)) } catch {
            throw ReadAloudError.invalidArtifact("SMIL text target is invalid XML")
          }
          identifiers = Set(
            try textDocument.nodes(forXPath: "//*[@id]").compactMap {
              ($0 as? XMLElement)?.attribute(forName: "id")?.stringValue
            }.map(\.precomposedStringWithCanonicalMapping))
          textIdentifiers[textPath] = identifiers
        }
        guard identifiers.contains(fragment) else {
          throw ReadAloudError.invalidArtifact("SMIL text fragment is missing")
        }
      }
    }
    guard referencedAudio == audioPaths else {
      throw ReadAloudError.invalidArtifact("embedded audio and SMIL references do not match")
    }
    guard Set(audioFilesByPath.keys) == audioPaths else {
      throw ReadAloudError.invalidArtifact("embedded audio count does not match processed audio")
    }

    let runner = ExternalProcessRunner()
    var decoded = 0
    for entry in audioEntries {
      guard let file = audioFilesByPath[entry.path] else {
        throw ReadAloudError.invalidArtifact("embedded audio has no verification source")
      }
      let probe = try await runner.run(
        executable: ffprobe,
        arguments: [
          "-v", "error", "-select_streams", "a:0",
          "-show_entries", "stream=codec_name,sample_rate,channels,duration",
          "-of", "json", file.path,
        ], environment: environment, timeout: .seconds(60))
      guard probe.status == 0,
        let value = try? JSONSerialization.jsonObject(with: probe.stdout) as? [String: Any],
        let streams = value["streams"] as? [[String: Any]], streams.count == 1,
        let stream = streams.first,
        stream["codec_name"] as? String == "opus",
        String(describing: stream["sample_rate"] ?? "") == "48000",
        (1...2).contains(stream["channels"] as? Int ?? 0),
        let duration = Double(String(describing: stream["duration"] ?? "")), duration > 0
      else { throw ReadAloudError.invalidArtifact("embedded audio is not valid 48 kHz Opus") }
      if let clipEnd = maxClipEnd[entry.path], clipEnd > duration + 0.05 {
        throw ReadAloudError.invalidArtifact("SMIL clip exceeds embedded audio duration")
      }
      decoded += 1
    }
    return ReadAloudVerificationReport(
      entryCount: archive.entries.count, smilCount: smilEntries.count,
      audioCount: audioEntries.count, decodedAudioCount: decoded)
  }

  private static func validatedArchive(_ epub: URL) throws -> ZIPArchive {
    do {
      let archive = try ZIPArchive(url: epub, limits: .readAloud)
      guard archive.entry(at: "mimetype") != nil,
        archive.entry(at: "META-INF/container.xml") != nil
      else { throw ReadAloudError.invalidArtifact("EPUB container files are missing") }
      return archive
    } catch let error as ReadAloudError { throw error } catch {
      throw ReadAloudError.invalidArtifact("output is not a safe, readable EPUB ZIP")
    }
  }

  private static func validateAudioBounds(_ entries: [ZIPEntry]) throws {
    guard entries.count <= maximumAudioCount else {
      throw ReadAloudError.invalidArtifact("EPUB contains too many embedded audio files")
    }
    var total = 0
    for entry in entries {
      let (next, overflow) = total.addingReportingOverflow(entry.uncompressedSize)
      guard !overflow, next <= maximumExtractedAudioBytes else {
        throw ReadAloudError.invalidArtifact("embedded audio exceeds the verification limit")
      }
      total = next
    }
  }

  private static func resolveReference(_ source: String, relativeTo documentPath: String) -> String? {
    let pathAndFragment = source.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
    guard let rawPath = pathAndFragment.first, let decoded = String(rawPath).removingPercentEncoding,
      !decoded.isEmpty, !decoded.hasPrefix("/")
    else { return nil }
    var components = (documentPath as NSString).deletingLastPathComponent
      .split(separator: "/").map(String.init)
    for component in decoded.split(separator: "/", omittingEmptySubsequences: true) {
      switch component {
      case ".": continue
      case "..":
        guard !components.isEmpty else { return nil }
        components.removeLast()
      default: components.append(String(component))
      }
    }
    return components.joined(separator: "/").precomposedStringWithCanonicalMapping
  }

  private static func referenceFragment(_ source: String) -> String? {
    let parts = source.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2 else { return nil }
    return String(parts[1]).removingPercentEncoding?.precomposedStringWithCanonicalMapping
  }

  private static func clockSeconds(_ value: String) -> Double? {
    let text = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    func finite(_ value: Double?) -> Double? {
      guard let value, value.isFinite else { return nil }
      return value
    }
    if text.hasSuffix("ms") { return finite(Double(text.dropLast(2))).map { $0 / 1_000 } }
    if text.hasSuffix("s") { return finite(Double(text.dropLast())) }
    if text.hasSuffix("min") { return finite(Double(text.dropLast(3))).map { $0 * 60 } }
    if text.hasSuffix("h") { return finite(Double(text.dropLast())).map { $0 * 3_600 } }
    let parts = text.split(separator: ":", omittingEmptySubsequences: false)
    guard !parts.isEmpty, parts.count <= 3, parts.allSatisfy({ Double($0) != nil }) else {
      return nil
    }
    return finite(parts.reduce(0.0) { $0 * 60 + (Double($1) ?? 0) })
  }
}

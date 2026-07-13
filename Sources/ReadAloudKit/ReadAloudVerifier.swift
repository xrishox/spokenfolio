import Foundation

package enum ReadAloudVerifier {
  package static func verifyPublished(
    epub: URL, ffprobe: URL,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) async throws -> ReadAloudVerificationReport {
    // Validate every archive path before allowing unzip to materialize any entry. An EPUB is
    // user-controlled input, and wildcard extraction must never be able to traverse outside the
    // verification directory.
    _ = try await validatedEntries(in: epub, environment: environment)
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent("readaloud-verify-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    let runner = ExternalProcessRunner()
    let extracted = try await runner.run(
      executable: URL(fileURLWithPath: "/usr/bin/unzip"),
      arguments: ["-qq", epub.path, "*.mp4", "-d", temporary.path], environment: environment)
    guard extracted.status == 0 else {
      throw ReadAloudError.invalidArtifact("could not extract embedded audio for verification")
    }
    var audioDirectory = temporary
    let enumerator = FileManager.default.enumerator(at: temporary, includingPropertiesForKeys: nil)
    if let first = (enumerator?.allObjects as? [URL])?.first(where: {
      $0.pathExtension.lowercased() == "mp4"
    }) {
      audioDirectory = first.deletingLastPathComponent()
      // Flatten nested entries for the existing bounded verifier.
      let all =
        (FileManager.default.enumerator(at: temporary, includingPropertiesForKeys: nil)?.allObjects
          as? [URL]) ?? []
      for file in all
      where file.pathExtension.lowercased() == "mp4"
        && file.deletingLastPathComponent() != audioDirectory
      {
        let destination = audioDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        try FileManager.default.copyItem(at: file, to: destination)
      }
    }
    return try await verify(
      epub: epub, processedAudio: audioDirectory, ffprobe: ffprobe, environment: environment)
  }

  package static func verify(
    epub: URL, processedAudio: URL, ffprobe: URL,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) async throws -> ReadAloudVerificationReport {
    let runner = ExternalProcessRunner()
    let entries = try await validatedEntries(in: epub, environment: environment)
    let smil = entries.filter { $0.lowercased().hasSuffix(".smil") }
    let audio = entries.filter { $0.lowercased().hasSuffix(".mp4") }
    guard !smil.isEmpty, !audio.isEmpty else {
      throw ReadAloudError.invalidArtifact("EPUB has no Media Overlays or embedded audio")
    }
    var referencedAudio = Set<String>()
    for path in smil {
      let content = try await runner.run(
        executable: URL(fileURLWithPath: "/usr/bin/unzip"),
        arguments: ["-p", epub.path, path], environment: environment)
      guard content.status == 0 else {
        throw ReadAloudError.invalidArtifact("could not read SMIL document \(path)")
      }
      let document: XMLDocument
      do { document = try XMLDocument(data: content.stdout, options: [.nodeLoadExternalEntitiesNever]) }
      catch {
        throw ReadAloudError.invalidArtifact("invalid SMIL XML \(path)")
      }
      let nodes = try document.nodes(forXPath: "//*[local-name()='audio']")
      guard !nodes.isEmpty else {
        throw ReadAloudError.invalidArtifact("SMIL has no audio clips in \(path)")
      }
      for case let element as XMLElement in nodes {
        guard let source = element.attribute(forName: "src")?.stringValue,
          element.attribute(forName: "clipBegin")?.stringValue != nil,
          element.attribute(forName: "clipEnd")?.stringValue != nil,
          let rawPath = source.split(separator: "#", maxSplits: 1).first,
          let decoded = String(rawPath).removingPercentEncoding
        else { throw ReadAloudError.invalidArtifact("invalid audio clip in \(path)") }
        let base = (path as NSString).deletingLastPathComponent
        guard let resolved = resolveArchivePath(decoded, relativeTo: base),
          audio.contains(resolved)
        else {
          throw ReadAloudError.invalidArtifact("SMIL references missing audio in \(path)")
        }
        referencedAudio.insert(resolved)
      }
    }
    guard referencedAudio == Set(audio) else {
      throw ReadAloudError.invalidArtifact("embedded audio and SMIL references do not match")
    }

    let processed = try FileManager.default.contentsOfDirectory(
      at: processedAudio, includingPropertiesForKeys: nil
    )
    .filter { $0.pathExtension.lowercased() == "mp4" }
    guard processed.count == audio.count else {
      throw ReadAloudError.invalidArtifact("embedded audio count does not match processed audio")
    }
    var decoded = 0
    for file in processed {
      let probe = try await runner.run(
        executable: ffprobe,
        arguments: [
          "-v", "error", "-select_streams", "a:0",
          "-show_entries", "stream=codec_name,sample_rate,channels,duration",
          "-of", "json", file.path,
        ], environment: environment)
      guard probe.status == 0,
        let value = try? JSONSerialization.jsonObject(with: probe.stdout) as? [String: Any],
        let streams = value["streams"] as? [[String: Any]], let stream = streams.first,
        stream["codec_name"] as? String == "opus",
        String(describing: stream["sample_rate"] ?? "") == "48000",
        (stream["channels"] as? Int) == 1
      else { throw ReadAloudError.invalidArtifact("embedded audio is not valid 48 kHz mono Opus") }
      decoded += 1
    }
    return ReadAloudVerificationReport(
      entryCount: entries.count, smilCount: smil.count,
      audioCount: audio.count, decodedAudioCount: decoded)
  }

  private static func validatedEntries(
    in epub: URL, environment: [String: String]
  ) async throws -> [String] {
    let runner = ExternalProcessRunner()
    let listing = try await runner.run(
      executable: URL(fileURLWithPath: "/usr/bin/unzip"),
      arguments: ["-Z1", epub.path], environment: environment)
    guard listing.status == 0 else {
      throw ReadAloudError.invalidArtifact("output is not a readable EPUB ZIP")
    }
    let entries = String(decoding: listing.stdout, as: UTF8.self)
      .split(separator: "\n").map(String.init)
    guard entries.contains("mimetype"), entries.contains("META-INF/container.xml") else {
      throw ReadAloudError.invalidArtifact("EPUB container files are missing")
    }
    guard !entries.contains(where: { $0.hasPrefix("/") || $0.split(separator: "/").contains("..") })
    else {
      throw ReadAloudError.invalidArtifact("EPUB contains an unsafe path")
    }
    guard Set(entries).count == entries.count else {
      throw ReadAloudError.invalidArtifact("EPUB contains duplicate paths")
    }
    return entries
  }

  private static func resolveArchivePath(_ path: String, relativeTo base: String) -> String? {
    guard !path.hasPrefix("/") else { return nil }
    var components = base.split(separator: "/").map(String.init)
    for component in path.split(separator: "/", omittingEmptySubsequences: true) {
      switch component {
      case ".": continue
      case "..":
        guard !components.isEmpty else { return nil }
        components.removeLast()
      default: components.append(String(component))
      }
    }
    return components.joined(separator: "/")
  }
}

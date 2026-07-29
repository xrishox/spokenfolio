import CryptoKit
import Foundation

/// Digest proof that retained transcripts describe the exact processed audio
/// bytes embedded in a ReadAloud. It contains identities only—never book text,
/// transcript content, PCM, or credentials.
package struct TranscriptBindingManifest: Codable, Sendable, Equatable {
  package static let schemaVersion = 1
  package static let fileName = "transcript-binding.manifest"

  package struct Entry: Codable, Sendable, Equatable {
    package var audioFileName: String
    package var audioSHA256: String
    package var transcriptFileName: String
    package var transcriptSHA256: String
  }

  package var schemaVersion: Int
  package var sourceAudiobookSHA256: String
  package var transcriptionFingerprint: String
  package var entries: [Entry]

  package static func write(
    processedAudio: URL, transcriptions: URL,
    sourceAudiobookSHA256: String, transcriptionFingerprint: String
  ) throws {
    let tracks = try regularFiles(in: processedAudio, extension: "mp4")
    let transcripts = try regularFiles(in: transcriptions, extension: "json")
    var transcriptsByStem: [String: URL] = [:]
    for transcript in transcripts {
      let stem = (transcript.lastPathComponent as NSString).deletingPathExtension
      guard transcriptsByStem.updateValue(transcript, forKey: stem) == nil else {
        throw ReadAloudError.invalidArtifact(
          "duplicate transcript stems cannot be digest-bound")
      }
    }
    let entries = try tracks.map { track -> Entry in
      let stem = (track.lastPathComponent as NSString).deletingPathExtension
      guard let transcript = transcriptsByStem[stem] else {
        throw ReadAloudError.invalidArtifact(
          "processed audio has no digest-bound transcript")
      }
      return Entry(
        audioFileName: track.lastPathComponent, audioSHA256: try sha256(track),
        transcriptFileName: transcript.lastPathComponent,
        transcriptSHA256: try sha256(transcript))
    }
    guard entries.count == transcripts.count, !entries.isEmpty else {
      throw ReadAloudError.invalidArtifact(
        "processed audio and transcript binding counts do not match")
    }
    let manifest = TranscriptBindingManifest(
      schemaVersion: schemaVersion,
      sourceAudiobookSHA256: sourceAudiobookSHA256,
      transcriptionFingerprint: transcriptionFingerprint,
      entries: entries)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(manifest).write(
      to: transcriptions.appendingPathComponent(fileName), options: .atomic)
  }

  package static func validate(
    transcriptions: URL, inspection: ReadAloudInspection
  ) throws {
    let url = transcriptions.appendingPathComponent(fileName)
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values.isRegularFile == true, let size = values.fileSize,
      size > 0, size <= 1 << 20
    else {
      throw ReadAloudError.invalidArtifact(
        "retained transcripts have no bounded audio-binding manifest")
    }
    let manifest = try JSONDecoder().decode(
      TranscriptBindingManifest.self, from: Data(contentsOf: url))
    guard manifest.schemaVersion == schemaVersion,
      isSHA256(manifest.sourceAudiobookSHA256),
      !manifest.transcriptionFingerprint.isEmpty,
      manifest.transcriptionFingerprint.utf8.count <= 4_096,
      manifest.entries.count == inspection.audio.count,
      manifest.entries.count <= 4_096,
      manifest.entries.allSatisfy({
        isSHA256($0.audioSHA256) && isSHA256($0.transcriptSHA256)
      }),
      Set(manifest.entries.map(\.audioFileName)).count == manifest.entries.count,
      Set(manifest.entries.map(\.transcriptFileName)).count == manifest.entries.count
    else {
      throw ReadAloudError.invalidArtifact("transcript audio binding is invalid")
    }

    let byAudio = Dictionary(uniqueKeysWithValues: manifest.entries.map { ($0.audioFileName, $0) })
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
      "readaloud-binding-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    for (index, member) in inspection.audio.enumerated() {
      let name = URL(fileURLWithPath: member.path).lastPathComponent
      guard let entry = byAudio[name] else {
        throw ReadAloudError.invalidArtifact(
          "embedded audio is absent from the transcript binding")
      }
      let extracted = temporary.appendingPathComponent("\(index).mp4")
      try inspection.archive.extract(member.entry, to: extracted)
      guard try sha256(extracted) == entry.audioSHA256 else {
        throw ReadAloudError.invalidArtifact(
          "embedded audio does not match the bound transcript")
      }
      let transcript = transcriptions.appendingPathComponent(entry.transcriptFileName)
      guard try sha256(transcript) == entry.transcriptSHA256 else {
        throw ReadAloudError.invalidArtifact(
          "a retained transcript changed after it was bound")
      }
    }
  }

  private static func regularFiles(in directory: URL, extension ext: String) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: [.isRegularFileKey]
    ).filter {
      $0.pathExtension.lowercased() == ext
        && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }.sorted { $0.lastPathComponent < $1.lastPathComponent }
  }

  private static func sha256(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let data = try handle.read(upToCount: 4 << 20), !data.isEmpty {
      hasher.update(data: data)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private static func isSHA256(_ value: String) -> Bool {
    value.utf8.count == 64 && value.utf8.allSatisfy {
      (48...57).contains($0) || (97...102).contains($0)
    }
  }
}

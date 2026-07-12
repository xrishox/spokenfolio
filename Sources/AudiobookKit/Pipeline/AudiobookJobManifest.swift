import CryptoKit
import Darwin
import Foundation
import SiriTTSCore

/// Everything that determines an audiobook's content. The job key derived
/// from these inputs names the work directory, so artifacts can only ever be
/// reused by an identical run.
package struct AudiobookJobInputs: Codable, Sendable, Equatable {
  package var epubSHA256: String
  package var voiceID: String
  package var voiceVersion: Int
  package var bitRate: Int
  /// "spineIndex:slug" for every effectively included section, sorted.
  package var includedSections: [String]
  package var paragraphPauseMs: Int
  package var chapterPauseMs: Int
  package var announceTitles: Bool
  package var maxChapters: Int?
  package var engine: String
  package var formatIdentifier: String
  package var extractorVersion: Int
  package var synthesisPolicyVersion: Int

  package init(
    epubSHA256: String, voiceID: String, voiceVersion: Int = 0, bitRate: Int,
    includedSections: [String],
    paragraphPauseMs: Int, chapterPauseMs: Int, announceTitles: Bool, maxChapters: Int?,
    formatIdentifier: String
  ) {
    self.epubSHA256 = epubSHA256
    self.voiceID = voiceID
    self.voiceVersion = voiceVersion
    self.bitRate = bitRate
    self.includedSections = includedSections.sorted()
    self.paragraphPauseMs = paragraphPauseMs
    self.chapterPauseMs = chapterPauseMs
    self.announceTitles = announceTitles
    self.maxChapters = maxChapters
    engine = "siri"
    self.formatIdentifier = formatIdentifier
    extractorVersion = AudiobookKitInfo.extractorVersion
    synthesisPolicyVersion = NarrationUnitPlanner.synthesisPolicyVersion
  }

  /// Full 32-byte digest of the canonical (sorted-keys) JSON encoding;
  /// artifacts embed it, and the job key is its first 16 bytes.
  package var fingerprint: Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let canonical = (try? encoder.encode(self)) ?? Data()
    return Data(SHA256.hash(data: canonical))
  }

  package var jobKey: String {
    fingerprint.prefix(16).map { String(format: "%02x", $0) }.joined()
  }

  package static func hashEPUB(at url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
      hasher.update(data: chunk)
    }
    return Data(hasher.finalize()).map { String(format: "%02x", $0) }.joined()
  }
}

package enum AudiobookJobError: Error, LocalizedError {
  case workDirectoryUnavailable(URL, String)
  case alreadyRunning(URL)

  package var errorDescription: String? {
    switch self {
    case .workDirectoryUnavailable(let url, let reason):
      "Could not use the work directory '\(url.path)': \(reason)"
    case .alreadyRunning(let url):
      "An identical audiobook job is already using '\(url.path)'."
    }
  }
}

private final class AudiobookJobLease: @unchecked Sendable {
  private let descriptor: Int32

  init(directory: URL) throws {
    let lockURL = directory.appendingPathComponent(".job.lock")
    descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else {
      throw AudiobookJobError.workDirectoryUnavailable(directory, "could not open job lock")
    }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      Darwin.close(descriptor)
      throw AudiobookJobError.alreadyRunning(directory)
    }
  }

  deinit {
    _ = flock(descriptor, LOCK_UN)
    Darwin.close(descriptor)
  }
}

/// The per-run work directory: completed chapter artifacts plus a manifest
/// that is rewritten atomically after every chapter, making resume crash-safe.
package struct AudiobookJob: Sendable {
  package struct ChapterRecord: Codable, Sendable, Equatable {
    package let index: Int
    package let title: String
    package let artifactFileName: String
  }

  struct Manifest: Codable, Sendable {
    var schemaVersion: Int
    var jobKey: String
    var inputs: AudiobookJobInputs
    var chapters: [ChapterRecord]
  }

  package let directory: URL
  package let inputs: AudiobookJobInputs
  private var manifest: Manifest
  private let manifestURL: URL
  private let lease: AudiobookJobLease

  package static func defaultWorkRoot() -> URL {
    AppPaths.applicationSupportDirectory.appendingPathComponent(
      "audiobook-jobs", isDirectory: true)
  }

  /// Opens (or restarts, with `force`) the work directory for these inputs.
  /// A manifest from a different job key — only possible through manual
  /// tampering, since the key names the directory — is discarded.
  package static func open(
    inputs: AudiobookJobInputs, workRoot: URL? = nil, force: Bool = false
  ) throws -> AudiobookJob {
    let root = workRoot ?? defaultWorkRoot()
    let directory = root.appendingPathComponent(inputs.jobKey, isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    } catch {
      throw AudiobookJobError.workDirectoryUnavailable(directory, error.localizedDescription)
    }
    let lease = try AudiobookJobLease(directory: directory)
    if force {
      do {
        for item in try FileManager.default.contentsOfDirectory(
          at: directory, includingPropertiesForKeys: nil)
        where item.lastPathComponent != ".job.lock"
        {
          try FileManager.default.removeItem(at: item)
        }
      } catch {
        throw AudiobookJobError.workDirectoryUnavailable(directory, error.localizedDescription)
      }
    }

    let manifestURL = directory.appendingPathComponent("manifest.json")
    var manifest = Manifest(
      schemaVersion: 1, jobKey: inputs.jobKey, inputs: inputs, chapters: [])
    if let data = try? Data(contentsOf: manifestURL),
      let existing = try? JSONDecoder().decode(Manifest.self, from: data),
      existing.schemaVersion == 1, existing.jobKey == inputs.jobKey, existing.inputs == inputs
    {
      manifest = existing
    }
    return AudiobookJob(
      directory: directory, inputs: inputs, manifest: manifest, manifestURL: manifestURL,
      lease: lease)
  }

  package func artifactURL(chapterIndex: Int) -> URL {
    directory.appendingPathComponent(String(format: "chapter-%04d.aacseg", chapterIndex))
  }

  /// A completed chapter from a previous run, re-validated before reuse.
  package func validatedArtifact(
    chapterIndex: Int, title: String, writer: any AudiobookFormatWriter
  ) -> ChapterArtifact? {
    guard
      manifest.chapters.contains(where: {
        $0.index == chapterIndex && $0.title == title
      })
    else { return nil }
    return try? writer.validateArtifact(at: artifactURL(chapterIndex: chapterIndex))
  }

  package mutating func recordCompleted(chapterIndex: Int, title: String) throws {
    manifest.chapters.removeAll(where: { $0.index == chapterIndex })
    manifest.chapters.append(
      ChapterRecord(
        index: chapterIndex,
        title: title,
        artifactFileName: artifactURL(chapterIndex: chapterIndex).lastPathComponent))
    manifest.chapters.sort { $0.index < $1.index }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(manifest)
    let temporary = manifestURL.appendingPathExtension("tmp")
    do {
      try data.write(to: temporary, options: [])
      try DurableFileCommit.synchronizeFile(at: temporary)
      try DurableFileCommit.replace(manifestURL, with: temporary)
    } catch {
      try? FileManager.default.removeItem(at: temporary)
      throw AudiobookJobError.workDirectoryUnavailable(directory, error.localizedDescription)
    }
  }

  package func removeWorkDirectory() {
    try? FileManager.default.removeItem(at: directory)
  }
}

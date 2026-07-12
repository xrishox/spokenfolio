import Foundation

package struct AACEncodingSettings: Sendable, Equatable, Codable {
  package static let allowedBitRates = [32_000, 64_000, 128_000, 256_000]
  package static let defaultBitRate = 256_000

  package var bitRate: Int
  package var sampleRate: Int
  package var channels: Int

  package init(bitRate: Int = Self.defaultBitRate, sampleRate: Int = 48_000, channels: Int = 1) {
    self.bitRate = bitRate
    self.sampleRate = sampleRate
    self.channels = channels
  }
}

/// Book-level metadata destined for the container's tag atoms.
package struct AudiobookMetadata: Sendable, Equatable {
  package var title: String
  package var author: String?
  /// The Siri voice display name.
  package var narrator: String?
  package var genre: String?
  package var date: String?
  package var bookDescription: String?

  package init(
    title: String, author: String? = nil, narrator: String? = nil,
    genre: String? = nil, date: String? = nil, bookDescription: String? = nil
  ) {
    self.title = title
    self.author = author
    self.narrator = narrator
    self.genre = genre
    self.date = date
    self.bookDescription = bookDescription
  }
}

/// A completed, validated per-chapter encoded segment in the work directory.
package struct ChapterArtifact: Sendable, Equatable {
  package let url: URL
  package let packetCount: Int
  package let framesPerPacket: Int
  package let leadingFrames: Int
  package let trailingFrames: Int
  package let payloadByteCount: Int
  package let audioSpecificConfig: Data

  package var totalFrames: Int { packetCount * framesPerPacket }
}

/// Encodes one chapter's PCM incrementally into an artifact file. Confine an
/// instance to one task; it is not thread-safe.
package protocol ChapterAudioEncoding: AnyObject {
  /// Append PCM16-LE mono chunks of any size.
  func append(pcm16: Data) throws
  /// Drain the encoder, finalize the artifact atomically, and describe it.
  func finish() throws -> ChapterArtifact
  /// Delete any partial output. Safe to call after a failure.
  func cancel()
}

/// One audiobook container format. The M4B/AAC writer is the only
/// implementation today; a future container implements this protocol and
/// plugs into the same pipeline.
package protocol AudiobookFormatWriter: Sendable {
  /// Stable identity that participates in the resume job key: artifacts from
  /// one format/version are never reused by another.
  var formatIdentifier: String { get }
  var fileExtension: String { get }

  func makeChapterEncoder(artifactURL: URL) throws -> any ChapterAudioEncoding

  /// Re-validate an artifact left by a previous run before reusing it.
  func validateArtifact(at url: URL) throws -> ChapterArtifact

  /// Assemble ordered chapters into the final audiobook file. The output
  /// appears at `outputURL` only after it is complete and verified.
  func assemble(
    chapters: [(title: String, artifact: ChapterArtifact)],
    metadata: AudiobookMetadata,
    cover: EPUBCover?,
    to outputURL: URL,
    progress: (@Sendable (Double) -> Void)?
  ) throws
}

package enum AudiobookAudioError: Error, LocalizedError {
  case bitRateNotSupported(requested: Int, applicable: [Int])
  case encoderUnavailable
  case misalignedPCM
  case emptyChapter
  case converterFailed(String)
  case artifactIO(URL, String)
  case artifactCorrupt(URL, reason: String)
  case artifactSettingsMismatch(URL)
  case inconsistentAudioConfig
  case assemblySizeMismatch(expected: Int, actual: Int)
  case outputWriteFailed(URL, String)
  case outputAlreadyExists(URL)

  package var errorDescription: String? {
    switch self {
    case .bitRateNotSupported(let requested, let applicable):
      "The AAC encoder does not support \(requested / 1000) kbps for this format "
        + "(supported: \(applicable.map { String($0 / 1000) }.joined(separator: ", ")) kbps)."
    case .encoderUnavailable:
      "No AAC encoder is available for 48 kHz mono input."
    case .misalignedPCM:
      "PCM16 data must contain a whole number of 16-bit samples."
    case .emptyChapter:
      "A chapter produced no audio."
    case .converterFailed(let message):
      "AAC encoding failed: \(message)"
    case .artifactIO(let url, let message):
      "Could not access chapter artifact '\(url.lastPathComponent)': \(message)"
    case .artifactCorrupt(let url, let reason):
      "Chapter artifact '\(url.lastPathComponent)' is unusable (\(reason)); it will be re-synthesized."
    case .artifactSettingsMismatch(let url):
      "Chapter artifact '\(url.lastPathComponent)' was made with different settings; it will be re-synthesized."
    case .inconsistentAudioConfig:
      "Chapters were encoded with inconsistent audio configurations."
    case .assemblySizeMismatch(let expected, let actual):
      "Audiobook assembly wrote \(actual) bytes where \(expected) were planned; the output was discarded."
    case .outputWriteFailed(let url, let message):
      "Could not write '\(url.path)': \(message)"
    case .outputAlreadyExists(let url):
      "The output '\(url.path)' appeared while synthesis was running; it was not replaced. Re-run with --overwrite to replace it."
    }
  }
}

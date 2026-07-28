import Foundation
import TTSKit

package enum AudiobookProgressEvent: Sendable, Equatable {
  /// `chapterCharacters` carries the plan's per-chapter character counts so
  /// a consumer in another process can weight partial-chapter progress
  /// without re-planning the book.
  case started(
    totalChapters: Int, totalCharacters: Int, reusedChapters: Int,
    chapterCharacters: [Int], runtimeProvenance: TTSRuntimeProvenance)
  case chapterStarted(index: Int, title: String)
  case unitCompleted(chapterIndex: Int, completed: Int, total: Int)
  case chapterCompleted(index: Int, title: String, reused: Bool)
  case assemblyStarted
  case finished(outputURL: URL)
  case warning(String)
}

/// Machine-readable form of `AudiobookProgressEvent`: one JSON object per
/// line on stdout under `audiobook create --progress ndjson`. The desktop
/// GUI runs jobs by spawning that command and decoding this stream, so the
/// GUI and CLI execute the exact same pipeline.
package struct ProgressEventWire: Codable, Sendable {
  package enum Kind: String, Codable, Sendable {
    case started, chapterStarted, unitCompleted, chapterCompleted
    case assemblyStarted, finished, warning
  }

  package var type: Kind
  package var totalChapters: Int?
  package var totalCharacters: Int?
  package var reusedChapters: Int?
  package var chapterCharacters: [Int]?
  package var runtimeProvenance: TTSRuntimeProvenance?
  package var index: Int?
  package var chapterIndex: Int?
  package var title: String?
  package var completed: Int?
  package var total: Int?
  package var reused: Bool?
  package var outputPath: String?
  package var message: String?

  package init(_ event: AudiobookProgressEvent) {
    switch event {
    case .started(
      let totalChapters, let totalCharacters, let reused, let characters, let provenance):
      type = .started
      self.totalChapters = totalChapters
      self.totalCharacters = totalCharacters
      reusedChapters = reused
      chapterCharacters = characters
      runtimeProvenance = provenance
    case .chapterStarted(let index, let title):
      type = .chapterStarted
      self.index = index
      self.title = title
    case .unitCompleted(let chapterIndex, let completed, let total):
      type = .unitCompleted
      self.chapterIndex = chapterIndex
      self.completed = completed
      self.total = total
    case .chapterCompleted(let index, let title, let reused):
      type = .chapterCompleted
      self.index = index
      self.title = title
      self.reused = reused
    case .assemblyStarted:
      type = .assemblyStarted
    case .finished(let outputURL):
      type = .finished
      outputPath = outputURL.path
    case .warning(let message):
      type = .warning
      self.message = message
    }
  }

  /// Nil when required fields for the tagged case are missing — the reader
  /// treats that as a protocol violation, never as a silently dropped event.
  package func event() -> AudiobookProgressEvent? {
    switch type {
    case .started:
      guard let totalChapters, let totalCharacters, let reusedChapters,
        let runtimeProvenance
      else { return nil }
      return .started(
        totalChapters: totalChapters, totalCharacters: totalCharacters,
        reusedChapters: reusedChapters, chapterCharacters: chapterCharacters ?? [],
        runtimeProvenance: runtimeProvenance)
    case .chapterStarted:
      guard let index, let title else { return nil }
      return .chapterStarted(index: index, title: title)
    case .unitCompleted:
      guard let chapterIndex, let completed, let total else { return nil }
      return .unitCompleted(chapterIndex: chapterIndex, completed: completed, total: total)
    case .chapterCompleted:
      guard let index, let title, let reused else { return nil }
      return .chapterCompleted(index: index, title: title, reused: reused)
    case .assemblyStarted:
      return .assemblyStarted
    case .finished:
      guard let outputPath else { return nil }
      return .finished(outputURL: URL(fileURLWithPath: outputPath))
    case .warning:
      guard let message else { return nil }
      return .warning(message)
    }
  }
}

/// A synthesis failure annotated with its position; completed chapters stay
/// durable in the work directory, so the guidance is always "re-run to
/// resume".
package struct AudiobookRunError: Error, LocalizedError {
  package let chapterIndex: Int
  package let chapterTitle: String
  package let unit: Int?
  package let underlying: any Error

  package var errorDescription: String? {
    let location =
      unit.map { "chapter \(chapterIndex + 1) (\(chapterTitle)), paragraph \($0 + 1)" }
      ?? "chapter \(chapterIndex + 1) (\(chapterTitle))"
    let reason = (underlying as? LocalizedError)?.errorDescription
      ?? String(describing: underlying)
    return "\(location): \(reason) — completed chapters are saved; re-run the same command to resume."
  }
}

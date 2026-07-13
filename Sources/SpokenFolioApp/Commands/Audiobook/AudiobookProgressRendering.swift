import ArgumentParser
import AudiobookKit
import Darwin
import Foundation

enum ProgressFormat: String, ExpressibleByArgument, CaseIterable {
  case human
  case ndjson
}
protocol ProgressSink: Sendable {
  func render(_ event: AudiobookProgressEvent)
  func finishLine()
}

/// `--progress ndjson`: one JSON object per event on stdout, written
/// line-atomically. Everything human-readable stays on stderr, so a parent
/// process can decode stdout unconditionally.
final class NDJSONProgressWriter: ProgressSink, @unchecked Sendable {
  private let lock = NSLock()
  private let output: FileHandle
  private let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }()
  private var outputAvailable = true

  init(output: FileHandle = .standardOutput) {
    self.output = output
  }

  func render(_ event: AudiobookProgressEvent) {
    lock.withLock {
      guard outputAvailable else { return }
      guard var data = try? encoder.encode(ProgressEventWire(event)) else { return }
      data = Self.escapingUnicodeLineBreaks(data)
      data.append(UInt8(ascii: "\n"))
      do {
        try output.write(contentsOf: data)
      } catch {
        // A GUI crash closes stdout. Progress is optional; synthesis must
        // continue so the isolated child can finish or leave resumable work.
        outputAvailable = false
      }
    }
  }

  func finishLine() {}

  /// JSONEncoder leaves U+2028/U+2029/U+0085 as raw UTF-8 even though
  /// line-oriented readers treat them as breaks. Escaping byte-wise is safe:
  /// UTF-8 is self-synchronizing, so these sequences cannot occur inside any
  /// other scalar's encoding.
  static func escapingUnicodeLineBreaks(_ data: Data) -> Data {
    let replacements: [(sequence: [UInt8], escape: [UInt8])] = [
      ([0xE2, 0x80, 0xA8], Array("\\u2028".utf8)),
      ([0xE2, 0x80, 0xA9], Array("\\u2029".utf8)),
      ([0xC2, 0x85], Array("\\u0085".utf8)),
    ]
    guard replacements.contains(where: { data.range(of: Data($0.sequence)) != nil }) else {
      return data
    }
    var result = Data(capacity: data.count + 16)
    var index = data.startIndex
    outer: while index < data.endIndex {
      for (sequence, escape) in replacements {
        if data.count - data.distance(from: data.startIndex, to: index) >= sequence.count,
          data[index..<data.index(index, offsetBy: sequence.count)].elementsEqual(sequence)
        {
          result.append(contentsOf: escape)
          index = data.index(index, offsetBy: sequence.count)
          continue outer
        }
      }
      result.append(data[index])
      index = data.index(after: index)
    }
    return result
  }
}

/// One-line TTY progress bar, or one line per event when piped/quiet.
final class ProgressRenderer: ProgressSink, @unchecked Sendable {
  private let lock = NSLock()
  private let quiet: Bool
  private let isTTY = isatty(STDERR_FILENO) == 1
  private let totalCharacters: Int
  private let chapterCharacters: [Int]
  private let startedAt = Date()
  private var completedCharacters = 0
  private var currentChapterUnitsDone = 0
  private var currentChapterUnitsTotal = 0
  private var currentChapterIndex = 0
  private var wroteBar = false

  init(plan: AudiobookPlan, quiet: Bool) {
    self.quiet = quiet
    chapterCharacters = plan.chapters.map(\.characterCount)
    totalCharacters = plan.totalCharacterCount
  }

  func render(_ event: AudiobookProgressEvent) {
    guard !quiet else { return }
    lock.withLock {
      switch event {
      case .started(let chapters, _, let reused, _):
        line("Synthesizing \(chapters) chapters (\(reused) already complete)")
      case .chapterStarted(let index, let title):
        currentChapterIndex = index
        currentChapterUnitsDone = 0
        currentChapterUnitsTotal = 0
        if !isTTY { line("chapter \(index + 1): \(title)") }
      case .unitCompleted(let index, let done, let total):
        currentChapterIndex = index
        currentChapterUnitsDone = done
        currentChapterUnitsTotal = total
        drawBar()
      case .chapterCompleted(let index, let title, let reused):
        completedCharacters += chapterCharacters.indices.contains(index)
          ? chapterCharacters[index] : 0
        currentChapterUnitsDone = 0
        currentChapterUnitsTotal = 0
        if !isTTY || reused {
          line("chapter \(index + 1) \(reused ? "reused" : "done"): \(title)")
        } else {
          drawBar()
        }
      case .assemblyStarted:
        line("Assembling audiobook…")
      case .finished:
        break
      case .warning(let message):
        line("warning: \(message)")
      }
    }
  }

  private func drawBar() {
    guard isTTY else { return }
    var done = Double(completedCharacters)
    if currentChapterUnitsTotal > 0, chapterCharacters.indices.contains(currentChapterIndex) {
      done += Double(chapterCharacters[currentChapterIndex])
        * Double(currentChapterUnitsDone) / Double(currentChapterUnitsTotal)
    }
    let fraction = totalCharacters > 0 ? min(1, done / Double(totalCharacters)) : 0
    let elapsed = Date().timeIntervalSince(startedAt)
    let eta = fraction > 0.01 ? elapsed / fraction - elapsed : .nan
    let barWidth = 24
    let filled = Int(fraction * Double(barWidth))
    let bar = String(repeating: "█", count: filled)
      + String(repeating: "░", count: barWidth - filled)
    let text = String(
      format: "\rChapter %d/%d %@ %3.0f%% | elapsed %@ | ETA %@   ",
      currentChapterIndex + 1, chapterCharacters.count, bar, fraction * 100,
      Self.clock(elapsed), eta.isNaN ? "--:--" : Self.clock(eta))
    FileHandle.standardError.write(Data(text.utf8))
    wroteBar = true
  }

  /// Callable from outside `render` only — `line`/`drawBar` already run
  /// inside the lock, and NSLock does not recurse.
  func finishLine() {
    lock.withLock {
      if wroteBar {
        FileHandle.standardError.write(Data("\n".utf8))
        wroteBar = false
      }
    }
  }

  private func line(_ text: String) {
    if wroteBar {
      FileHandle.standardError.write(Data("\n".utf8))
      wroteBar = false
    }
    FileHandle.standardError.write(Data((text + "\n").utf8))
  }

  private static func clock(_ interval: TimeInterval) -> String {
    let seconds = max(0, Int(interval))
    if seconds >= 3_600 {
      return String(format: "%d:%02d:%02d", seconds / 3_600, (seconds / 60) % 60, seconds % 60)
    }
    return String(format: "%02d:%02d", seconds / 60, seconds % 60)
  }
}

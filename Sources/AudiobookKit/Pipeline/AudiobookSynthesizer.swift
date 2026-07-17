import Foundation
import PublicationKit
import TTSKit

package struct SynthesisSettings: Sendable {
  /// Voice display name, written as the audiobook narrator.
  package var narratorName: String
  package var maxWorkers: Int
  package var paragraphPauseSeconds: Double
  package var chapterPauseSeconds: Double
  /// Fixed head pad; also masks AAC encoder priming at chapter joins.
  package var headPauseSeconds: Double
  package var sampleRate: Int

  package init(
    narratorName: String, maxWorkers: Int = 4,
    paragraphPauseSeconds: Double = 0.6, chapterPauseSeconds: Double = 1.75,
    headPauseSeconds: Double = 0.25, sampleRate: Int = 48_000
  ) {
    self.narratorName = narratorName
    self.maxWorkers = maxWorkers
    self.paragraphPauseSeconds = paragraphPauseSeconds
    self.chapterPauseSeconds = chapterPauseSeconds
    self.headPauseSeconds = headPauseSeconds
    self.sampleRate = sampleRate
  }
}

/// Drives a whole book: per chapter, sentences fan out to the synthesis pool
/// with a bounded window, PCM is re-ordered back into source order and
/// streamed straight into the chapter encoder, and completed chapters land
/// in the job's work directory. Only the in-flight window of sentence PCM is
/// ever resident.
package struct AudiobookSynthesizer: Sendable {
  private let sentences: any NarrationSynthesizing
  private let writer: any M4BWriting
  private let settings: SynthesisSettings

  package init(
    sentences: any NarrationSynthesizing,
    writer: any M4BWriting,
    settings: SynthesisSettings
  ) {
    self.sentences = sentences
    self.writer = writer
    self.settings = settings
  }

  package func run(
    plan: AudiobookPlan, job: AudiobookJob, outputURL: URL
  ) -> AsyncThrowingStream<AudiobookProgressEvent, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          try await runBook(
            plan: plan, job: job, outputURL: outputURL, continuation: continuation)
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  private func runBook(
    plan: AudiobookPlan,
    job: AudiobookJob,
    outputURL: URL,
    continuation: AsyncThrowingStream<AudiobookProgressEvent, Error>.Continuation
  ) async throws {
    var job = job
    for warning in plan.warnings { continuation.yield(.warning(warning)) }

    var reused: [Int: M4BChapterArtifact] = [:]
    for (index, chapter) in plan.chapters.enumerated() {
      if let artifact = job.validatedArtifact(
        chapterIndex: index, title: chapter.title, writer: writer)
      {
        reused[index] = artifact
      }
    }
    continuation.yield(
      .started(
        totalChapters: plan.chapters.count,
        totalCharacters: plan.totalCharacterCount,
        reusedChapters: reused.count,
        chapterCharacters: plan.chapters.map(\.characterCount)))

    var assembled: [(title: String, artifact: M4BChapterArtifact)] = []
    for (index, chapter) in plan.chapters.enumerated() {
      try Task.checkCancellation()
      if let artifact = reused[index] {
        assembled.append((chapter.title, artifact))
        continuation.yield(.chapterCompleted(index: index, title: chapter.title, reused: true))
        continue
      }

      continuation.yield(.chapterStarted(index: index, title: chapter.title))
      let artifact = try await synthesizeChapter(
        chapter, index: index, artifactURL: job.artifactURL(chapterIndex: index),
        continuation: continuation)
      try job.recordCompleted(chapterIndex: index, title: chapter.title)
      assembled.append((chapter.title, artifact))
      continuation.yield(.chapterCompleted(index: index, title: chapter.title, reused: false))
    }

    if assembled.count > 255 {
      continuation.yield(
        .warning(
          "book has \(assembled.count) chapters: players reading the Nero chapter list see the "
            + "first 255; the Apple chapter track carries all of them"))
    }

    try Task.checkCancellation()
    continuation.yield(.assemblyStarted)
    try writer.assemble(
      chapters: assembled,
      metadata: AudiobookMetadata(
        title: plan.metadata.title,
        author: plan.metadata.author,
        narrator: settings.narratorName,
        genre: plan.metadata.subject,
        date: plan.metadata.date,
        bookDescription: plan.metadata.description),
      cover: plan.cover,
      to: outputURL,
      progress: nil)
    continuation.yield(.finished(outputURL: outputURL))
  }

  private struct SynthesisUnit {
    let text: String
    let sourceLocator: SourceLocator?
    let pauseAfterSeconds: Double
  }

  private func synthesizeChapter(
    _ chapter: NarrationChapter,
    index chapterIndex: Int,
    artifactURL: URL,
    continuation: AsyncThrowingStream<AudiobookProgressEvent, Error>.Continuation
  ) async throws -> M4BChapterArtifact {
    let units = makeUnits(for: chapter)
    let encoder = try writer.makeChapterEncoder(artifactURL: artifactURL)

    do {
      try encoder.append(
        pcm16: SilencePCM.data(
          seconds: settings.headPauseSeconds, sampleRate: settings.sampleRate))
      try await pumpUnits(units, into: encoder, chapterIndex: chapterIndex) { completed in
        continuation.yield(
          .unitCompleted(
            chapterIndex: chapterIndex, completed: completed, total: units.count))
      }
      try encoder.append(
        pcm16: SilencePCM.data(
          seconds: settings.chapterPauseSeconds, sampleRate: settings.sampleRate))
      return try encoder.finish()
    } catch is CancellationError {
      encoder.cancel()
      throw CancellationError()
    } catch let error as AudiobookRunError {
      encoder.cancel()
      throw AudiobookRunError(
        chapterIndex: chapterIndex, chapterTitle: chapter.title, unit: error.unit,
        underlying: error.underlying)
    } catch {
      encoder.cancel()
      throw AudiobookRunError(
        chapterIndex: chapterIndex, chapterTitle: chapter.title, unit: nil,
        underlying: error)
    }
  }

  /// Bounded-window ordered fan-out: at most 2×maxWorkers sentences in
  /// flight; results re-enter source order before touching the encoder.
  private func pumpUnits(
    _ units: [SynthesisUnit],
    into encoder: any M4BChapterEncoding,
    chapterIndex: Int,
    onProgress: (Int) -> Void
  ) async throws {
    guard !units.isEmpty else { return }
    let window = max(1, settings.maxWorkers * 2)
    let sentences = sentences

    var completed: [Int: Data] = [:]
    var nextToEmit = 0
    var submitted = 0

    try await withThrowingTaskGroup(of: (Int, Data).self) { group in
      // The window bounds the reorder gap, not just the in-flight count: a
      // single stalled early sentence must not let later completions pile up
      // in `completed` without limit.
      func fillWindow() {
        while submitted < units.count, submitted - nextToEmit < window {
          let index = submitted
          let text = units[index].text
          submitted += 1
          group.addTask {
            do {
              let audio = try await sentences.synthesize(text: text)
              guard audio.sampleRate == self.settings.sampleRate, audio.channels == 1 else {
                throw TTSBackendError.invalidAudioFormat
              }
              return (index, audio.data)
            } catch TTSBackendError.synthesisFailed
              where NarrationUnitPlanner.isSpeechless(text)
            {
              // The engine refuses letterless decoration outright, so no
              // speakable content exists to lose; the unit contributes only
              // its pause. Units with any letter or numeral still abort.
              return (index, Data())
            }
          }
        }
      }
      fillWindow()

      do {
        while let (index, pcm) = try await group.next() {
          completed[index] = pcm
          while let ready = completed.removeValue(forKey: nextToEmit) {
            try encoder.append(pcm16: ready)
            let pause = units[nextToEmit].pauseAfterSeconds
            if pause > 0 {
              try encoder.append(
                pcm16: SilencePCM.data(seconds: pause, sampleRate: settings.sampleRate))
            }
            nextToEmit += 1
            onProgress(nextToEmit)
          }
          try Task.checkCancellation()
          fillWindow()
        }
      } catch is CancellationError {
        throw CancellationError()
      } catch let error as AudiobookAudioError {
        group.cancelAll()
        throw AudiobookRunError(
          chapterIndex: chapterIndex, chapterTitle: "", unit: nextToEmit, underlying: error)
      } catch {
        group.cancelAll()
        throw AudiobookRunError(
          chapterIndex: chapterIndex, chapterTitle: "", unit: min(nextToEmit, units.count - 1),
          underlying: error)
      }
    }
  }

  /// One unit per paragraph: multi-sentence prosody flows inside the
  /// engine, and the paragraph pause is inserted only between units. The
  /// request deadline is scaled to the longest paragraph by the caller.
  ///
  /// A degenerate wall-of-text paragraph is split at sentence boundaries
  /// under `maxUnitCharacters` (with no pause between the pieces): the IPC
  /// frame header is hard-capped, so an unbounded unit would fail the same
  /// way on every run — a deterministic, resume-proof dead end.
  private func makeUnits(for chapter: NarrationChapter) -> [SynthesisUnit] {
    let paragraphs = chapter.allParagraphs
    var units: [SynthesisUnit] = []
    for (paragraphIndex, paragraph) in paragraphs.enumerated() {
      let pauseAfter = paragraphIndex < paragraphs.count - 1
        ? settings.paragraphPauseSeconds : 0
      let pieces = NarrationUnitPlanner.units(for: paragraph)
      for (pieceIndex, piece) in pieces.enumerated() {
        units.append(
          SynthesisUnit(
            text: piece.text,
            sourceLocator: piece.sourceLocator,
            pauseAfterSeconds: pieceIndex == pieces.count - 1 ? pauseAfter : 0))
      }
    }
    return units
  }
}

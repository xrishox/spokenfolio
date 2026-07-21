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

  /// Capture ground-truth narration timing during synthesis and write the
  /// digest-bound sidecar next to the finished M4B. Off by default; the
  /// PCM and M4B output are byte-identical either way.
  package var emitTimeline: Bool

  package init(
    narratorName: String, maxWorkers: Int = 4,
    paragraphPauseSeconds: Double = 0.6, chapterPauseSeconds: Double = 1.75,
    headPauseSeconds: Double = 0.25, sampleRate: Int = 48_000,
    emitTimeline: Bool = false
  ) {
    self.narratorName = narratorName
    self.maxWorkers = maxWorkers
    self.paragraphPauseSeconds = paragraphPauseSeconds
    self.chapterPauseSeconds = chapterPauseSeconds
    self.headPauseSeconds = headPauseSeconds
    self.sampleRate = sampleRate
    self.emitTimeline = emitTimeline
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
        jobKey: job.inputs.jobKey,
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
    if settings.emitTimeline {
      let artifactURLs = (0..<assembled.count).map { job.artifactURL(chapterIndex: $0) }
      let fingerprintHex = job.inputs.fingerprint.map { String(format: "%02x", $0) }.joined()
      let coverage = try SynthesisTimelineSidecar.write(
        jobKey: job.inputs.jobKey,
        fingerprintHex: fingerprintHex,
        artifacts: assembled,
        artifactURLs: artifactURLs,
        outputURL: outputURL,
        sampleRate: settings.sampleRate)
      if coverage < 1.0 {
        continuation.yield(
          .warning(
            "synthesis timeline covers \(Int(coverage * 100))% of chapters; "
              + "reused chapters without timelines are recorded as uncovered"))
      }
    }
    continuation.yield(.finished(outputURL: outputURL))
  }

  private struct SynthesisUnit {
    let text: String
    let sourceLocator: SourceLocator?
    let pauseAfterSeconds: Double
    let sentences: [String]
    let isAnnouncement: Bool
  }

  static func timelineURL(forArtifact artifactURL: URL) -> URL {
    artifactURL.appendingPathExtension("timeline.json")
  }

  private func writeChapterTimeline(
    for chapter: NarrationChapter, chapterIndex: Int, artifactURL: URL,
    jobKey: String, headPauseFrames: Int, units: [SynthesisUnit],
    unitTimings: [ChapterSynthesisTimeline.UnitTiming],
    wordsByUnit: [[SpokenWordTiming]?]
  ) throws {
    let sentences = ChapterSynthesisTimeline.deriveSentences(
      sentencesByUnit: units.map(\.sentences), units: unitTimings,
      wordsByUnit: wordsByUnit, sampleRate: settings.sampleRate)
    var sourceDocuments: [String] = []
    for unit in units {
      guard let documentID = unit.sourceLocator?.documentID,
        sourceDocuments.last != documentID, !sourceDocuments.contains(documentID)
      else { continue }
      sourceDocuments.append(documentID)
    }
    let timeline = ChapterSynthesisTimeline(
      jobKey: jobKey,
      chapterIndex: chapterIndex,
      title: chapter.title,
      sampleRate: settings.sampleRate,
      headPauseFrames: headPauseFrames,
      artifactSHA256: try ChapterSynthesisTimeline.sha256(of: artifactURL),
      sourceDocuments: sourceDocuments,
      units: unitTimings,
      sentences: sentences)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let url = Self.timelineURL(forArtifact: artifactURL)
    try encoder.encode(timeline).write(to: url, options: .atomic)
  }

  private func synthesizeChapter(
    _ chapter: NarrationChapter,
    index chapterIndex: Int,
    artifactURL: URL,
    jobKey: String,
    continuation: AsyncThrowingStream<AudiobookProgressEvent, Error>.Continuation
  ) async throws -> M4BChapterArtifact {
    let units = makeUnits(for: chapter)
    let encoder = try writer.makeChapterEncoder(artifactURL: artifactURL)

    do {
      let headPad = SilencePCM.data(
        seconds: settings.headPauseSeconds, sampleRate: settings.sampleRate)
      try encoder.append(pcm16: headPad)
      let headPauseFrames = headPad.count / MemoryLayout<Int16>.size
      let pumped = try await pumpUnits(
        units, into: encoder, chapterIndex: chapterIndex,
        startingFrame: headPauseFrames
      ) { completed in
        continuation.yield(
          .unitCompleted(
            chapterIndex: chapterIndex, completed: completed, total: units.count))
      }
      try encoder.append(
        pcm16: SilencePCM.data(
          seconds: settings.chapterPauseSeconds, sampleRate: settings.sampleRate))
      let artifact = try encoder.finish()
      if settings.emitTimeline {
        try writeChapterTimeline(
          for: chapter, chapterIndex: chapterIndex, artifactURL: artifactURL,
          jobKey: jobKey, headPauseFrames: headPauseFrames, units: units,
          unitTimings: pumped.timings, wordsByUnit: pumped.words)
      }
      return artifact
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
  @discardableResult
  private func pumpUnits(
    _ units: [SynthesisUnit],
    into encoder: any M4BChapterEncoding,
    chapterIndex: Int,
    startingFrame: Int = 0,
    onProgress: (Int) -> Void
  ) async throws -> (
    timings: [ChapterSynthesisTimeline.UnitTiming], words: [[SpokenWordTiming]?]
  ) {
    guard !units.isEmpty else { return ([], []) }
    let window = max(1, settings.maxWorkers * 2)
    let sentences = sentences

    var completed: [Int: (pcm: Data, words: [SpokenWordTiming]?)] = [:]
    var nextToEmit = 0
    var submitted = 0
    var timings: [ChapterSynthesisTimeline.UnitTiming] = []
    var wordsByUnit: [[SpokenWordTiming]?] = []
    var cursor = startingFrame
    let captureWords = settings.emitTimeline

    try await withThrowingTaskGroup(of: (Int, Data, [SpokenWordTiming]?).self) { group in
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
              if captureWords {
                let result = try await sentences.synthesizeDetailed(text: text)
                guard result.audio.sampleRate == self.settings.sampleRate,
                  result.audio.channels == 1
                else { throw TTSBackendError.invalidAudioFormat }
                return (index, result.audio.data, result.timings)
              }
              let audio = try await sentences.synthesize(text: text)
              guard audio.sampleRate == self.settings.sampleRate, audio.channels == 1 else {
                throw TTSBackendError.invalidAudioFormat
              }
              return (index, audio.data, nil)
            } catch TTSBackendError.synthesisFailed
              where NarrationUnitPlanner.isSpeechless(text)
            {
              // The engine refuses letterless decoration outright, so no
              // speakable content exists to lose; the unit contributes only
              // its pause. Units with any letter or numeral still abort.
              return (index, Data(), nil)
            }
          }
        }
      }
      fillWindow()

      do {
        while let (index, pcm, words) = try await group.next() {
          completed[index] = (pcm, words)
          while let ready = completed.removeValue(forKey: nextToEmit) {
            try encoder.append(pcm16: ready.pcm)
            let pause = units[nextToEmit].pauseAfterSeconds
            var pauseFrames = 0
            if pause > 0 {
              let silence = SilencePCM.data(seconds: pause, sampleRate: settings.sampleRate)
              try encoder.append(pcm16: silence)
              pauseFrames = silence.count / MemoryLayout<Int16>.size
            }
            // The cursor mirrors the appends exactly, so unit spans are
            // ground truth by construction.
            let unit = units[nextToEmit]
            let frameCount = ready.pcm.count / MemoryLayout<Int16>.size
            timings.append(
              ChapterSynthesisTimeline.UnitTiming(
                unitIndex: nextToEmit,
                text: unit.text,
                kind: frameCount == 0 && NarrationUnitPlanner.isSpeechless(unit.text)
                  ? .speechlessSilence
                  : unit.isAnnouncement ? .announcement : .prose,
                startFrame: cursor,
                frameCount: frameCount,
                pauseAfterFrames: pauseFrames))
            cursor += frameCount + pauseFrames
            wordsByUnit.append(ready.words)
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
    return (timings, wordsByUnit)
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
    let hasAnnouncement = chapter.announcement != nil
    var units: [SynthesisUnit] = []
    for (paragraphIndex, paragraph) in paragraphs.enumerated() {
      let pauseAfter = paragraphIndex < paragraphs.count - 1
        ? settings.paragraphPauseSeconds : 0
      let pieces = NarrationUnitPlanner.units(for: paragraph)
      let sentencesByPiece = Self.assignSentences(
        paragraph.sentences, toPieces: pieces.map(\.text))
      for (pieceIndex, piece) in pieces.enumerated() {
        units.append(
          SynthesisUnit(
            text: piece.text,
            sourceLocator: piece.sourceLocator,
            pauseAfterSeconds: pieceIndex == pieces.count - 1 ? pauseAfter : 0,
            sentences: sentencesByPiece[pieceIndex],
            isAnnouncement: hasAnnouncement && paragraphIndex == 0))
      }
    }
    return units
  }

  /// Deterministically re-associates a paragraph's sentences with the
  /// planner's packed pieces. Whole sentences pack greedily, so each piece
  /// is a space-join of consecutive sentences; a SentenceLimiter fragment
  /// (pathological over-long sentence) attributes the sentence to the piece
  /// where it starts.
  static func assignSentences(
    _ sentences: [String], toPieces pieces: [String]
  ) -> [[String]] {
    var result: [[String]] = Array(repeating: [], count: pieces.count)
    var sentenceIndex = 0
    var pieceIndex = 0
    var consumedInSentence = 0
    while pieceIndex < pieces.count, sentenceIndex < sentences.count {
      var remaining = pieces[pieceIndex].count
      while sentenceIndex < sentences.count, remaining > 0 {
        let sentenceLength = sentences[sentenceIndex].count - consumedInSentence
        if consumedInSentence == 0 {
          result[pieceIndex].append(sentences[sentenceIndex])
        }
        if sentenceLength <= remaining {
          remaining -= sentenceLength
          if remaining > 0 { remaining -= 1 }  // joining space
          sentenceIndex += 1
          consumedInSentence = 0
        } else {
          consumedInSentence += remaining
          remaining = 0
        }
      }
      pieceIndex += 1
    }
    return result
  }
}

import ArgumentParser
import AudiobookKit
import EPUBKit
import CryptoKit
import Darwin
import Foundation
import SiriTTSCore
import TTSKit

/// Hidden benchmarking harness: measures synthesis throughput under
/// different worker counts, feed shapes, and chunk sizes, and produces
/// listening samples for quality comparison. One invocation = one run = one
/// JSON line on stdout. Production pipeline code is not touched; the bench
/// drives its own pool with an instrumented clone of the pipeline's pump.
@main
struct SiriTTSBench: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "siri-tts-bench",
      abstract: "Benchmark Siri synthesis throughput (testing aid).")

    enum Mode: String, ExpressibleByArgument {
      case saturated
      case chaptersSeq = "chapters-seq"
      case chaptersGlobal = "chapters-global"
    }

    @Option(help: "EPUB supplying real prose for the workload.")
    var epub: String

    @Option(help: "Concurrent Siri worker processes.")
    var workers: Int = 4

    @Option(help: "Feed shape: saturated, chapters-seq, chapters-global.")
    var mode: Mode = .saturated

    @Option(name: .customLong("window-multiplier"), help: "Reorder window = multiplier × workers.")
    var windowMultiplier: Int = 2

    @Option(
      name: .customLong("chunk-sentences"),
      help: "Group N consecutive sentences per request (never crossing a paragraph).")
    var chunkSentences: Int = 1

    @Option(
      name: .customLong("chunk-chars"),
      help: "Pack whole paragraphs up to N characters per request (overrides --chunk-sentences).")
    var chunkChars: Int = 0

    @Option(help: "Unit count (0 = 100 × workers, ≈90 s of measured wall).")
    var units: Int = 0

    @Option(help: "Deterministic corpus shuffle seed.")
    var seed: UInt64 = 42

    @Option(
      name: .customLong("deadline-seconds"),
      help: "Per-request pool deadline (0 = auto-scaled to chunk size).")
    var deadlineSeconds: Double = 0

    @Option(help: "Voice ID or unambiguous alias (default: preferred installed voice).")
    var voice: String?

    @Flag(
      name: .customLong("no-internal-split"),
      help: "Workers pass whole chunks to the engine as one utterance.")
    var noInternalSplit = false

    @Option(name: .customLong("sample-text"), help: "Passage file (blank-line paragraphs) to synthesize as a quality sample instead of benchmarking.")
    var sampleText: String?

    @Option(name: .customLong("sample-out"), help: "Output WAV path for --sample-text.")
    var sampleOut: String?

    @Flag(name: .customLong("ignore-env"), help: "Run despite thermal/load preconditions.")
    var ignoreEnv = false

    @Option(help: "Label recorded in the output line.")
    var experiment: String = ""

    @Option(name: .customLong("run-seq"), help: "Global run-order label.")
    var runSeq: Int = 0

    @Option(name: .customLong("repeat"), help: "Repeat label.")
    var repeatIndex: Int = 1

    func run() async throws {
      var isRelease = true
      #if DEBUG
        isRelease = false
        FileHandle.standardError.write(
          Data("bench: WARNING debug build — numbers are not comparable\n".utf8))
      #endif
      try checkEnvironment()

      try SiriPermissionPreflight.verifyModelAccess()
      let assets = SiriVoiceCatalog.discover()
      guard !assets.isEmpty else {
        throw BenchFailure(message: "no compatible Siri voices installed", exitCode: 69)
      }
      let voiceID =
        voice.flatMap { SiriVoiceCatalog.makeVoiceLookup(assets)[$0.lowercased()] }
        ?? SiriVoiceCatalog.preferred(assets)!.id

      let corpus = try buildCorpus()
      let workload = try selectWorkload(corpus: corpus)
      let maxUnitChars = workload.map(\.text.count).max() ?? 0
      let effectiveDeadline =
        deadlineSeconds > 0 ? deadlineSeconds : max(60, Double(maxUnitChars) / 3)

      let pool = SiriWorkerPool(
        maxWorkers: workers, maxQueued: 4 * workers + 16, deadlineSeconds: effectiveDeadline)
      defer { Task { await pool.shutdown() } }

      let warmupSeconds = try await warmUp(pool: pool, voiceID: voiceID)

      if let sampleText, let sampleOut {
        try await writeSample(
          passageFile: sampleText, outputPath: sampleOut, pool: pool, voiceID: voiceID)
        await pool.shutdown()
        return
      }

      let cpuBefore = cpuTicks()
      let thermalStart = thermalStateName()
      let result: PumpResult
      switch mode {
      case .saturated, .chaptersGlobal:
        result = try await pump(
          units: workload, pool: pool, voiceID: voiceID, window: windowMultiplier * workers)
      case .chaptersSeq:
        var merged = PumpResult()
        let clock = ContinuousClock()
        let started = clock.now
        for chapter in Set(workload.map(\.chapter)).sorted() {
          let chapterUnits = workload.filter { $0.chapter == chapter }
          let partial = try await pump(
            units: chapterUnits, pool: pool, voiceID: voiceID,
            window: windowMultiplier * workers)
          merged.absorb(partial)
        }
        merged.wallSeconds = seconds(clock.now - started)
        result = merged
      }
      let cpuAfter = cpuTicks()
      let diagnostics = await pool.diagnosticsSnapshot()
      await pool.shutdown()

      var loadAverage = [Double](repeating: 0, count: 3)
      getloadavg(&loadAverage, 3)

      let output = BenchOutput(
        schema: 1,
        experiment: experiment,
        runSeq: runSeq,
        repeatIndex: repeatIndex,
        releaseBuild: isRelease,
        voiceID: voiceID,
        mode: mode.rawValue,
        workers: workers,
        windowMultiplier: windowMultiplier,
        chunkSentences: chunkSentences,
        chunkChars: chunkChars,
        noInternalSplit: noInternalSplit,
        workerQos: false,
        deadlineSeconds: effectiveDeadline,
        unitCount: workload.count,
        unitCharsP50: percentile(workload.map(\.text.count), 0.5),
        unitCharsP95: percentile(workload.map(\.text.count), 0.95),
        unitCharsMax: maxUnitChars,
        corpusSHA: corpusDigest(workload),
        warmupSeconds: warmupSeconds,
        wallSeconds: result.wallSeconds,
        audioSeconds: Double(result.frames) / 48_000,
        realtimeFactor: result.wallSeconds > 0
          ? (Double(result.frames) / 48_000) / result.wallSeconds : 0,
        charsPerWallSec: result.wallSeconds > 0
          ? Double(workload.reduce(0) { $0 + $1.text.count }) / result.wallSeconds : 0,
        latencyP50: percentile(result.latencies, 0.5),
        latencyP95: percentile(result.latencies, 0.95),
        latencyMax: result.latencies.max() ?? 0,
        inFlightAverage: result.wallSeconds > 0
          ? result.inFlightSecondsIntegral / result.wallSeconds : 0,
        windowStallSeconds: result.stallSeconds,
        drainSeconds: result.drainSeconds,
        cpuBusyFraction: cpuBusyFraction(before: cpuBefore, after: cpuAfter),
        retries: diagnostics.retries,
        workerKills: diagnostics.workerKills,
        workersSpawned: diagnostics.workersSpawned,
        thermalStart: thermalStart,
        thermalEnd: thermalStateName(),
        load1: loadAverage[0])

      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      print(String(decoding: try encoder.encode(output), as: UTF8.self))

      if diagnostics.retries > 0 || diagnostics.workerKills > 0 {
        FileHandle.standardError.write(
          Data("bench: RUN INVALID (retries/kills nonzero) — discard and re-run\n".utf8))
        throw ExitCode(75)  // EX_TEMPFAIL
      }
    }

    // MARK: - Preconditions

    private func checkEnvironment() throws {
      guard !ignoreEnv else { return }
      if ProcessInfo.processInfo.thermalState != .nominal {
        throw BenchFailure(
          message:
            "thermal state is \(thermalStateName()) — wait for nominal or pass --ignore-env",
          exitCode: 75)
      }
      var loadAverage = [Double](repeating: 0, count: 3)
      getloadavg(&loadAverage, 3)
      if loadAverage[0] > 4.0 {
        throw BenchFailure(
          message: String(
            format: "load average %.1f is too high for a clean run — pass --ignore-env",
            loadAverage[0]),
          exitCode: 75)
      }
    }

    // MARK: - Workload

    private struct BenchUnit {
      let text: String
      let chapter: Int
    }

    /// Chapter paragraphs → sentence units → optional whole-sentence chunking,
    /// exactly mirroring production text preparation.
    private func buildCorpus() throws -> [[[String]]] {
      let url = URL(fileURLWithPath: (epub as NSString).expandingTildeInPath)
      guard FileManager.default.fileExists(atPath: url.path) else {
        throw BenchFailure(message: "no such file: \(url.path)", exitCode: 66)
      }
      let publication = try EPUBImporter().load(url: url)
      let plan = try AudiobookPlanner.plan(publication: publication)
      // chapters → paragraphs → sentences (announcements excluded).
      return plan.chapters.map { chapter in
        chapter.paragraphs.map { paragraph in
          paragraph.sentences.flatMap { SentenceLimiter.split($0) }
        }
      }
    }

    private func selectWorkload(corpus: [[[String]]]) throws -> [BenchUnit] {
      let chunked: [[BenchUnit]] = corpus.enumerated().map { chapterIndex, paragraphs in
        chunk(paragraphs: paragraphs).map { BenchUnit(text: $0, chapter: chapterIndex) }
      }

      switch mode {
      case .saturated:
        let all = chunked.flatMap { $0 }
        guard !all.isEmpty else {
          throw BenchFailure(message: "the book produced no narratable units", exitCode: 65)
        }
        let target = units > 0 ? units : 100 * workers
        return Array(stratifiedShuffle(all).prefix(target))
      case .chaptersSeq, .chaptersGlobal:
        // First 3 substantial chapters, ~5,400 chars each (≈ 60 sentences),
        // real order preserved — drain behavior depends on where long
        // sentences fall.
        var selected: [BenchUnit] = []
        var chaptersTaken = 0
        for chapter in chunked where chapter.reduce(0, { $0 + $1.text.count }) > 2_000 {
          var budget = 5_400
          for unit in chapter {
            guard budget > 0 else { break }
            selected.append(unit)
            budget -= unit.text.count
          }
          chaptersTaken += 1
          if chaptersTaken == 3 { break }
        }
        guard chaptersTaken > 0 else {
          throw BenchFailure(message: "no substantial chapters found", exitCode: 65)
        }
        return selected
      }
    }

    /// Whole sentences always. `--chunk-chars` packs whole paragraphs (joined
    /// by blank lines) up to the budget; `--chunk-sentences` groups within a
    /// paragraph.
    private func chunk(paragraphs: [[String]]) -> [String] {
      if chunkChars > 0 {
        var chunks: [String] = []
        var current: [String] = []
        var currentLength = 0
        for paragraph in paragraphs where !paragraph.isEmpty {
          let text = paragraph.joined(separator: " ")
          if !current.isEmpty, currentLength + text.count > chunkChars {
            chunks.append(current.joined(separator: "\n\n"))
            current = []
            currentLength = 0
          }
          current.append(text)
          currentLength += text.count + 2
        }
        if !current.isEmpty { chunks.append(current.joined(separator: "\n\n")) }
        return chunks
      }
      if chunkSentences > 1 {
        return paragraphs.flatMap { sentences in
          stride(from: 0, to: sentences.count, by: chunkSentences).map { start in
            sentences[start..<min(start + chunkSentences, sentences.count)]
              .joined(separator: " ")
          }
        }
      }
      return paragraphs.flatMap { $0 }
    }

    /// Length-bucketed round-robin with a seeded shuffle inside each bucket:
    /// any prefix is length-representative, so different worker counts can
    /// use different workload sizes and stay comparable.
    private func stratifiedShuffle(_ units: [BenchUnit]) -> [BenchUnit] {
      var generator = SplitMix64(seed: seed)
      var buckets: [[BenchUnit]] = [[], [], [], []]
      for unit in units {
        switch unit.text.count {
        case ..<60: buckets[0].append(unit)
        case ..<120: buckets[1].append(unit)
        case ..<200: buckets[2].append(unit)
        default: buckets[3].append(unit)
        }
      }
      for index in buckets.indices { buckets[index].shuffle(using: &generator) }
      var result: [BenchUnit] = []
      result.reserveCapacity(units.count)
      var cursors = [0, 0, 0, 0]
      while result.count < units.count {
        for bucket in buckets.indices where cursors[bucket] < buckets[bucket].count {
          result.append(buckets[bucket][cursors[bucket]])
          cursors[bucket] += 1
        }
      }
      return result
    }

    private func corpusDigest(_ units: [BenchUnit]) -> String {
      var hasher = SHA256()
      for unit in units { hasher.update(data: Data(unit.text.utf8)) }
      return Data(hasher.finalize()).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Warmup

    /// W concurrent dummy requests force W spawned workers with loaded
    /// models; model load happens off the measured clock.
    private func warmUp(pool: SiriWorkerPool, voiceID: String) async throws -> Double {
      let clock = ContinuousClock()
      let started = clock.now
      try await withThrowingTaskGroup(of: Void.self) { group in
        for _ in 0..<workers {
          group.addTask {
            _ = try await pool.synthesize(
              text: "The benchmark warms this worker up before measuring.", voiceID: voiceID)
          }
        }
        try await group.waitForAll()
      }
      return seconds(clock.now - started)
    }

    // MARK: - Instrumented pump (clone of the production ordering logic)

    private struct PumpResult {
      var frames = 0
      var wallSeconds = 0.0
      var latencies: [Double] = []
      var stallSeconds = 0.0
      var drainSeconds = 0.0
      var inFlightSecondsIntegral = 0.0

      mutating func absorb(_ other: PumpResult) {
        frames += other.frames
        latencies.append(contentsOf: other.latencies)
        stallSeconds += other.stallSeconds
        drainSeconds += other.drainSeconds
        inFlightSecondsIntegral += other.inFlightSecondsIntegral
      }
    }

    private func pump(
      units: [BenchUnit], pool: SiriWorkerPool, voiceID: String, window: Int
    ) async throws -> PumpResult {
      var result = PumpResult()
      guard !units.isEmpty else { return result }
      let clock = ContinuousClock()
      let started = clock.now

      var submitted = 0
      var nextToEmit = 0
      var completed: [Int: Int] = [:]  // index → frame count (PCM discarded)
      var submitTimes: [Int: ContinuousClock.Instant] = [:]
      var queueEmptiedAt: ContinuousClock.Instant?
      var lastEmitAt = started

      var inFlight = 0
      var lastEventAt = started
      try await withThrowingTaskGroup(of: (Int, Data).self) { group in
        func accountInFlight(now: ContinuousClock.Instant) {
          result.inFlightSecondsIntegral += Double(inFlight) * seconds(now - lastEventAt)
          lastEventAt = now
        }
        func fillWindow() {
          while submitted < units.count, submitted - nextToEmit < window {
            let index = submitted
            let text = units[index].text
            let now = clock.now
            accountInFlight(now: now)
            submitTimes[index] = now
            submitted += 1
            inFlight += 1
            group.addTask {
              (index,
               try await pool.synthesize(
                 text: text, voiceID: voiceID, splitSentencesInWorker: !self.noInternalSplit))
            }
          }
          if submitted == units.count, queueEmptiedAt == nil {
            queueEmptiedAt = clock.now
          }
        }
        fillWindow()

        while true {
          // Ordering starves workers only when the window is full AND fewer
          // requests are in flight than workers could serve.
          let unitsRemain = submitted < units.count
          let windowFull = submitted - nextToEmit >= window
          let starving = unitsRemain && windowFull && inFlight < workers
          let waitStarted = clock.now
          guard let (index, pcm) = try await group.next() else { break }
          let now = clock.now
          accountInFlight(now: now)
          inFlight -= 1
          if starving {
            result.stallSeconds += seconds(now - waitStarted)
          }
          if let submitTime = submitTimes.removeValue(forKey: index) {
            result.latencies.append(seconds(now - submitTime))
          }
          completed[index] = pcm.count / 2

          while let frames = completed.removeValue(forKey: nextToEmit) {
            result.frames += frames  // ordered emission into a null encoder
            nextToEmit += 1
            lastEmitAt = clock.now
          }
          fillWindow()
        }
      }

      result.wallSeconds = seconds(clock.now - started)
      if let queueEmptiedAt {
        result.drainSeconds = max(0, seconds(lastEmitAt - queueEmptiedAt))
      }
      return result
    }

    // MARK: - Quality sample (E4q)

    private func writeSample(
      passageFile: String, outputPath: String, pool: SiriWorkerPool, voiceID: String
    ) async throws {
      let passageURL = URL(fileURLWithPath: (passageFile as NSString).expandingTildeInPath)
      let text = String(decoding: try Data(contentsOf: passageURL), as: UTF8.self)
      let paragraphs = text.components(separatedBy: "\n\n")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).collapsingNewlines() }
        .filter { !$0.isEmpty }
      let sentenceParagraphs = paragraphs.map {
        splitSentences($0).flatMap { SentenceLimiter.split($0) }
      }

      // Pause semantics mirror production: 0.6 s between paragraphs, nothing
      // within one. Where the chunking merges a boundary into a single
      // utterance the engine chooses the pacing — that difference is exactly
      // what the listener is judging.
      var pcm = Data()
      let paragraphPause = Data(count: Int(0.6 * 48_000) * 2)
      if chunkChars > 0 {
        let chunks = chunk(paragraphs: sentenceParagraphs)
        for (index, chunkText) in chunks.enumerated() {
          if index > 0 { pcm.append(paragraphPause) }
          pcm.append(
            try await pool.synthesize(
              text: chunkText, voiceID: voiceID, splitSentencesInWorker: !noInternalSplit))
        }
      } else {
        for (paragraphIndex, sentences) in sentenceParagraphs.enumerated() {
          if paragraphIndex > 0 { pcm.append(paragraphPause) }
          let groups = stride(from: 0, to: sentences.count, by: max(1, chunkSentences)).map {
            sentences[$0..<min($0 + max(1, chunkSentences), sentences.count)]
              .joined(separator: " ")
          }
          for group in groups {
            pcm.append(
              try await pool.synthesize(
                text: group, voiceID: voiceID, splitSentencesInWorker: !noInternalSplit))
          }
        }
      }

      let outputURL = URL(fileURLWithPath: (outputPath as NSString).expandingTildeInPath)
      try FileManager.default.createDirectory(
        at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try makeWAV(pcmData: pcm, sampleRate: 48_000).write(to: outputURL)
      print(
        #"{"sample":"\#(outputURL.path)","paragraphs":\#(sentenceParagraphs.count),"audioSeconds":\#(Double(pcm.count / 2) / 48_000)}"#
      )
    }

    // MARK: - System metrics

    private func seconds(_ duration: Duration) -> Double {
      Double(duration.components.seconds)
        + Double(duration.components.attoseconds) / 1e18
    }

    private func percentile(_ values: [Int], _ p: Double) -> Int {
      guard !values.isEmpty else { return 0 }
      let sorted = values.sorted()
      return sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]
    }

    private func percentile(_ values: [Double], _ p: Double) -> Double {
      guard !values.isEmpty else { return 0 }
      let sorted = values.sorted()
      return sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]
    }

    private func thermalStateName() -> String {
      switch ProcessInfo.processInfo.thermalState {
      case .nominal: "nominal"
      case .fair: "fair"
      case .serious: "serious"
      case .critical: "critical"
      @unknown default: "unknown"
      }
    }

    private func cpuTicks() -> (busy: UInt64, total: UInt64) {
      var cpuCount: natural_t = 0
      var info: processor_info_array_t?
      var infoCount: mach_msg_type_number_t = 0
      let result = host_processor_info(
        mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount)
      guard result == KERN_SUCCESS, let info else { return (0, 0) }
      defer {
        vm_deallocate(
          mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(infoCount) * 4)
      }
      var busy: UInt64 = 0
      var total: UInt64 = 0
      for cpu in 0..<Int(cpuCount) {
        let base = cpu * Int(CPU_STATE_MAX)
        let user = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]))
        let system = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]))
        let nice = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
        let idle = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]))
        busy += user + system + nice
        total += user + system + nice + idle
      }
      return (busy, total)
    }

    private func cpuBusyFraction(
      before: (busy: UInt64, total: UInt64), after: (busy: UInt64, total: UInt64)
    ) -> Double {
      let busyDelta = Double(after.busy &- before.busy)
      let totalDelta = Double(after.total &- before.total)
      return totalDelta > 0 ? busyDelta / totalDelta : 0
    }
}
private struct BenchFailure: Error, CustomStringConvertible {
  let message: String
  let exitCode: Int32
  var description: String { message }
}

private struct SplitMix64: RandomNumberGenerator {
  private var state: UInt64

  init(seed: UInt64) {
    state = seed
  }

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}

struct BenchOutput: Codable {
  let schema: Int
  let experiment: String
  let runSeq: Int
  let repeatIndex: Int
  let releaseBuild: Bool
  let voiceID: String
  let mode: String
  let workers: Int
  let windowMultiplier: Int
  let chunkSentences: Int
  let chunkChars: Int
  let noInternalSplit: Bool
  let workerQos: Bool
  let deadlineSeconds: Double
  let unitCount: Int
  let unitCharsP50: Int
  let unitCharsP95: Int
  let unitCharsMax: Int
  let corpusSHA: String
  let warmupSeconds: Double
  let wallSeconds: Double
  let audioSeconds: Double
  let realtimeFactor: Double
  let charsPerWallSec: Double
  let latencyP50: Double
  let latencyP95: Double
  let latencyMax: Double
  let inFlightAverage: Double
  let windowStallSeconds: Double
  let drainSeconds: Double
  let cpuBusyFraction: Double
  let retries: Int
  let workerKills: Int
  let workersSpawned: Int
  let thermalStart: String
  let thermalEnd: String
  let load1: Double
}

extension String {
  fileprivate func collapsingNewlines() -> String {
    replacingOccurrences(of: "\n", with: " ")
  }
}

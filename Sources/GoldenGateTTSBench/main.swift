import AudiobookKit
import Darwin
import Foundation
import GoldenGateTTSCore
import TTSKit

/// Developer-only worker-scaling harness for the expressive backend. It uses
/// the production paragraph unit planner and the same bounded 2×workers,
/// source-order reorder shape as audiobook synthesis.
@main
enum GoldenGateTTSBench {
  struct Options {
    var voiceID: String?
    var pace = 3
    var expressivity = 3
    var workers = [1, 2, 3, 4, 6, 8]
    var repetitions = 3
    var textFile: String?
    var includeLongUnit = false
  }

  struct Measurement {
    let workers: Int
    let repetition: Int
    let elapsedSeconds: Double
    let audioSeconds: Double
    let p95LatencySeconds: Double
    let checksum: UInt64

    var throughput: Double { audioSeconds / elapsedSeconds }
  }

  static func main() async {
    signal(SIGPIPE, SIG_IGN)
    if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--golden-gate-worker" {
      GoldenGateWorkerMain.run(voiceID: CommandLine.arguments[2])
    }
    if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "--golden-gate-catalog" {
      GoldenGateCatalogMain.run()
    }

    do {
      let options = try parse(Array(CommandLine.arguments.dropFirst()))
      try await run(options)
    } catch {
      FileHandle.standardError.write(Data("golden-gate-tts-bench: \(error.localizedDescription)\n".utf8))
      exit(EXIT_FAILURE)
    }
  }

  private static func parse(_ arguments: [String]) throws -> Options {
    var options = Options()
    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      func value() throws -> String {
        guard index + 1 < arguments.count else {
          throw TTSBackendError.invalidInput("Missing value after \(argument).")
        }
        index += 1
        return arguments[index]
      }
      switch argument {
      case "--voice": options.voiceID = try value()
      case "--pace": options.pace = Int(try value()) ?? 0
      case "--expressivity": options.expressivity = Int(try value()) ?? 0
      case "--workers":
        options.workers = try value().split(separator: ",").compactMap { Int($0) }
      case "--repetitions": options.repetitions = Int(try value()) ?? 0
      case "--text-file": options.textFile = try value()
      case "--include-long-unit": options.includeLongUnit = true
      case "--help", "-h":
        print("""
          Usage: golden-gate-tts-bench [options]
            --voice ID             FM voice ID (default: backend preference)
            --pace 1...5           Pace preset (default: 3)
            --expressivity 1...5  Expressivity preset (default: 3)
            --workers LIST         Comma-separated sweep (default: 1,2,3,4,6,8)
            --repetitions N        Warmed repetitions per count (default: 3)
            --text-file PATH       Blank-line-separated prose workload
            --include-long-unit    Include one ~3,450-character paragraph
          """)
        exit(EXIT_SUCCESS)
      default:
        throw TTSBackendError.invalidInput("Unknown option '\(argument)'.")
      }
      index += 1
    }
    guard (1...5).contains(options.pace), (1...5).contains(options.expressivity),
      (1...10).contains(options.repetitions), !options.workers.isEmpty,
      options.workers.allSatisfy({ (1...16).contains($0) })
    else { throw TTSBackendError.invalidInput("Preset, repetition, or worker bounds are invalid.") }
    return options
  }

  private static func run(_ options: Options) async throws {
    guard #available(macOS 27, *) else { throw TTSBackendError.unavailable }
    let backend = try GoldenGateTTSBackend()
    let voice: VoiceKey
    if let requested = options.voiceID {
      guard let resolved = backend.resolveVoice(requested) else {
        throw TTSBackendError.invalidInput("Unknown expressive voice '\(requested)'.")
      }
      voice = resolved
    } else {
      voice = backend.defaultVoice
    }
    let selection = TTSVoiceSelection(
      voice: voice,
      controls: TTSSynthesisControls(
        pace: try TTSPreset(options.pace), expressivity: try TTSPreset(options.expressivity)))
    let units = try workload(
      textFile: options.textFile, includeLongUnit: options.includeLongUnit)
    guard !units.isEmpty,
      units.allSatisfy({ !$0.isEmpty && $0.count <= NarrationUnitPlanner.maximumCharacters })
    else { throw TTSBackendError.invalidInput("The benchmark workload produced invalid units.") }

    print(
      "voice=\(voice.voiceID) presets=\(options.pace)/\(options.expressivity) "
        + "units=\(units.count) maxChars=\(units.map(\.count).max() ?? 0)")
    var measurements: [Measurement] = []
    for workers in options.workers {
      let session = try backend.makeSession(
        configuration: TTSWorkloadConfiguration(
          purpose: .audiobook, maxConcurrency: workers,
          maxQueuedRequests: max(20, units.count),
          deadlineSeconds: NarrationUnitPlanner.deadlineSeconds(
            maximumUnitCharacters: units.map(\.count).max() ?? 0)))
      defer { Task { await session.shutdown() } }
      // prepare performs one real synthesis, warming the model before timing.
      do {
        _ = try await session.prepare(selection: selection)
      } catch {
        throw TTSBackendError.invalidInput(
          "Preparation failed at \(workers) workers: \(error.localizedDescription)")
      }

      for repetition in 1...options.repetitions {
        let measurement = try await measure(
          units: units, workers: workers, repetition: repetition,
          selection: selection, session: session)
        measurements.append(measurement)
        print(
          String(
            format: "workers=%2d rep=%d throughput=%6.2fx elapsed=%7.2fs audio=%7.2fs p95=%6.2fs checksum=%016llx",
            workers, repetition, measurement.throughput, measurement.elapsedSeconds,
            measurement.audioSeconds, measurement.p95LatencySeconds,
            measurement.checksum))
      }
      await session.shutdown()
    }

    let medians = Dictionary(grouping: measurements, by: \.workers).mapValues { values in
      median(values.map(\.throughput))
    }
    guard let best = medians.values.max() else { return }
    let eligible = medians.filter { $0.value >= best * 0.95 }.keys.sorted()
    print("median throughput: " + medians.keys.sorted().map {
      String(format: "%d=%0.2fx", $0, medians[$0]!)
    }.joined(separator: ", "))
    if let recommended = eligible.first {
      print("95%-of-best candidate: \(recommended) workers (verify both installed FM voices before changing defaults)")
    }
    print("thermalState=\(ProcessInfo.processInfo.thermalState.rawValue)")
  }

  private static func measure(
    units: [String], workers: Int, repetition: Int,
    selection: TTSVoiceSelection, session: any TTSSession
  ) async throws -> Measurement {
    let clock = ContinuousClock()
    let started = clock.now
    let window = max(1, min(units.count, workers * 2))
    var nextLaunch = 0
    var nextEmit = 0
    var pending: [Int: (PCM16Audio, Double)] = [:]
    var audioSeconds = 0.0
    var latencies: [Double] = []
    var checksum: UInt64 = 14_695_981_039_346_656_037

    try await withThrowingTaskGroup(of: (Int, PCM16Audio, Double).self) { group in
      func add(_ index: Int) {
        group.addTask {
          let requestStart = clock.now
          do {
            // Vary the full text across counts and repetitions so sirittsd's
            // Opus cache cannot turn a generation benchmark into a decode benchmark.
            let text = "Benchmark \(workers), repetition \(repetition), passage \(index + 1). "
              + units[index]
            let result = try await session.synthesize(
              request: TTSSynthesisRequest(
                text: text, selection: selection,
                utteranceMode: .singleUtterance, timingMode: .none))
            let normalized = try PCMNormalizer.normalize(result.audio)
            return (index, normalized, seconds(clock.now - requestStart))
          } catch {
            throw TTSBackendError.invalidInput(
              "Unit \(index) (\(units[index].count) characters) failed: \(error.localizedDescription)")
          }
        }
      }
      while nextLaunch < window {
        add(nextLaunch)
        nextLaunch += 1
      }
      while let (index, audio, latency) = try await group.next() {
        pending[index] = (audio, latency)
        if nextLaunch < units.count {
          add(nextLaunch)
          nextLaunch += 1
        }
        while let (ordered, orderedLatency) = pending.removeValue(forKey: nextEmit) {
          let frames = ordered.data.count / (MemoryLayout<Int16>.size * ordered.channels)
          audioSeconds += Double(frames) / Double(ordered.sampleRate)
          latencies.append(orderedLatency)
          checksum = fnv1a(ordered.data, seed: checksum)
          nextEmit += 1
        }
      }
    }
    guard nextEmit == units.count else { throw TTSBackendError.synthesisFailed }
    let sorted = latencies.sorted()
    let p95Index = min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1)
    return Measurement(
      workers: workers, repetition: repetition,
      elapsedSeconds: seconds(clock.now - started), audioSeconds: audioSeconds,
      p95LatencySeconds: sorted[max(0, p95Index)], checksum: checksum)
  }

  private static func workload(
    textFile: String?, includeLongUnit: Bool
  ) throws -> [String] {
    let paragraphs: [String]
    if let textFile {
      let text = try String(contentsOfFile: textFile, encoding: .utf8)
      paragraphs = text.components(separatedBy: "\n\n")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    } else {
      let passages = [
        "Morning entered the room by degrees. The rain had stopped, but every branch still held a bright line of water, and the street below answered each passing wheel with a soft hiss. Mara closed the old ledger, listened for the kettle, and wondered whether the letter on the table had changed while she was not looking.",
        "The captain lowered their voice when the map was unfolded. Beyond the marked harbor lay three days of open water, a reef no chart agreed upon, and an island described only by sailors who contradicted one another. Nobody interrupted; even the lamps seemed to lean toward the table.",
        "At first the machine made no sound. Then a relay clicked somewhere behind the panel, followed by a low harmonic that rose, divided, and settled into something almost like a chord. 'That is not in the manual,' Inez said, with delight arriving half a second before caution.",
        "The child read the inscription twice: once as a warning, and once as an invitation. The difference was only a comma worn shallow by time. Behind the gate, wind moved through tall grass in long silver waves, carrying the distant call of an animal none of them could name.",
        "By evening the debate had escaped the council chamber and filled every kitchen in the district. Bakers argued over precedent, mechanics over cost, and grandparents over promises made before anyone else at the table was born. The proposal itself remained pinned beneath a glass paperweight, concise and stubborn.",
        "Snow changed the acoustics of the city. Footsteps became private, doors closed with unusual gentleness, and the bell in the western tower seemed nearer than the houses across the square. Arun walked without hurrying, rehearsing an apology that grew less convincing each time.",
        "When the orchestra stopped, one violin continued. It was not defiance; the player had reached a page copied in a different hand, where seven unexpected measures opened like a side door. The conductor waited. The audience waited. The melody found its way back without being called.",
        "No one expected the garden to survive the heat. Yet beneath the scorched leaves, new shoots appeared around the roots of the pear tree, pale and determined. We carried water after sunset, speaking quietly as if recovery were a shy creature that might flee from praise.",
        "The observatory opened its dome just before midnight. Clouds had hidden the northern sky for a week, but now the air was clear enough to show the faint green edge of the comet. Leena adjusted the lens, wrote down the time, and called the others without taking her eye from the glass.",
        "In the courtroom, certainty arrived in fragments. A receipt established the hour, a muddy coat suggested the road, and one hesitant answer changed the meaning of everything said before it. The judge asked for silence, not because the room was noisy, but because everyone had begun thinking aloud.",
        "The last train crossed the plain under a copper sunset. In the dining car, cups trembled gently against their saucers while fields, barns, and isolated stands of cottonwood moved past the windows. Tomas watched the station lights appear ahead and folded the unfinished note into his pocket.",
        "The archivist found the missing volume where no catalog would have sent her: behind a row of atlases, wrapped in cloth, with a pressed fern marking page two hundred and eleven. The ink had faded unevenly. Some sentences remained bold, while others survived only when the paper was tilted toward the lamp.",
      ]
      let longPassage = passages.joined(separator: " ")
      paragraphs = includeLongUnit ? passages + [longPassage] : passages
    }
    return paragraphs.flatMap { paragraph in
      NarrationUnitPlanner.chunks(
        for: NarrationParagraph(sentences: splitSentences(paragraph)))
    }
  }

  private static func seconds(_ duration: Duration) -> Double {
    let parts = duration.components
    return Double(parts.seconds) + Double(parts.attoseconds) / 1_000_000_000_000_000_000
  }

  private static func median(_ values: [Double]) -> Double {
    let values = values.sorted()
    guard !values.isEmpty else { return 0 }
    if values.count.isMultiple(of: 2) {
      return (values[values.count / 2 - 1] + values[values.count / 2]) / 2
    }
    return values[values.count / 2]
  }

  private static func fnv1a(_ data: Data, seed: UInt64) -> UInt64 {
    data.reduce(seed) { hash, byte in
      (hash ^ UInt64(byte)) &* 1_099_511_628_211
    }
  }
}

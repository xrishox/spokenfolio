import ArgumentParser
import Darwin
import EPUBKit
import Foundation
import ReadAloudKit

struct ReadAloudCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "readaloud",
    abstract: "Create and verify EPUB 3 Media Overlay books.",
    subcommands: [Create.self, Verify.self, Audit.self, Doctor.self, Tools.self])

  struct Create: AsyncParsableCommand {
    enum ASREngine: String, ExpressibleByArgument { case apple, whisper, synthesis }

    static let configuration = CommandConfiguration(
      abstract: "Align an EPUB and M4B into a sentence-level ReadAloud EPUB.")

    @Argument(help: "Source EPUB.", completion: .file(extensions: ["epub"]))
    var epub: String
    @Option(help: "Verified AAC M4B audiobook.", completion: .file(extensions: ["m4b"]))
    var audiobook: String
    @Option(name: .shortAndLong, help: "ReadAloud EPUB destination.")
    var output: String
    @Option(help: "Embedded Opus bitrate: 16, 32, 64, or 96 kbps.")
    var bitrate = 32
    @Option(help: "BCP-47 language (default: en-US).")
    var language = "en-US"
    @Option(
      name: .customLong("asr"),
      help:
        "Transcript source: synthesis (exact timing from the audiobook sidecar, default), apple, or whisper.")
    var asrEngine: ASREngine = .synthesis
    @Option(
      name: .customLong("whisper-model"),
      help: "Whisper model used by --asr whisper (default: large-v3-turbo).")
    var whisperModel: String?
    @Option(name: .customLong("work-dir"), help: "Resumable ReadAloud work directory.")
    var workDir: String?
    @Flag(help: "Replace an existing destination after successful verification.")
    var overwrite = false
    @Option(help: "Progress output: human or ndjson.")
    var progress: ProgressFormat = .human

    func run() async throws {
      let tools: ReadAloudToolchain
      do {
        tools = try await ReadAloudTools.resolve(managedStalign: AppPaths.managedStalignURL)
      } catch { throw CLIFailure(message: error.localizedDescription, exitCode: 69) }
      let sourceURL = URL(fileURLWithPath: (epub as NSString).expandingTildeInPath)
      let prepared: PreparedEPUB
      do {
        prepared = try await EPUBCompliance.prepare(source: sourceURL)
      } catch {
        throw CLIFailure(message: error.localizedDescription, exitCode: 65)
      }
      defer { prepared.cleanup() }
      let outputURL = URL(fileURLWithPath: (output as NSString).expandingTildeInPath)
      let work =
        workDir.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        ?? AppPaths.productionJobRoot.appendingPathComponent("readaloud-\(UUID().uuidString)")
      let asr: ReadAloudASRSettings
      switch asrEngine {
      case .apple:
        guard whisperModel == nil else {
          throw ValidationError("--whisper-model requires --asr whisper")
        }
        asr = .apple
      case .whisper:
        let modelID = whisperModel ?? ReadAloudWhisperModel.largeV3Turbo.rawValue
        guard let model = ReadAloudWhisperModel(rawValue: modelID) else {
          throw ValidationError("unsupported Whisper model '\(modelID)'")
        }
        asr = .whisper(model)
      case .synthesis:
        guard whisperModel == nil else {
          throw ValidationError("--whisper-model requires --asr whisper")
        }
        asr = .synthesis
      }
      let request = ReadAloudRequest(
        epubPath: prepared.url.path,
        audiobookPath: (audiobook as NSString).expandingTildeInPath,
        outputPath: outputURL.path, workDirectory: work.path,
        opusBitrateKbps: bitrate, language: language, asr: asr, overwrite: overwrite)
      let backend = StalignReadAloudBackend(tools: tools)
      do {
        let task = Task {
          try await backend.create(request: request) { value in
            switch progress {
            case .human:
              let percent = Int((value.overallFraction * 100).rounded())
              FileHandle.standardError.write(Data("\r\(percent)% — \(value.message)   ".utf8))
            case .ndjson:
              let object: [String: Any] = [
                "schemaVersion": 1, "stage": value.stage.rawValue,
                "fraction": value.overallFraction, "message": value.message,
              ]
              if let data = try? JSONSerialization.data(withJSONObject: object) {
                FileHandle.standardOutput.write(data + Data([0x0A]))
              }
            }
          }
        }
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        sigint.setEventHandler { task.cancel() }
        sigterm.setEventHandler { task.cancel() }
        sigint.resume()
        sigterm.resume()
        defer {
          sigint.cancel()
          sigterm.cancel()
        }
        let report = try await task.value
        if progress == .human {
          FileHandle.standardError.write(Data("\n".utf8))
          print(
            "Created \(outputURL.path) (\(report.smilCount) overlays, \(report.audioCount) Opus tracks)"
          )
        }
      } catch is CancellationError {
        throw CLIFailure(
          message: "ReadAloud creation interrupted; validated stages are saved", exitCode: 130)
      } catch {
        throw CLIFailure(message: error.localizedDescription, exitCode: 69)
      }
    }
  }

  struct Verify: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Verify a ReadAloud EPUB and embedded Opus audio.")
    @Argument(completion: .file(extensions: ["epub"])) var epub: String

    func run() async throws {
      let tools = try await ReadAloudTools.resolve(managedStalign: AppPaths.managedStalignURL)
      let report = try await ReadAloudVerifier.verifyPublished(
        epub: URL(fileURLWithPath: (epub as NSString).expandingTildeInPath),
        ffmpeg: tools.ffmpeg, ffprobe: tools.ffprobe, epubcheck: tools.epubcheck)
      print(
        "ok: EPUB \(report.epubConformance.epubVersion) via EPUBCheck "
          + "\(report.epubConformance.checkerVersion), \(report.smilCount) SMIL files, "
          + "\(report.audioCount) decoded Opus tracks")
    }
  }

  struct Audit: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Audit ReadAloud structure, content identity, and alignment timing.")

    @Argument(completion: .file(extensions: ["epub"])) var epub: String
    @Option(name: .customLong("source-epub"), completion: .file(extensions: ["epub"]))
    var sourceEPUB: String?
    @Option(name: .customLong("transcriptions"), completion: .directory)
    var transcriptions: String?
    @Option(name: .customLong("work-dir"), completion: .directory)
    var workDirectory: String?
    @Flag(help: "Transcribe all referenced audio instead of distributed samples.")
    var thorough = false
    @Flag(
      name: .customLong("no-fresh-asr"),
      help: "Skip independent ASR (normally inconclusive without bound transcripts).")
    var noFreshASR = false
    @Flag(
      name: .customLong("bound-transcriptions"),
      help: "Assert that supplied transcripts are provenance-bound to embedded audio.")
    var boundTranscriptions = false
    @Flag(help: "Emit the complete JSON report.") var json = false

    func run() async throws {
      let url = URL(fileURLWithPath: (epub as NSString).expandingTildeInPath)
      let report = try await ReadAloudAuditService().auditLocal(
        epub: url,
        sourceEPUB: sourceEPUB.map {
          URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)
        },
        mode: thorough ? .thorough : .standard,
        retainedTranscriptions: transcriptions.map {
          URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true)
        },
        retainedTranscriptionsAreBound: boundTranscriptions,
        workDirectory: workDirectory.map {
          URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true)
        }, useFreshASR: !noFreshASR
      ) { value in
        let percent = Int((value.fraction * 100).rounded())
        FileHandle.standardError.write(Data("\r\(percent)% — \(value.message)   ".utf8))
      }
      FileHandle.standardError.write(Data("\n".utf8))
      if json {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        FileHandle.standardOutput.write(try encoder.encode(report) + Data([0x0A]))
      } else {
        print("\(report.verdict.rawValue): \(report.evidenceAdequacy.rawValue) evidence")
        if let coverage = report.metrics.primaryCoverage {
          print(String(format: "primary overlay coverage: %.1f%%", coverage * 100))
        }
        for finding in report.findings.prefix(20) {
          print("- \(finding.code.rawValue): \(finding.summary)")
        }
      }
      if report.verdict == .broken || report.verdict == .likelyBroken {
        throw CLIFailure(message: "ReadAloud quality audit failed", exitCode: 65)
      }
    }
  }

  struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Check stalign and FFmpeg readiness.")
    func run() async throws {
      do {
        let tools = try await ReadAloudTools.resolve(managedStalign: AppPaths.managedStalignURL)
        print("ok: stalign \(tools.stalignVersion)")
        print("ok: \(tools.ffmpeg.path)")
        print("ok: \(tools.ffprobe.path)")
        print("ok: \(tools.epubcheckVersion)")
        if #available(macOS 26.0, *) {
          if let locale = await AppleSpeechReadAloudTranscriber.resolvedLocale("en-US") {
            print("ok: Apple Speech \(locale.identifier)")
          } else {
            print("unavailable: Apple Speech en-US (Whisper remains available)")
          }
        } else {
          print("unavailable: Apple Speech requires macOS 26 (Whisper remains available)")
        }
      } catch {
        throw CLIFailure(message: error.localizedDescription, exitCode: 69)
      }
    }
  }

  struct Tools: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Install the pinned stalign helper.", subcommands: [Install.self])
    struct Install: AsyncParsableCommand {
      static let configuration = CommandConfiguration(
        abstract: "Download and verify pinned stalign into Application Support.")
      func run() async throws {
        try await ReadAloudTools.installStalign(destination: AppPaths.managedStalignURL)
        print(
          "Installed stalign \(ReadAloudTools.pinnedStalignVersion) at \(AppPaths.managedStalignURL.path)"
        )
      }
    }
  }
}

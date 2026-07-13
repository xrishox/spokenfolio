import ArgumentParser
import Darwin
import Foundation
import ReadAloudKit

struct ReadAloudCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "readaloud",
    abstract: "Create and verify EPUB 3 Media Overlay books.",
    subcommands: [Create.self, Verify.self, Doctor.self, Tools.self])

  struct Create: AsyncParsableCommand {
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
      let outputURL = URL(fileURLWithPath: (output as NSString).expandingTildeInPath)
      let work =
        workDir.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        ?? AppPaths.productionJobRoot.appendingPathComponent("readaloud-\(UUID().uuidString)")
      let request = ReadAloudRequest(
        epubPath: (epub as NSString).expandingTildeInPath,
        audiobookPath: (audiobook as NSString).expandingTildeInPath,
        outputPath: outputURL.path, workDirectory: work.path,
        opusBitrateKbps: bitrate, language: language, overwrite: overwrite)
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
        ffprobe: tools.ffprobe)
      print("ok: \(report.smilCount) SMIL files, \(report.audioCount) decoded Opus tracks")
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

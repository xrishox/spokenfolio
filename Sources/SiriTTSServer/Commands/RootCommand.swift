import ArgumentParser
import Darwin
import Foundation
import SiriTTSCore
import Vapor

struct RootCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "siri-tts-server",
    abstract: "Local Siri speech and audiobook tools.",
    subcommands: [Serve.self, Doctor.self, AudiobookCommand.self])

  static func dispatch(_ arguments: [String]) async {
    do {
      var command = try parseAsRoot(arguments)
      if var asyncCommand = command as? any AsyncParsableCommand {
        try await asyncCommand.run()
      } else {
        try command.run()
      }
    } catch let failure as CLIFailure {
      FileHandle.standardError.write(Data("error: \(failure.message)\n".utf8))
      Foundation.exit(failure.exitCode)
    } catch {
      exit(withError: error)
    }
  }

  struct Serve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Run the HTTP gateway in foreground.")

    func run() async throws {
      do {
        let app = try await makeServerApplication(config: ServerConfig.load())
        try await app.execute()
        try await app.asyncShutdown()
      } catch let error as ServiceError {
        throw CLIFailure(message: error.message, exitCode: EX_UNAVAILABLE)
      } catch let error as CLIFailure {
        throw error
      } catch {
        throw CLIFailure(message: "startup failed: \(error.localizedDescription)", exitCode: EX_SOFTWARE)
      }
    }
  }

  struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Diagnose platform, voices, and permissions.")

    func run() throws {
      var failures = 0
      if #available(macOS 15, *) {
        print("ok: macOS 15 or newer")
      } else {
        print("FAIL: macOS 15 or newer is required")
        failures += 1
      }
      #if arch(arm64)
        print("ok: Apple Silicon")
      #else
        print("FAIL: Apple Silicon is required")
        failures += 1
      #endif
      let voices = SiriVoiceCatalog.discover()
      if voices.isEmpty {
        print("FAIL: no compatible installed 48 kHz Siri voice")
        failures += 1
      } else {
        print("ok: \(voices.count) compatible Siri voice variant(s)")
        for voice in voices { print("  \(voice.id)") }
      }
      do {
        try SiriPermissionPreflight.verifyModelAccess()
        print("ok: Siri shared model access")
      } catch ServiceError.permissionRequired {
        print("FAIL: Full Disk Access is required for Siri shared models")
        failures += 1
      } catch {
        print("FAIL: Siri shared models are unavailable")
        failures += 1
      }
      if failures != 0 { throw ExitCode.failure }
    }
  }
}

import AppKit
import Darwin
import Foundation
import Vapor

@main
enum Entrypoint {
  static func main() async {
    if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--siri-worker" {
      SiriWorkerMain.run(voiceID: CommandLine.arguments[2])
    }

    if CommandLine.arguments.dropFirst().contains("doctor") {
      runDoctor()
      return
    }

    if CommandLine.arguments.dropFirst().contains("serve") {
      await runForegroundServer()
      return
    }

    await MainActor.run { MenuBarApplication.run() }
  }

  private static func runForegroundServer() async {
    do {
      let app = try await makeServerApplication(config: ServerConfig.load())
      try await app.execute()
      try await app.asyncShutdown()
    } catch let error as ServiceError {
      FileHandle.standardError.write(Data("siri-tts-server: \(error.message)\n".utf8))
      _exit(EX_UNAVAILABLE)
    } catch {
      FileHandle.standardError.write(Data("siri-tts-server: startup failed\n".utf8))
      _exit(EX_SOFTWARE)
    }
  }

  private static func runDoctor() {
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
    exit(failures == 0 ? EXIT_SUCCESS : EXIT_FAILURE)
  }
}

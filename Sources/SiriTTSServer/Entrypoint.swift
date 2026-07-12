import AppKit
import Darwin
import Foundation
import SiriTTSCore
import Vapor

@main
enum Entrypoint {
  /// Deliberately synchronous: NSApplication.run() must be entered from a
  /// plain main() frame. An async main runs everything inside the Swift
  /// concurrency executor, which leaves AppKit's launch sequence incomplete —
  /// the process never becomes properly activatable, and clicks into its
  /// windows and open-panel sheets are swallowed by failed activation.
  static func main() {
    // A worker dying mid-write must surface as EPIPE (handled: the client
    // replaces the worker), never as fatal SIGPIPE for the whole process.
    signal(SIGPIPE, SIG_IGN)

    if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--siri-worker" {
      SiriWorkerMain.run(voiceID: CommandLine.arguments[2])
    }

    if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "audiobook" {
      runBridgingMainRunLoop {
        await AudiobookCommand.dispatch(Array(CommandLine.arguments.dropFirst(2)))
      }
      return
    }

    if CommandLine.arguments.dropFirst().contains("doctor") {
      runDoctor()
      return
    }

    if CommandLine.arguments.dropFirst().contains("serve") {
      runBridgingMainRunLoop { await runForegroundServer() }
      return
    }

    MenuBarApplication.run()
  }

  /// Runs async work to completion while the main thread pumps its run
  /// loop, so main-actor jobs keep executing and the async work can never
  /// deadlock against a blocked main thread.
  private static func runBridgingMainRunLoop(_ work: @escaping @Sendable () async -> Void) {
    final class Flag: @unchecked Sendable {
      var done = false  // touched only on the main thread
    }
    let flag = Flag()
    Task.detached {
      await work()
      DispatchQueue.main.async {
        flag.done = true
        CFRunLoopStop(CFRunLoopGetMain())
      }
    }
    while !flag.done { CFRunLoopRun() }
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

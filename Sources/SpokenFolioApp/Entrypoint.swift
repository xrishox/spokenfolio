import AppKit
import Darwin
import Foundation
import SiriTTSCore

@main
enum Entrypoint {
  /// Deliberately synchronous: NSApplication.run() must be entered from a
  /// plain main() frame. Public CLI commands bridge async work while pumping
  /// the main run loop; the private worker mode bypasses ArgumentParser.
  static func main() {
    signal(SIGPIPE, SIG_IGN)

    if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--siri-worker" {
      SiriWorkerMain.run(voiceID: CommandLine.arguments[2])
    }
    guard CommandLine.arguments.count > 1 else {
      DesktopApplication.run()
      return
    }
    runBridgingMainRunLoop {
      await RootCommand.dispatch(Array(CommandLine.arguments.dropFirst()))
    }
  }

  private static func runBridgingMainRunLoop(_ work: @escaping @Sendable () async -> Void) {
    final class Flag: @unchecked Sendable { var done = false }
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
}

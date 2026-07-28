import Darwin
import Foundation
import TTSKit

package enum GoldenGateVoiceCatalog {
  private static let maximumCatalogBytes = 1 << 20

  package static func discover() throws -> [GoldenGateVoice] {
    guard #available(macOS 27, *) else { throw TTSBackendError.unavailable }
    let executable = ProcessInfo.processInfo.environment["SPOKENFOLIO_WORKER_EXECUTABLE"]
      .map { URL(fileURLWithPath: $0) }
      ?? Bundle.main.executableURL
      ?? URL(fileURLWithPath: CommandLine.arguments[0])
    let outputPipe = Pipe()
    let process = Process()
    process.executableURL = executable
    process.arguments = ["--golden-gate-catalog"]
    process.standardOutput = outputPipe
    process.standardError = FileHandle.standardError

    let completed = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in completed.signal() }
    do { try process.run() } catch {
      throw GoldenGateTTSError.catalogUnavailable(error.localizedDescription)
    }
    guard completed.wait(timeout: .now() + 20) == .success else {
      process.terminate()
      throw GoldenGateTTSError.catalogUnavailable("catalog child timed out")
    }
    let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
    guard process.terminationStatus == EXIT_SUCCESS,
      !data.isEmpty, data.count <= maximumCatalogBytes
    else {
      throw GoldenGateTTSError.catalogUnavailable(
        "catalog child exited with status \(process.terminationStatus)")
    }
    let voices = try JSONDecoder().decode([GoldenGateVoice].self, from: data)
    guard !voices.isEmpty else {
      throw GoldenGateTTSError.catalogUnavailable("catalog child returned no voices")
    }
    return voices
  }
}

package enum GoldenGateCatalogMain {
  package static func run() -> Never {
    do {
      let runtime = try GoldenGatePrivateTTSRuntime()
      let voices = try runtime.voices().map(\.descriptor)
      let data = try JSONEncoder().encode(voices)
      try FileHandle.standardOutput.write(contentsOf: data)
      _exit(EXIT_SUCCESS)
    } catch {
      FileHandle.standardError.write(Data("golden-gate-catalog: \(error)\n".utf8))
      _exit(EX_UNAVAILABLE)
    }
  }
}

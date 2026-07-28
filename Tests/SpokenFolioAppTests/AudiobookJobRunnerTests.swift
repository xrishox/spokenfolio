import AudiobookKit
import Darwin
import TTSKit
import XCTest

@testable import SpokenFolioApp

/// Exercises the GUI's synthesis backend — the spawned `audiobook create
/// --progress ndjson` child — against the real built binary, so the exact
/// production path is covered headlessly.
@MainActor
final class AudiobookJobRunnerTests: XCTestCase {
  func testDurableRunnerResolvesInjectedOrBundledExecutable() {
    let bundled = URL(fileURLWithPath: "/Applications/Test.app/Contents/MacOS/test")
    let injected = URL(fileURLWithPath: "/tmp/injected-runner")
    XCTAssertEqual(
      BookJobProcessRunner.resolveExecutable(override: nil, bundleExecutable: bundled), bundled)
    XCTAssertEqual(
      BookJobProcessRunner.resolveExecutable(override: injected, bundleExecutable: bundled),
      injected)
  }

  func testClosedProgressPipeDoesNotCrashWriter() {
    signal(SIGPIPE, SIG_IGN)
    let pipe = Pipe()
    try? pipe.fileHandleForReading.close()
    let writer = NDJSONProgressWriter(output: pipe.fileHandleForWriting)
    writer.render(.warning("parent disappeared"))
    writer.render(.warning("subsequent output remains disabled"))
  }

  func testClosedStderrPipeDoesNotCrashFinalDiagnostic() {
    signal(SIGPIPE, SIG_IGN)
    let pipe = Pipe()
    try? pipe.fileHandleForReading.close()
    XCTAssertFalse(
      CLIFileOutput.write(Data("error: cancelled\n".utf8), to: pipe.fileHandleForWriting))
  }
  /// The server binary sits beside the xctest bundle in the build products.
  static let builtBinary = Bundle(for: AudiobookJobRunnerTests.self)
    .bundleURL.deletingLastPathComponent().appendingPathComponent("spokenfolio")

  private func requireBinaryAndBook() throws -> (binary: URL, epub: URL) {
    guard FileManager.default.isExecutableFile(atPath: Self.builtBinary.path) else {
      throw XCTSkip("built spokenfolio not found beside the test bundle")
    }
    guard let path = ProcessInfo.processInfo.environment["AUDIOBOOK_TEST_EPUB"] else {
      throw XCTSkip("AUDIOBOOK_TEST_EPUB not set")
    }
    return (Self.builtBinary, URL(fileURLWithPath: path))
  }

  func testFailureCarriesChildErrorText() async throws {
    let (binary, epub) = try requireBinaryAndBook()
    let runner = AudiobookJobRunner(executable: binary)
    do {
      for try await _ in runner.run(arguments: [
        epub.path, "--voice", "definitely-not-a-voice-xyz",
        "--output", FileManager.default.temporaryDirectory
          .appendingPathComponent("runner-fail-\(UUID().uuidString).m4b").path,
      ]) {}
      XCTFail("run with a nonexistent voice must fail")
    } catch let failure as AudiobookJobRunner.Failure {
      XCTAssertEqual(failure.exitCode, 69)
      XCTAssertTrue(
        failure.errorDescription?.contains("not installed") == true
          || failure.errorDescription?.contains("ambiguous") == true,
        "expected the CLI's own message, got: \(failure.errorDescription ?? "nil")")
    }
  }

  func testSpawnFailureSurfacesImmediately() async {
    let runner = AudiobookJobRunner(executable: URL(fileURLWithPath: "/nonexistent/binary"))
    do {
      for try await _ in runner.run(arguments: ["/nonexistent.epub"]) {}
      XCTFail("spawn of a nonexistent binary must fail")
    } catch let failure as AudiobookJobRunner.Failure {
      XCTAssertTrue(failure.stderrTail.contains("could not start"))
    } catch {
      XCTFail("unexpected error type: \(error)")
    }
  }

  // MARK: - Stub children: every termination shape, no Siri/EPUB required

  private func stubChild(_ script: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("runner-stub-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("stub.sh")
    try Data(("#!/bin/bash\n" + script + "\n").utf8).write(to: url)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
  }

  private static var startedLine: String {
    let provenance = try! TTSRuntimeProvenance(
      backendID: TTSBackendID(rawValue: "siri"), modelID: "siri-private",
      voiceID: "voice",
      operatingSystemVersion: "27.0", operatingSystemBuild: "26A1",
      frameworkIdentifier: "test.framework", frameworkVersion: "1")
    let event = AudiobookProgressEvent.started(
      totalChapters: 1, totalCharacters: 10, reusedChapters: 0,
      chapterCharacters: [10], runtimeProvenance: provenance)
    return String(
      decoding: try! JSONEncoder().encode(ProgressEventWire(event)), as: UTF8.self)
  }

  /// Exit 0 without a `.finished` event is a protocol violation, never
  /// success: a truncated stream must not produce a "Done" screen.
  func testExitZeroWithoutFinishedIsFailure() async throws {
    let stub = try stubChild("echo '\(Self.startedLine)'")
    let runner = AudiobookJobRunner(executable: stub)
    do {
      for try await _ in runner.run(arguments: []) {}
      XCTFail("exit 0 without .finished must fail")
    } catch let failure as AudiobookJobRunner.Failure {
      XCTAssertEqual(failure.exitCode, 0)
    }
  }

  /// Cancel before the child installs its SIGINT handler kills it by
  /// signal (status 2, uncaughtSignal) — still the user's cancel, never
  /// "exited with status 2".
  func testSignalDeathAfterCancelIsCancellation() async throws {
    let stub = try stubChild("sleep 300")
    let runner = AudiobookJobRunner(executable: stub)
    Task {
      try? await Task.sleep(for: .milliseconds(300))
      runner.cancel()
    }
    do {
      for try await _ in runner.run(arguments: []) {}
      XCTFail("signal death must not end as success")
    } catch is CancellationError {
      // expected
    } catch {
      XCTFail("signal death surfaced as \(error), expected CancellationError")
    }
  }

  func testDirectConsumerTaskCancellationMapsToCancellation() async throws {
    let stub = try stubChild(
      "trap 'exit 130' INT\n"
        + "echo '\(Self.startedLine)'\n"
        + "while true; do echo 'child diagnostic' >&2; sleep 0.05; done")
    let runner = AudiobookJobRunner(executable: stub)
    let task = Task {
      for try await _ in runner.run(arguments: []) {
        withUnsafeCurrentTask { $0?.cancel() }
      }
      // AsyncThrowingStream cancellation may end iteration normally; the
      // durable executor's post-loop check must preserve task cancellation.
      try Task.checkCancellation()
    }
    do {
      try await task.value
      XCTFail("direct task cancellation must not report success")
    } catch is CancellationError {
      // expected
    }
  }

  /// A malformed stdout line must fail fast and stop the child — not sit
  /// behind an undrained pipe until the book finishes.
  func testMalformedLineFailsFastAndStopsChild() async throws {
    let stub = try stubChild("echo 'not json at all'; sleep 300")
    let runner = AudiobookJobRunner(executable: stub)
    let begun = Date()
    do {
      for try await _ in runner.run(arguments: []) {}
      XCTFail("malformed line must fail the run")
    } catch let failure as AudiobookJobRunner.Failure {
      XCTAssertTrue(failure.stderrTail.contains("unreadable progress event"))
      XCTAssertLessThan(
        Date().timeIntervalSince(begun), 20,
        "runner waited on the sleeping child instead of stopping it")
    }
  }

  /// The writer escapes U+2028/U+2029/U+0085 (JSONEncoder leaves them raw,
  /// and line-oriented readers split on them); the runner decodes the
  /// escapes back losslessly from one physical line.
  func testUnicodeLineBreaksStayOnOneLine() async throws {
    let title = "Line\u{2028}Sep\u{2029}Para\u{0085}NEL"

    // Writer side: encode through the real NDJSON writer into a pipe; the
    // event must occupy exactly one 0x0A-terminated line.
    let pipe = Pipe()
    let writer = NDJSONProgressWriter(output: pipe.fileHandleForWriting)
    writer.render(.chapterStarted(index: 0, title: title))
    try pipe.fileHandleForWriting.close()
    let written = pipe.fileHandleForReading.readDataToEndOfFile()
    let jsonLines = written.split(separator: UInt8(ascii: "\n"))
    XCTAssertEqual(jsonLines.count, 1, "event must be a single physical line")

    // Reader side: a stub child replays that exact line; the decoded event
    // must carry the original separators.
    let wireLine = String(decoding: jsonLines[0], as: UTF8.self)
    let stub = try stubChild("echo '" + wireLine + "'\nexit 7")
    let runner = AudiobookJobRunner(executable: stub)
    var titles: [String] = []
    do {
      for try await event in runner.run(arguments: []) {
        if case .chapterStarted(_, let received) = event { titles.append(received) }
      }
    } catch {}
    XCTAssertEqual(titles, [title], "escaped separators must decode losslessly")
  }

  /// Real synthesis of a one-chapter run through the child: full event
  /// sequence, clean stream end, valid output file.
  func testSmallRunCompletesWithOrderedEvents() async throws {
    guard ProcessInfo.processInfo.environment["AUDIOBOOK_TEST_E2E"] == "1" else {
      throw XCTSkip("AUDIOBOOK_TEST_E2E not set")
    }
    let (binary, epub) = try requireBinaryAndBook()
    let output = FileManager.default.temporaryDirectory
      .appendingPathComponent("runner-e2e-\(UUID().uuidString).m4b")
    defer { try? FileManager.default.removeItem(at: output) }

    let runner = AudiobookJobRunner(executable: binary)
    var sawStarted = false
    var sawUnit = false
    var sawChapterCompleted = false
    var sawAssembly = false
    var sawFinished = false
    for try await event in runner.run(arguments: [
      epub.path, "--output", output.path, "--overwrite",
      "--workers", "1", "--max-chapters", "1",
    ]) {
      switch event {
      case .started(let chapters, let characters, _, let perChapter, _):
        sawStarted = true
        XCTAssertEqual(chapters, 1)
        XCTAssertEqual(perChapter.count, 1)
        XCTAssertGreaterThan(characters, 0)
      case .unitCompleted:
        XCTAssertTrue(sawStarted, ".unitCompleted before .started")
        sawUnit = true
      case .chapterCompleted:
        sawChapterCompleted = true
      case .assemblyStarted:
        XCTAssertTrue(sawChapterCompleted, "assembly before any chapter completed")
        sawAssembly = true
      case .finished(let url):
        sawFinished = true
        XCTAssertEqual(url.path, output.path)
      default:
        break
      }
    }
    XCTAssertTrue(sawStarted && sawUnit && sawAssembly && sawFinished, "missing pipeline events")
    let size = (try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int) ?? 0
    XCTAssertGreaterThan(size, 10_000, "output M4B is implausibly small")
  }

  /// SIGINT mid-run must surface as CancellationError (exit 130), never as
  /// success and never as a generic failure.
  func testCancelMapsToCancellationError() async throws {
    guard ProcessInfo.processInfo.environment["AUDIOBOOK_TEST_E2E"] == "1" else {
      throw XCTSkip("AUDIOBOOK_TEST_E2E not set")
    }
    let (binary, epub) = try requireBinaryAndBook()
    let output = FileManager.default.temporaryDirectory
      .appendingPathComponent("runner-cancel-\(UUID().uuidString).m4b")
    defer { try? FileManager.default.removeItem(at: output) }

    let runner = AudiobookJobRunner(executable: binary)
    do {
      for try await event in runner.run(arguments: [
        epub.path, "--output", output.path, "--overwrite", "--workers", "1", "--force",
      ]) {
        if case .unitCompleted = event { runner.cancel() }
      }
      XCTFail("cancelled run must not end as success")
    } catch is CancellationError {
      XCTAssertFalse(
        FileManager.default.fileExists(atPath: output.path),
        "no partial output file may exist after cancellation")
    }
  }
}

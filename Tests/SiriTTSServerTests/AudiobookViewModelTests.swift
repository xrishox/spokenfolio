import XCTest

@testable import SiriTTSServer

/// Drives the Create Audiobook view model headlessly through the same code
/// path the window uses, so a stuck "loading" state is reproducible without
/// clicking through the GUI.
@MainActor
final class AudiobookViewModelTests: XCTestCase {
  private func testEPUB() throws -> URL {
    guard let path = ProcessInfo.processInfo.environment["AUDIOBOOK_TEST_EPUB"] else {
      throw XCTSkip("AUDIOBOOK_TEST_EPUB not set")
    }
    return URL(fileURLWithPath: path)
  }

  private func loadToConfigure(
    _ model: AudiobookViewModel, url: URL, timeout: TimeInterval = 30
  ) async throws {
    model.loadBook(at: url)
    let deadline = Date().addingTimeInterval(timeout)
    while model.isLoadingBook, Date() < deadline {
      await Task.yield()
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertFalse(model.isLoadingBook, "loading never completed — the spinner would be stuck")
  }

  func testLoadBookReachesConfigureOrFails() async throws {
    let model = AudiobookViewModel()
    try await loadToConfigure(model, url: try testEPUB())
    switch model.phase {
    case .configure:
      XCTAssertFalse(model.sections.isEmpty)
      XCTAssertFalse(model.voices.isEmpty)
      XCTAssertNotNil(model.outputURL)
    case .failed(let message):
      XCTFail("load failed: \(message)")
    default:
      XCTFail("unexpected phase after load")
    }
  }

  func testLoadAndResetBumpGeneration() async throws {
    let model = AudiobookViewModel()
    let g0 = model.generation
    model.loadBook(at: URL(fileURLWithPath: "/nonexistent/never.epub"))
    XCTAssertGreaterThan(model.generation, g0, "loadBook must invalidate prior continuations")
    let g1 = model.generation
    model.reset()
    XCTAssertGreaterThan(model.generation, g1, "reset must invalidate prior continuations")
  }

  /// The regression this guards: a load-timeout watchdog armed by book A
  /// firing during book B's load and failing it. Load A's watchdog is armed
  /// at t=0 with a 1.2 s fuse; B (a real book, several hundred ms to read)
  /// starts at t≈0.7 s, so A's watchdog fires while B is still loading — but
  /// B's own watchdog (t≈1.9 s) stays in the future. Without the generation
  /// token, A's watchdog fails B; with it, B must reach `.configure`.
  func testStaleLoadTimeoutDoesNotKillNextLoad() async throws {
    let epub = try testEPUB()
    let model = AudiobookViewModel(loadTimeout: .milliseconds(1_200))

    model.loadBook(at: URL(fileURLWithPath: "/nonexistent/never.epub"))
    let failDeadline = Date().addingTimeInterval(10)
    while model.isLoadingBook, Date() < failDeadline {
      await Task.yield()
      try await Task.sleep(for: .milliseconds(10))
    }
    guard case .failed = model.phase else {
      XCTFail("nonexistent EPUB should fail fast; phase is \(model.phase)")
      return
    }

    try await Task.sleep(for: .milliseconds(700))
    model.reset()
    try await loadToConfigure(model, url: epub)
    guard case .configure = model.phase else {
      XCTFail("stale timeout from the first load killed the second: \(model.phase)")
      return
    }
    // Outlast B's own watchdog too: the phase must stay settled.
    try await Task.sleep(for: .milliseconds(1_400))
    guard case .configure = model.phase else {
      XCTFail("a watchdog fired after the load completed: \(model.phase)")
      return
    }
  }

  func testResetClearsAllBookAndProgressState() async throws {
    let model = AudiobookViewModel()
    try await loadToConfigure(model, url: try testEPUB())
    guard case .configure = model.phase else {
      throw XCTSkip("book did not load; covered by testLoadBookReachesConfigureOrFails")
    }

    model.reset()

    guard case .pickBook = model.phase else {
      XCTFail("reset must return to pickBook; got \(model.phase)")
      return
    }
    XCTAssertEqual(model.bookTitle, "")
    XCTAssertEqual(model.bookAuthor, "")
    XCTAssertNil(model.coverImage)
    XCTAssertEqual(model.chapterPreviewCount, 0)
    XCTAssertTrue(model.sections.isEmpty)
    XCTAssertTrue(model.voices.isEmpty)
    XCTAssertEqual(model.selectedVoiceID, "")
    XCTAssertNil(model.outputURL)
    XCTAssertNil(model.epubURL)
    XCTAssertEqual(model.progressText, "")
    XCTAssertEqual(model.progressFraction, 0)
    XCTAssertEqual(model.currentChapterText, "")
    XCTAssertFalse(model.isLoadingBook)
    XCTAssertEqual(model.loadingBookName, "")
    XCTAssertTrue(model.chapterCharacters.isEmpty)
    XCTAssertEqual(model.completedCharacters, 0)
    XCTAssertEqual(model.totalCharacters, 0)
    XCTAssertEqual(model.totalChapters, 0)
    XCTAssertEqual(model.currentChapterNumber, 0)
    XCTAssertEqual(model.currentChapterTitle, "")
    XCTAssertEqual(model.chapterUnitsDone, 0)
    XCTAssertEqual(model.chapterUnitsTotal, 0)
    XCTAssertEqual(model.reusedChapters, 0)
    XCTAssertFalse(model.isAssembling)
    XCTAssertNil(model.synthesisStartedAt)
    XCTAssertEqual(model.runCompletedCharacters, 0)
    XCTAssertEqual(model.partialRunCharacters, 0)
    XCTAssertNil(model.permissionWarning)
  }

  func testRequestBookPickerGuards() {
    let model = AudiobookViewModel()
    var presentations = 0
    model.presentOpenPanel = { completion in
      presentations += 1
      completion(nil)  // user cancels
    }
    model.requestBookPicker()
    XCTAssertEqual(presentations, 1, "pickBook phase should present the chooser")
    // Cancelling leaves the model on pickBook, able to present again — the
    // model holds no latch that could wedge the button.
    model.requestBookPicker()
    XCTAssertEqual(presentations, 2)

    model.loadBook(at: URL(fileURLWithPath: "/nonexistent/never.epub"))
    model.requestBookPicker()
    XCTAssertEqual(presentations, 2, "no chooser while a book is loading")
  }

  /// Real end-to-end run through the GUI's own state machine and its real
  /// backend — the spawned CLI child: loads the test EPUB, narrows it to its
  /// smallest non-empty section, synthesizes with a real Siri worker, and
  /// asserts the progress fields the window displays (percent, "Chapter x of
  /// y", fraction) actually move and finish at 100%.
  func testEndToEndRunReportsProgress() async throws {
    guard ProcessInfo.processInfo.environment["AUDIOBOOK_TEST_E2E"] == "1" else {
      throw XCTSkip("AUDIOBOOK_TEST_E2E not set")
    }
    let epub = try testEPUB()
    let binary = AudiobookJobRunnerTests.builtBinary
    guard FileManager.default.isExecutableFile(atPath: binary.path) else {
      throw XCTSkip("built siri-tts-server not found beside the test bundle")
    }

    let model = AudiobookViewModel(jobExecutable: binary)
    try await loadToConfigure(model, url: epub)
    guard case .configure = model.phase else {
      XCTFail("could not reach configure: \(model.phase)")
      return
    }

    // Keep the run short: only the smallest non-empty included section.
    let included = model.sections.filter { $0.included && $0.characterCount > 0 }
    guard let smallest = included.min(by: { $0.characterCount < $1.characterCount }) else {
      XCTFail("no non-empty included sections in test EPUB")
      return
    }
    for index in model.sections.indices {
      model.sections[index].included = model.sections[index].id == smallest.id
    }
    model.workers = 1

    let output = FileManager.default.temporaryDirectory
      .appendingPathComponent("audiobook-e2e-\(UUID().uuidString).m4b")
    model.outputURL = output
    defer { try? FileManager.default.removeItem(at: output) }

    model.start()
    guard case .running = model.phase else {
      XCTFail("start() did not enter running: \(model.phase)")
      return
    }

    var sawChapterNumber = false
    var sawNonzeroPercent = false
    let deadline = Date().addingTimeInterval(600)
    while Date() < deadline {
      if case .running = model.phase {
        if model.currentChapterNumber > 0 { sawChapterNumber = true }
        if model.percentText != "0%" { sawNonzeroPercent = true }
        try await Task.sleep(for: .milliseconds(100))
      } else {
        break
      }
    }

    switch model.phase {
    case .done(let url):
      XCTAssertEqual(url, output)
      XCTAssertEqual(model.progressFraction, 1, accuracy: 0.0001)
      XCTAssertTrue(sawChapterNumber, "GUI never showed 'Chapter x of y' during the run")
      XCTAssertTrue(sawNonzeroPercent, "GUI percent never moved off 0%")
      let size = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int)
        .flatMap { $0 } ?? 0
      XCTAssertGreaterThan(size, 10_000, "output M4B is implausibly small")
    case .running:
      XCTFail("run did not finish within 10 minutes")
    case .failed(let message):
      XCTFail("run failed: \(message)")
    default:
      XCTFail("unexpected phase \(model.phase)")
    }
  }
}

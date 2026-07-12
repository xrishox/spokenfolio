import AppKit
import AudiobookKit
import EPUBKit
import Foundation
import Observation
import SiriTTSCore
import TTSKit
import os

/// Drives the Create Audiobook window: pick → configure → run → done.
/// Synthesis runs in a detached task with its own worker pool (never the
/// HTTP server's), so a running server and a running book job coexist.
@MainActor
@Observable
final class AudiobookViewModel {
  enum Phase {
    case pickBook
    case configure
    case running
    case done(URL)
    case failed(String)
  }

  struct SectionRow: Identifiable {
    let id: Int
    let title: String
    let role: String
    let characterCount: Int
    let includedByDefault: Bool
    /// The reconciled plan's verdict at load time — the baseline the user's
    /// checkbox edits are diffed against when building CLI overrides. Using
    /// the role default here instead would silently drop a user's re-include
    /// of a section the plan had excluded.
    let initiallyIncluded: Bool
    var included: Bool
  }

  private(set) var phase: Phase = .pickBook
  private(set) var bookTitle = ""
  private(set) var bookAuthor = ""
  private(set) var coverImage: NSImage?
  private(set) var chapterPreviewCount = 0
  var sections: [SectionRow] = []
  var voices: [VoiceDescriptor] = []
  var selectedVoiceID = ""
  var bitrateKbps = 256
  var workers = AudiobookConfig.autoMaxWorkers
  var announceTitles = true
  var paragraphPause = 0.6
  var chapterPause = 1.75
  var outputURL: URL?

  private(set) var progressText = ""
  private(set) var progressFraction = 0.0
  private(set) var currentChapterText = ""
  private(set) var isLoadingBook = false
  private(set) var loadingBookName = ""

  /// Invalidation token for every async continuation (load result, load
  /// timeout, run completion). Bumped whenever the model starts a new
  /// lifecycle — reset, a new load, a new run — so a stale continuation from
  /// a previous lifecycle cannot touch state. Deliberately not bumped by
  /// `cancel()`: the cancelled run's own completion must still land.
  private(set) var generation = 0

  /// Injected by the window controller: present the EPUB chooser / save
  /// panel as sheets on the real window. Sheets on a shown window always
  /// present (unlike a free-floating panel in an accessory app), and the
  /// only re-entry guard is AppKit's own attached-sheet state, so a failed
  /// presentation cannot leave a stuck flag behind.
  var presentOpenPanel: (@MainActor (@escaping @MainActor (URL?) -> Void) -> Void)?
  var presentSavePanel: (@MainActor (URL?, @escaping @MainActor (URL?) -> Void) -> Void)?

  /// Set when the Siri model directory is unreadable (missing Full Disk
  /// Access); shown as a banner on the configure screen so a doomed run is
  /// flagged before Start.
  private(set) var permissionWarning: String?

  /// Fired (already dispatched) at most ~1/s while a job runs, so the menu
  /// bar can mirror progress without any code running inside menu tracking.
  var onProgressChange: (() -> Void)?

  private let loadTimeout: Duration
  private let runStartTimeout: Duration
  private let jobExecutable: URL?
  private var runner: AudiobookJobRunner?
  private var lastProgressPush = Date.distantPast
  /// Any decoded child event counts as liveness for the run-start watchdog
  /// (warnings can legitimately precede `.started` on a big resume).
  private var runSawEvent = false
  private var configuredWorkDirectory: String?

  init(
    loadTimeout: Duration = .seconds(60),
    runStartTimeout: Duration = .seconds(90),
    jobExecutable: URL? = nil
  ) {
    self.loadTimeout = loadTimeout
    self.runStartTimeout = runStartTimeout
    self.jobExecutable = jobExecutable
  }

  /// Breadcrumbs for `log show --predicate 'process == "siri-tts-server"'`;
  /// never logs book text.
  private static let log = Logger(
    subsystem: "com.xrishox.macos-tts-server", category: "audiobook-gui")

  var isJobRunning: Bool {
    if case .running = phase { return true }
    return false
  }
  var onJobStateChange: (() -> Void)?

  private(set) var epubURL: URL?
  private var runTask: Task<Void, Never>?
  private(set) var chapterCharacters: [Int] = []
  private(set) var completedCharacters = 0
  private(set) var totalCharacters = 0

  // Progress-display state (set from pipeline events).
  private(set) var totalChapters = 0
  private(set) var currentChapterNumber = 0
  private(set) var currentChapterTitle = ""
  private(set) var chapterUnitsDone = 0
  private(set) var chapterUnitsTotal = 0
  private(set) var reusedChapters = 0
  private(set) var isAssembling = false
  private(set) var synthesisStartedAt: Date?
  private(set) var runCompletedCharacters = 0.0
  private(set) var partialRunCharacters = 0.0

  /// Returns the model to a pristine pick-a-book state. Everything derived
  /// from a previous book or run is cleared; only user preferences that carry
  /// across books (bitrate, workers, announce, pauses) and controller wiring
  /// (`onJobStateChange`, `presentSavePanel`) survive.
  func reset() {
    generation += 1
    runner?.cancel()
    runner = nil
    runTask?.cancel()
    runTask = nil
    phase = .pickBook
    permissionWarning = nil
    bookTitle = ""
    bookAuthor = ""
    coverImage = nil
    chapterPreviewCount = 0
    sections = []
    voices = []
    selectedVoiceID = ""
    outputURL = nil
    epubURL = nil
    progressText = ""
    progressFraction = 0
    currentChapterText = ""
    isLoadingBook = false
    loadingBookName = ""
    chapterCharacters = []
    completedCharacters = 0
    totalCharacters = 0
    totalChapters = 0
    currentChapterNumber = 0
    currentChapterTitle = ""
    chapterUnitsDone = 0
    chapterUnitsTotal = 0
    reusedChapters = 0
    isAssembling = false
    synthesisStartedAt = nil
    runCompletedCharacters = 0
    partialRunCharacters = 0
    notifyJobStateChange()
  }

  /// Opens the EPUB chooser when the model is ready for one. Safe to call
  /// repeatedly (menu action, window show, Choose button): while a sheet is
  /// already attached the controller ignores the request.
  func requestBookPicker() {
    guard case .pickBook = phase, !isLoadingBook else { return }
    Self.log.info("requestBookPicker: presenting EPUB chooser")
    presentOpenPanel? { [weak self] url in
      guard let self else { return }
      guard let url else {
        Self.log.info("EPUB chooser cancelled")
        return
      }
      guard case .pickBook = self.phase else { return }
      self.loadBook(at: url)
    }
  }

  /// Lets the user re-choose the output path via the controller-injected
  /// save-panel sheet.
  func chooseOutput() {
    guard case .configure = phase else { return }
    presentSavePanel?(outputURL) { [weak self] url in
      guard let self, let url, case .configure = self.phase else { return }
      self.outputURL = url
    }
  }

  func loadBook(at url: URL) {
    guard !isLoadingBook else { return }
    generation += 1
    let g = generation
    isLoadingBook = true
    loadingBookName = url.lastPathComponent
    epubURL = url
    Self.log.info("loadBook started")

    let appConfig: AppConfig
    do {
      appConfig = try AppConfig.load()
    } catch {
      isLoadingBook = false
      phase = .failed("Invalid configuration: \(error.localizedDescription)")
      return
    }
    let config = appConfig.audiobook
    let configuredVoice = config.defaultVoice ?? appConfig.server.defaultVoice
    configuredWorkDirectory = config.workDirectory
    bitrateKbps = config.defaultBitrateKbps
    workers = config.resolvedMaxWorkers
    announceTitles = config.announceTitles
    paragraphPause = config.paragraphPauseSeconds
    chapterPause = config.chapterPauseSeconds

    // A stuck spinner is never acceptable: whatever goes wrong below must
    // surface as a failure state within the timeout. The generation check
    // keeps a watchdog armed by one load from failing a later one.
    Task { [weak self, loadTimeout] in
      try? await Task.sleep(for: loadTimeout)
      guard let self, self.generation == g, self.isLoadingBook else { return }
      Self.log.error("loadBook timed out")
      self.isLoadingBook = false
      self.phase = .failed(
        "Reading the book took more than a minute and was abandoned. "
          + "Try again, and check Console for 'audiobook-gui' messages if it repeats.")
    }

    Task.detached { [weak self] in
      do {
        let publication = try EPUBImporter().load(url: url)
        let plan = try AudiobookPlanner.plan(publication: publication)
        let backend = try SiriTTSBackend(defaultVoice: configuredVoice)
        let permissionProblem: String?
        do {
          try SiriPermissionPreflight.verifyModelAccess()
          permissionProblem = nil
        } catch {
          permissionProblem =
            "Full Disk Access is required to read Apple's Siri voice models. "
            + "Grant it to Siri TTS Server in System Settings before starting."
        }
        await MainActor.run { [weak self] in
          guard let self, self.generation == g, self.isLoadingBook else { return }
          Self.log.info(
            "loadBook finished: \(plan.chapters.count) chapters, \(backend.voices.count) voices")
          self.permissionWarning = permissionProblem
          self.bookLoaded(
            plan: plan, voices: backend.voices, defaultVoice: backend.defaultVoice)
        }
      } catch {
        let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        await MainActor.run { [weak self] in
          guard let self, self.generation == g, self.isLoadingBook else { return }
          Self.log.error("loadBook failed: \(message, privacy: .public)")
          self.isLoadingBook = false
          self.phase = .failed("Could not open this EPUB: \(message)")
        }
      }
    }
  }

  private func bookLoaded(
    plan: AudiobookPlan, voices: [VoiceDescriptor], defaultVoice: VoiceKey
  ) {
    isLoadingBook = false
    guard !voices.isEmpty else {
      phase = .failed(
        "No compatible Siri voices are installed. Download one in System Settings, then try again.")
      return
    }
    bookTitle = plan.metadata.title
    bookAuthor = plan.metadata.author ?? ""
    coverImage = plan.cover.map { NSImage(data: $0.data) } ?? nil
    chapterPreviewCount = plan.chapters.count
    sections = plan.sections.map {
      SectionRow(
        id: $0.index, title: $0.title, role: $0.role.rawValue,
        characterCount: $0.characterCount, includedByDefault: $0.includedByDefault,
        initiallyIncluded: $0.included, included: $0.included)
    }
    self.voices = voices
    selectedVoiceID = defaultVoice.voiceID
    outputURL = defaultOutputURL(plan: plan)
    phase = .configure
  }

  private func defaultOutputURL(plan: AudiobookPlan) -> URL? {
    guard let epubURL else { return nil }
    let author = plan.metadata.author.map { " - \($0)" } ?? ""
    return epubURL.deletingLastPathComponent()
      .appendingPathComponent(sanitizeFilename("\(plan.metadata.title)\(author)") + ".m4b")
  }

  func restoreDefaultSections() {
    for index in sections.indices { sections[index].included = sections[index].initiallyIncluded }
  }

  /// Starts the job by spawning the CLI (`audiobook create --progress
  /// ndjson`) as a child process and rendering its event stream. The GUI
  /// process never runs synthesis: the job lives in the same code path the
  /// CLI and smoke tests exercise, isolated from every GUI failure mode.
  func start() {
    guard let epubURL, let outputURL, case .configure = phase else { return }
    guard !selectedVoiceID.isEmpty else { return }

    generation += 1
    let g = generation

    var arguments = [epubURL.path]
    arguments += ["--output", outputURL.path, "--overwrite"]
    arguments += ["--voice", selectedVoiceID]
    arguments += ["--bitrate", String(bitrateKbps)]
    arguments += ["--workers", String(max(1, min(16, workers)))]
    arguments += ["--paragraph-pause", String(paragraphPause)]
    arguments += ["--chapter-pause", String(chapterPause)]
    arguments += [announceTitles ? "--announce-titles" : "--no-announce-titles"]
    let includes = sections.filter { $0.included && !$0.initiallyIncluded }.map { String($0.id) }
    let excludes = sections.filter { !$0.included && $0.initiallyIncluded }.map { String($0.id) }
    if !includes.isEmpty { arguments += ["--include-sections", includes.joined(separator: ",")] }
    if !excludes.isEmpty { arguments += ["--exclude-sections", excludes.joined(separator: ",")] }
    if let workDirectory = configuredWorkDirectory {
      arguments += ["--work-dir", workDirectory]
    }

    phase = .running
    progressText = "Preparing…"
    progressFraction = 0
    currentChapterText = ""
    totalChapters = 0
    currentChapterNumber = 0
    currentChapterTitle = ""
    chapterUnitsDone = 0
    chapterUnitsTotal = 0
    reusedChapters = 0
    isAssembling = false
    synthesisStartedAt = nil
    runCompletedCharacters = 0
    partialRunCharacters = 0
    chapterCharacters = []
    completedCharacters = 0
    totalCharacters = 0
    runSawEvent = false
    notifyJobStateChange()

    Self.log.info("run spawning child job")
    let runner = AudiobookJobRunner(executable: jobExecutable)
    self.runner = runner
    armRunStartWatchdog(generation: g)

    // The consuming task lives on the main actor: events arrive one at a
    // time, mutate @Observable state directly, and a cancelled consumer's
    // stream ends with nil — success is only ever the .finished event.
    runTask = Task { [weak self] in
      do {
        var finished = false
        for try await event in runner.run(arguments: arguments) {
          if case .finished = event { finished = true }
          guard let self, self.generation == g else { return }
          self.handle(event)
        }
        guard finished else { throw CancellationError() }
        guard let self, self.generation == g else { return }
        Self.log.info("run done")
        self.phase = .done(outputURL)
        self.notifyJobStateChange()
      } catch is CancellationError {
        guard let self, self.generation == g else { return }
        self.phase = .failed(
          "Cancelled — completed chapters are saved, so starting again resumes where it left off.")
        self.notifyJobStateChange()
      } catch {
        guard let self, self.generation == g else { return }
        let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        Self.log.error("run failed: \(message, privacy: .public)")
        self.phase = .failed(message)
        self.notifyJobStateChange()
      }
    }
  }

  /// SIGINT to the child: completed chapters stay durable and the child
  /// exits on its own, which ends the event stream and lands in the
  /// cancelled branch above.
  func cancel() {
    runner?.cancel()
  }

  /// If the child produces no event at all within the timeout, surface a
  /// visible failure instead of an eternal "Preparing…". Bumps `generation`
  /// first: it is establishing the terminal state, so the cancelled run
  /// task's own "Cancelled — resumes" message must be guarded out, not
  /// allowed to clobber this diagnostic.
  private func armRunStartWatchdog(generation g: Int) {
    Task { [weak self, runStartTimeout] in
      try? await Task.sleep(for: runStartTimeout)
      guard let self, self.generation == g, case .running = self.phase, !self.runSawEvent
      else { return }
      Self.log.error("run start watchdog fired")
      self.generation += 1
      self.runner?.cancel()
      self.runTask?.cancel()
      self.phase = .failed(
        "The synthesis process reported no progress and was stopped. "
          + "Try again, and check Console for 'audiobook-gui' messages if it repeats.")
      self.notifyJobStateChange()
    }
  }

  /// Menu updates run third-party-ish code (NSMenu, SMAppService XPC) that
  /// can throw ObjC exceptions AppKit swallows. Dispatching keeps such an
  /// exception from severing model logic mid-function — the cause of a
  /// job that once sat at "Preparing…" for seven hours.
  private func notifyJobStateChange() {
    DispatchQueue.main.async { [weak self] in self?.onJobStateChange?() }
  }

  private func pushProgress(force: Bool) {
    let now = Date()
    guard force || now.timeIntervalSince(lastProgressPush) >= 1 else { return }
    lastProgressPush = now
    DispatchQueue.main.async { [weak self] in self?.onProgressChange?() }
  }

  private func handle(_ event: AudiobookProgressEvent) {
    runSawEvent = true
    switch event {
    case .started(let chapters, let characters, let reused, let perChapter):
      Self.log.info("run started: \(chapters) chapters, \(reused) reused")
      synthesisStartedAt = Date()
      totalChapters = chapters
      reusedChapters = reused
      chapterCharacters = perChapter
      totalCharacters = characters
      completedCharacters = 0
      progressText = reused > 0
        ? "Resuming — \(reused) of \(chapters) chapters already complete"
        : "Synthesizing \(chapters) chapters"
      pushProgress(force: true)
    case .chapterStarted(let index, let title):
      currentChapterNumber = index + 1
      currentChapterTitle = title
      chapterUnitsDone = 0
      chapterUnitsTotal = 0
      isAssembling = false
      currentChapterText = "Chapter \(index + 1) of \(totalChapters): \(title)"
      pushProgress(force: true)
    case .unitCompleted(let index, let done, let total):
      guard totalCharacters > 0, chapterCharacters.indices.contains(index), total > 0 else {
        return
      }
      chapterUnitsDone = done
      chapterUnitsTotal = total
      let partial = Double(chapterCharacters[index]) * Double(done) / Double(total)
      partialRunCharacters = partial
      progressFraction = min(1, (Double(completedCharacters) + partial) / Double(totalCharacters))
      pushProgress(force: false)
    case .chapterCompleted(let index, _, let reused):
      if chapterCharacters.indices.contains(index) {
        completedCharacters += chapterCharacters[index]
        if !reused { runCompletedCharacters += Double(chapterCharacters[index]) }
      }
      partialRunCharacters = 0
      chapterUnitsDone = 0
      chapterUnitsTotal = 0
      if totalCharacters > 0 {
        progressFraction = min(1, Double(completedCharacters) / Double(totalCharacters))
      }
      pushProgress(force: true)
    case .assemblyStarted:
      Self.log.info("assembly started")
      isAssembling = true
      currentChapterText = "Assembling audiobook file…"
      progressFraction = 1
      pushProgress(force: true)
    case .finished:
      Self.log.info("run finished")
    case .warning:
      break
    }
  }

  func openFullDiskAccessSettings() {
    if let url = URL(
      string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
    {
      NSWorkspace.shared.open(url)
    }
  }

  // MARK: - Progress display

  var percentText: String {
    String(format: "%.0f%%", min(1, max(0, progressFraction)) * 100)
  }

  /// "Chapter 3 of 41 — The Madness Years", or the current stage.
  var primaryStatus: String {
    if isAssembling { return "Assembling audiobook file…" }
    guard currentChapterNumber > 0 else { return progressText }
    return "Chapter \(currentChapterNumber) of \(totalChapters) — \(currentChapterTitle)"
  }

  /// Live detail line: paragraph progress within the chapter, elapsed time,
  /// and a time-remaining estimate based on this run's synthesis rate
  /// (reused chapters complete instantly and are excluded from the rate).
  func secondaryStatus(now: Date) -> String {
    if isAssembling { return "Writing chapters, metadata, and cover into the M4B" }
    var parts: [String] = []
    if chapterUnitsTotal > 0 {
      parts.append("Paragraph \(chapterUnitsDone) of \(chapterUnitsTotal)")
    }
    if let startedAt = synthesisStartedAt {
      let elapsed = now.timeIntervalSince(startedAt)
      if elapsed > 1 { parts.append("elapsed \(Self.clock(elapsed))") }

      let doneThisRun = runCompletedCharacters + partialRunCharacters
      let remaining = Double(totalCharacters - completedCharacters) - partialRunCharacters
      if doneThisRun > 200, elapsed > 5, remaining > 0 {
        let rate = doneThisRun / elapsed
        parts.append("about \(Self.roughDuration(remaining / rate)) left")
      }
    }
    if reusedChapters > 0 {
      parts.append("\(reusedChapters) chapters reused")
    }
    return parts.joined(separator: "  ·  ")
  }

  private static func clock(_ interval: TimeInterval) -> String {
    let seconds = max(0, Int(interval))
    if seconds >= 3_600 {
      return String(format: "%d:%02d:%02d", seconds / 3_600, (seconds / 60) % 60, seconds % 60)
    }
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
  }

  private static func roughDuration(_ interval: TimeInterval) -> String {
    switch interval {
    case ..<75: "a minute"
    case ..<3_600: "\(Int((interval / 60).rounded())) minutes"
    default: String(format: "%.1f hours", interval / 3_600)
    }
  }
}

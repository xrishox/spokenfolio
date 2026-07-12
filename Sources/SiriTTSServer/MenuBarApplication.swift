import AVFAudio
import AppKit
import ServiceManagement
import SiriTTSCore
import Vapor

@MainActor
final class MenuBarApplication: NSObject, NSApplicationDelegate {
  private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
  private var stateItem = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
  private var endpointItem = NSMenuItem(
    title: "Endpoint unavailable", action: nil, keyEquivalent: "")
  private var audiobookItem = NSMenuItem(
    title: "Create Audiobook…", action: #selector(showAudiobookWindow), keyEquivalent: "b")
  /// SMAppService.status is an XPC call; cached so routine menu rebuilds
  /// never talk to launchd (and can never throw inside menu handling).
  private var launchAtLoginEnabled = false
  private var serverApplication: Application?
  private var serverTask: Task<Void, Never>?
  private var serverGeneration = UUID()
  private var didStart = false
  private var audiobookWindowController: AudiobookWindowController?

  static func run() {
    let application = NSApplication.shared
    let delegate = MenuBarApplication()
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    // Entered from a synchronous main(): run() performs the full normal
    // launch (including applicationDidFinishLaunching) and registers the
    // process as activatable with the window server.
    withExtendedLifetime(delegate) { application.run() }
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    startApplication()
  }

  private func startApplication() {
    guard !didStart else { return }
    didStart = true
    statusItem.button?.title = "Siri TTS"
    launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    buildMainMenu()
    rebuildMenu()
    startServer()
  }

  /// While the Create Audiobook window is open the app runs as a regular
  /// foreground app, and Cmd-key equivalents (paste in the save panel,
  /// close, quit) dispatch through the main menu — which a programmatic
  /// AppKit app must build itself.
  private func buildMainMenu() {
    let main = NSMenu()

    let appItem = NSMenuItem()
    let appMenu = NSMenu()
    appMenu.addItem(
      withTitle: "Quit Siri TTS Server",
      action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appItem.submenu = appMenu
    main.addItem(appItem)

    let editItem = NSMenuItem()
    let editMenu = NSMenu(title: "Edit")
    editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
    editMenu.addItem(.separator())
    editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    editMenu.addItem(
      withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    editItem.submenu = editMenu
    main.addItem(editItem)

    let windowItem = NSMenuItem()
    let windowMenu = NSMenu(title: "Window")
    windowMenu.addItem(
      withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    windowMenu.addItem(
      withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)),
      keyEquivalent: "m")
    windowItem.submenu = windowMenu
    main.addItem(windowItem)

    NSApp.mainMenu = main
    NSApp.windowsMenu = windowMenu
  }

  func applicationWillTerminate(_ notification: Notification) {
    // SIGINT the audiobook child if one is running (user already confirmed
    // via the quit alert): it saves resume state and exits on its own even
    // after this process is gone.
    if audiobookWindowController?.model.isJobRunning == true {
      audiobookWindowController?.model.cancel()
    }
    serverApplication?.running?.stop()
    serverTask?.cancel()
  }

  private func rebuildMenu() {
    // The stored items survive across rebuilds; adding an item that still
    // belongs to the previous menu raises NSInternalInconsistencyException
    // (swallowed by AppKit — this exact throw once truncated a caller and
    // wedged a job at "Preparing…"). Detach them first.
    for item in [stateItem, endpointItem, audiobookItem] {
      item.menu?.removeItem(item)
    }
    let menu = NSMenu()
    stateItem.isEnabled = false
    menu.addItem(stateItem)
    endpointItem.target = self
    endpointItem.action = #selector(copyEndpoint)
    menu.addItem(endpointItem)
    menu.addItem(.separator())
    refreshAudiobookItemTitle()
    menu.addItem(audiobookItem)
    menu.addItem(.separator())
    menu.addItem(
      withTitle: "Open Full Disk Access…", action: #selector(openFullDiskAccess), keyEquivalent: "")

    let launchTitle =
      launchAtLoginEnabled ? "Disable Launch at Login" : "Enable Launch at Login"
    menu.addItem(withTitle: launchTitle, action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
    menu.addItem(withTitle: "Restart Server", action: #selector(restartServer), keyEquivalent: "r")
    menu.addItem(
      withTitle: "Run Connection Test", action: #selector(runConnectionTest), keyEquivalent: "t")
    menu.addItem(withTitle: "Open Console", action: #selector(openConsole), keyEquivalent: "")
    menu.addItem(.separator())
    menu.addItem(withTitle: "Quit Siri TTS Server", action: #selector(quit), keyEquivalent: "q")
    for item in menu.items where item.action != nil { item.target = self }
    statusItem.menu = menu
  }

  /// Called from the model's throttled progress push (and on state
  /// transitions): nothing runs during menu tracking, updates arrive
  /// instead. Setting an NSMenuItem title is safe while the menu is open.
  private func refreshAudiobookItemTitle() {
    audiobookItem.title =
      audiobookWindowController?.progressSummary.map { "\($0) — Show Progress" }
      ?? "Create Audiobook…"
  }

  private func startServer() {
    guard serverTask == nil else { return }
    setState("Starting…")
    let generation = UUID()
    serverGeneration = generation
    serverTask = Task.detached { [weak self] in
      do {
        let config = try ServerConfig.load()
        let app = try await makeServerApplication(config: config)
        DispatchQueue.main.async { [weak self] in
          self?.serverBecameReady(app, config: config, generation: generation)
        }
        try await app.execute()
        try await app.asyncShutdown()
      } catch let error as ServiceError {
        DispatchQueue.main.async { [weak self] in
          self?.serverFailed(error, generation: generation)
        }
      } catch {
        DispatchQueue.main.async { [weak self] in
          self?.serverFailed(nil, generation: generation)
        }
      }
      DispatchQueue.main.async { [weak self] in
        self?.serverStopped(generation: generation)
      }
    }
  }

  private func serverBecameReady(
    _ application: Application, config: ServerConfig, generation: UUID
  ) {
    guard serverGeneration == generation else { return }
    serverApplication = application
    endpointItem.title = "Copy http://localhost:\(config.port)"
    switch application.serverHealth.state {
    case .ready:
      setState("Ready — \(application.ttsService.voiceCatalog.count) Siri voices")
    case .permissionRequired:
      setState("Full Disk Access required — gateway is available")
    case .unavailable:
      setState("Siri engine unavailable — gateway is available")
    case .starting:
      setState("Starting…")
    }
  }

  private func serverFailed(_ error: ServiceError?, generation: UUID) {
    guard serverGeneration == generation else { return }
    switch error {
    case .permissionRequired:
      setState("Full Disk Access required")
    case .engineUnavailable:
      setState("Siri engine unavailable — check FDA and installed voice")
    case .some:
      setState("Server unavailable — run Doctor")
    case nil:
      setState("Server failed — open Console")
    }
  }

  private func serverStopped(generation: UUID) {
    guard serverGeneration == generation else { return }
    serverApplication = nil
    serverTask = nil
  }

  private func setState(_ title: String) {
    stateItem.title = title
    statusItem.button?.title = title.hasPrefix("Ready") ? "Siri TTS ✓" : "Siri TTS !"
  }

  @objc private func copyEndpoint() {
    guard let port = try? ServerConfig.load().port else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(
      "http://\(Host.current().localizedName ?? "localhost"):\(port)", forType: .string)
  }

  @objc private func openFullDiskAccess() {
    if let url = URL(
      string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
    {
      NSWorkspace.shared.open(url)
    }
  }

  @objc private func toggleLaunchAtLogin() {
    do {
      if SMAppService.mainApp.status == .enabled {
        try SMAppService.mainApp.unregister()
      } else {
        try SMAppService.mainApp.register()
      }
    } catch { setState("Could not update Launch at Login") }
    launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    rebuildMenu()
  }

  @objc private func restartServer() {
    serverApplication?.running?.stop()
    serverTask?.cancel()
    serverApplication = nil
    serverTask = nil
    startServer()
  }

  @objc private func runConnectionTest() {
    guard let port = try? ServerConfig.load().port,
      let url = URL(string: "http://127.0.0.1:\(port)/v1/audio/speech"),
      let voice = serverApplication?.ttsService.defaultVoice
    else { return }
    Task {
      do {
        for format in ["opus", "aac"] {
          var request = URLRequest(url: url)
          request.httpMethod = "POST"
          request.setValue("application/json", forHTTPHeaderField: "Content-Type")
          request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "tts-1",
            "voice": voice,
            "response_format": format,
            "input": "Siri connection test.",
          ])
          let (audio, response) = try await URLSession.shared.data(for: request)
          guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ConnectionTestError.httpFailure
          }
          try Self.decodeTest(audio, fileExtension: format == "opus" ? "ogg" : "m4a")
        }
        setState("Ready — Opus and AAC synthesis/decode passed")
      } catch { setState("Connection test failed") }
    }
  }

  private static func decodeTest(_ audio: Data, fileExtension: String) throws {
    let fileURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("siri-tts-\(UUID().uuidString).\(fileExtension)")
    defer { try? FileManager.default.removeItem(at: fileURL) }
    try audio.write(to: fileURL, options: .atomic)
    let file = try AVAudioFile(forReading: fileURL)
    guard file.length > 0, file.processingFormat.channelCount == 1,
      file.processingFormat.sampleRate == 48_000,
      let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8_192)
    else {
      throw ConnectionTestError.decodeFailure
    }
    var decoded: AVAudioFramePosition = 0
    while file.framePosition < file.length {
      try file.read(into: buffer, frameCount: buffer.frameCapacity)
      guard buffer.frameLength > 0 else { throw ConnectionTestError.decodeFailure }
      decoded += AVAudioFramePosition(buffer.frameLength)
    }
    guard decoded > 0 else { throw ConnectionTestError.decodeFailure }
  }

  @objc private func openConsole() {
    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Console.app"))
  }

  @objc private func showAudiobookWindow() {
    if audiobookWindowController == nil {
      let controller = AudiobookWindowController()
      controller.model.onJobStateChange = { [weak self] in self?.rebuildMenu() }
      controller.model.onProgressChange = { [weak self] in self?.refreshAudiobookItemTitle() }
      controller.onWindowWillClose = { [weak self] in
        NSApp.setActivationPolicy(.accessory)
        self?.rebuildMenu()
      }
      audiobookWindowController = controller
    }
    // Become a regular app while the window is open: accessory processes do
    // not reliably activate on click, which leaves the open-panel sheet
    // unable to receive the click that confirms a selection. The Dock icon
    // disappears again when the window closes.
    NSApp.setActivationPolicy(.regular)
    audiobookWindowController?.show()
  }

  @objc private func quit() { NSApplication.shared.terminate(nil) }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard audiobookWindowController?.model.isJobRunning == true else { return .terminateNow }
    let alert = NSAlert()
    alert.messageText = "An audiobook is still being created"
    alert.informativeText =
      "Quitting cancels the current chapter. Completed chapters are saved, and the next run resumes from them."
    alert.addButton(withTitle: "Quit Anyway")
    alert.addButton(withTitle: "Keep Working")
    NSApp.activate(ignoringOtherApps: true)
    return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
  }
}

private enum ConnectionTestError: Error {
  case httpFailure
  case decodeFailure
}

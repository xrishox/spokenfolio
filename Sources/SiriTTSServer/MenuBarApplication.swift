import AVFAudio
import AppKit
import ServiceManagement
import Vapor

@MainActor
final class MenuBarApplication: NSObject, NSApplicationDelegate {
  private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
  private var stateItem = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
  private var endpointItem = NSMenuItem(
    title: "Endpoint unavailable", action: nil, keyEquivalent: "")
  private var serverApplication: Application?
  private var serverTask: Task<Void, Never>?
  private var serverGeneration = UUID()
  private var didStart = false

  static func run() {
    let application = NSApplication.shared
    let delegate = MenuBarApplication()
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    // Async Swift entry points can reach NSApplication.run() without AppKit
    // delivering applicationDidFinishLaunching to a programmatic delegate.
    // Finish launch explicitly, then use the same idempotent start path.
    application.finishLaunching()
    delegate.startApplication()
    withExtendedLifetime(delegate) { application.run() }
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    startApplication()
  }

  private func startApplication() {
    guard !didStart else { return }
    didStart = true
    statusItem.button?.title = "Siri TTS"
    rebuildMenu()
    startServer()
  }

  func applicationWillTerminate(_ notification: Notification) {
    serverApplication?.running?.stop()
    serverTask?.cancel()
  }

  private func rebuildMenu() {
    let menu = NSMenu()
    stateItem.isEnabled = false
    menu.addItem(stateItem)
    endpointItem.target = self
    endpointItem.action = #selector(copyEndpoint)
    menu.addItem(endpointItem)
    menu.addItem(.separator())
    menu.addItem(
      withTitle: "Open Full Disk Access…", action: #selector(openFullDiskAccess), keyEquivalent: "")

    let launchTitle =
      SMAppService.mainApp.status == .enabled
      ? "Disable Launch at Login" : "Enable Launch at Login"
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
    setState("Ready — \(application.ttsService.voiceCatalog.count) premium Siri voices")
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
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
          "model": "tts-1",
          "voice": voice,
          "response_format": "opus",
          "input": "Siri connection test.",
        ])
        let (audio, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
          throw ConnectionTestError.httpFailure
        }
        try Self.decodeTest(audio)
        setState("Ready — synthesis and decode passed")
      } catch { setState("Connection test failed") }
    }
  }

  private static func decodeTest(_ audio: Data) throws {
    let fileURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("siri-tts-\(UUID().uuidString).ogg")
    defer { try? FileManager.default.removeItem(at: fileURL) }
    try audio.write(to: fileURL, options: .atomic)
    let file = try AVAudioFile(forReading: fileURL)
    guard file.length > 0, file.processingFormat.channelCount == 1 else {
      throw ConnectionTestError.decodeFailure
    }
  }

  @objc private func openConsole() {
    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Console.app"))
  }

  @objc private func quit() { NSApplication.shared.terminate(nil) }
}

private enum ConnectionTestError: Error {
  case httpFailure
  case decodeFailure
}

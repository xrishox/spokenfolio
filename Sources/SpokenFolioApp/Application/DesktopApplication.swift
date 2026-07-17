import AppKit
import os

@MainActor
final class DesktopApplication: NSObject, NSApplicationDelegate, NSMenuItemValidation {
  private let runtime = ApplicationRuntime()
  private var mainWindowController: MainWindowController?
  private var didStart = false
  private var gracefulShutdownCompleted = false
  private var terminationInProgress = false

  static func run() {
    let application = NSApplication.shared
    let delegate = DesktopApplication()
    application.delegate = delegate
    application.setActivationPolicy(.regular)
    withExtendedLifetime(delegate) { application.run() }
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    guard !didStart else { return }
    didStart = true
    do {
      _ = try IdentityMigrationCoordinator().run()
    } catch {
      let alert = NSAlert()
      alert.messageText = "SpokenFolio could not migrate existing data"
      alert.informativeText = error.localizedDescription
        + "\n\nThe existing data was left in place for manual recovery."
      alert.addButton(withTitle: "Quit")
      alert.addButton(withTitle: "Reveal Data Folder")
      if alert.runModal() == .alertSecondButtonReturn {
        NSWorkspace.shared.activateFileViewerSelecting(
          [AppIdentity.applicationSupportDirectory.deletingLastPathComponent()])
      }
      NSApp.terminate(nil)
      return
    }
    buildMainMenu()
    showMainWindow()
    // Present the durable local state before background work can request
    // Keychain authorization for a queued Storyteller audit.
    runtime.start()
    if let controller = mainWindowController {
      UIAuditRunner.runIfRequested(runtime: runtime, controller: controller)
    }
  }

  func applicationShouldHandleReopen(
    _ sender: NSApplication, hasVisibleWindows flag: Bool
  ) -> Bool {
    if !flag { showMainWindow() }
    return true
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

  func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
    let menu = NSMenu()
    let add = menu.addItem(
      withTitle: "Add EPUBs…", action: #selector(addEPUBs), keyEquivalent: "")
    add.target = self
    if runtime.coordinator.isSuspended, runtime.coordinator.queuedCount > 0 {
      let resume = menu.addItem(
        withTitle: "Resume Production Queue", action: #selector(resumeProductionQueue),
        keyEquivalent: "")
      resume.target = self
    } else if runtime.coordinator.runningCount > 0 || runtime.coordinator.queuedCount > 0 {
      let pause = menu.addItem(
        withTitle: "Pause Production After Current", action: #selector(pauseProductionQueue),
        keyEquivalent: "")
      pause.target = self
    }
    return menu
  }

  enum TerminationDecision: Equatable {
    /// Graceful shutdown already finished; let AppKit proceed.
    case terminateNow
    /// A shutdown is already underway; a duplicate request changes nothing.
    case cancelDuplicateRequest
    /// User-initiated quit with work at risk: ask first.
    case confirm
    /// Begin the asynchronous graceful shutdown, then terminate again.
    case shutdown
    /// Logout/restart/shutdown: terminate immediately with best-effort
    /// teardown. Durable state tolerates it, and holding the session hostage
    /// on an async pause is worse.
    case terminateImmediately
  }

  static func terminationDecision(
    gracefulShutdownCompleted: Bool, terminationInProgress: Bool,
    runningJobs: Int, unqueuedDrafts: Int, systemInitiated: Bool
  ) -> TerminationDecision {
    if gracefulShutdownCompleted { return .terminateNow }
    if systemInitiated { return .terminateImmediately }
    if terminationInProgress { return .cancelDuplicateRequest }
    if runningJobs > 0 || unqueuedDrafts > 0 { return .confirm }
    return .shutdown
  }

  /// Two-phase quit. `.terminateLater` is a trap for async shutdown: AppKit
  /// pumps a nested event loop inside `terminate:` that does not schedule
  /// main-actor tasks (measured via process sample — the reply task never
  /// ran and quit hung forever). Instead every quit request is answered
  /// immediately; the graceful shutdown runs in the ordinary run loop and
  /// calls `terminate` again when it finishes.
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    let draftCount = mainWindowController?.createModel.unqueuedDraftCount ?? 0
    switch Self.terminationDecision(
      gracefulShutdownCompleted: gracefulShutdownCompleted,
      terminationInProgress: terminationInProgress,
      runningJobs: runtime.coordinator.runningCount,
      unqueuedDrafts: draftCount,
      systemInitiated: Self.terminationIsSystemInitiated)
    {
    case .terminateNow:
      return .terminateNow
    case .terminateImmediately:
      return .terminateNow
    case .cancelDuplicateRequest:
      return .terminateCancel
    case .confirm:
      terminationInProgress = true
      confirmTermination(draftCount: draftCount)
      return .terminateCancel
    case .shutdown:
      terminationInProgress = true
      beginGracefulShutdown()
      return .terminateCancel
    }
  }

  private func confirmTermination(draftCount: Int) {
    let alert = NSAlert()
    alert.messageText = "Book production is unfinished"
    alert.informativeText = draftCount > 0
      ? "\(draftCount) unqueued book\(draftCount == 1 ? "" : "s") will be discarded. Active work will be paused safely."
      : "Active work will be paused safely. Queued work remains durable."
    alert.addButton(withTitle: "Quit Anyway")
    alert.addButton(withTitle: "Keep Working")
    NSApp.activate(ignoringOtherApps: true)
    let decide: (NSApplication.ModalResponse) -> Void = { [weak self] response in
      guard let self else { return }
      if response == .alertFirstButtonReturn {
        self.beginGracefulShutdown()
      } else {
        self.terminationInProgress = false
      }
    }
    if let window = mainWindowController?.window, window.isVisible,
      window.attachedSheet == nil
    {
      alert.beginSheetModal(for: window, completionHandler: decide)
    } else {
      decide(alert.runModal())
    }
  }

  private func beginGracefulShutdown() {
    // Quit must never wedge: shutdown once hung indefinitely on a Keychain
    // read waiting for securityd (measured via process sample). Race it
    // against a watchdog; on stall, hand control back instead of beachballing.
    let shutdownTask = Task { try await runtime.shutdown() }
    Task {
      let outcome: Result<Void, Error>? = await withCheckedContinuation { continuation in
        let resumed = OSAllocatedUnfairLock(initialState: false)
        let resumeOnce: @Sendable (Result<Void, Error>?) -> Void = { value in
          let first = resumed.withLock { done in
            if done { return false }
            done = true
            return true
          }
          if first { continuation.resume(returning: value) }
        }
        Task {
          do {
            try await shutdownTask.value
            resumeOnce(.success(()))
          } catch {
            resumeOnce(.failure(error))
          }
        }
        Task {
          try? await Task.sleep(for: .seconds(20))
          resumeOnce(nil)
        }
      }
      switch outcome {
      case .success:
        gracefulShutdownCompleted = true
        NSApp.terminate(nil)
      case .failure(let error):
        terminationInProgress = false
        runtime.presentShutdownError(error.localizedDescription)
      case nil:
        terminationInProgress = false
        runtime.presentShutdownError(
          "Shutdown stalled: a subsystem did not stop in time. Approve any pending Keychain prompt and quit again, or force quit if this repeats.")
      }
    }
  }

  /// True when the quit request came from logout, restart, or shutdown.
  private static var terminationIsSystemInitiated: Bool {
    guard let event = NSAppleEventManager.shared().currentAppleEvent,
      event.eventClass == AEEventClass(kCoreEventClass),
      event.eventID == AEEventID(kAEQuitApplication),
      let reason = event.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))
    else { return false }
    switch reason.enumCodeValue {
    case kAELogOut, kAEReallyLogOut, kAEShowRestartDialog, kAEShowShutdownDialog:
      return true
    default:
      return false
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    if !gracefulShutdownCompleted { runtime.stopImmediately() }
  }

  @objc private func showMainWindow() {
    if mainWindowController == nil { mainWindowController = MainWindowController(runtime: runtime) }
    mainWindowController?.show()
  }

  @objc private func showSettings() {
    showMainWindow()
    runtime.navigation.select(.settings)
  }

  @objc private func addEPUBs() {
    showMainWindow()
    runtime.navigation.productionMode = .create
    runtime.navigation.select(.production)
    mainWindowController?.createModel.requestBooks()
  }

  @objc private func showProductionMode(_ sender: NSMenuItem) {
    guard let mode = ProductionWorkspaceMode(
      rawValue: sender.representedObject as? String ?? "")
    else { return }
    showMainWindow()
    runtime.navigation.productionMode = mode
    runtime.navigation.select(.production)
  }

  @objc private func resumeProductionQueue() { runtime.coordinator.resumeQueue() }
  @objc private func pauseProductionQueue() { runtime.coordinator.pauseQueue() }
  @objc private func pauseProductionNow() {
    runtime.coordinator.pauseQueue(interruptActive: true)
  }

  @objc private func restartTTSServer() { runtime.restartServer() }

  @objc private func testTTSServer() {
    showMainWindow()
    runtime.navigation.select(.server)
    runtime.runConnectionTest()
  }

  @objc private func showSection(_ sender: NSMenuItem) {
    guard let section = AppSection(rawValue: sender.representedObject as? String ?? "") else {
      return
    }
    showMainWindow()
    runtime.navigation.select(section)
  }

  @objc private func openDocumentation() {
    if let url = URL(string: "https://github.com/xrishox/spokenfolio#readme") {
      NSWorkspace.shared.open(url)
    }
  }

  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    switch menuItem.action {
    case #selector(showSection(_:)):
      guard let section = AppSection(
        rawValue: menuItem.representedObject as? String ?? "")
      else { return false }
      menuItem.state = runtime.navigation.selection == section ? .on : .off
      return true
    case #selector(restartTTSServer):
      if case .starting = runtime.serverState { return false }
      return true
    case #selector(testTTSServer):
      guard runtime.connectionTestState != .running else { return false }
      if case .ready = runtime.serverState { return true }
      return false
    case #selector(showProductionMode(_:)):
      guard let mode = ProductionWorkspaceMode(
        rawValue: menuItem.representedObject as? String ?? "")
      else { return false }
      menuItem.state = runtime.navigation.selection == .production
        && runtime.navigation.productionMode == mode ? .on : .off
      return true
    case #selector(resumeProductionQueue):
      return runtime.coordinator.isSuspended && runtime.coordinator.queuedCount > 0
    case #selector(pauseProductionQueue):
      return !runtime.coordinator.isSuspended
        && (runtime.coordinator.runningCount > 0 || runtime.coordinator.queuedCount > 0)
    case #selector(pauseProductionNow):
      return !runtime.coordinator.isSuspended && runtime.coordinator.runningCount > 0
    default:
      return true
    }
  }

  private func buildMainMenu() {
    let main = NSMenu()

    let appItem = NSMenuItem()
    let appMenu = NSMenu(title: AppIdentity.displayName)
    appMenu.addItem(
      withTitle: "About \(AppIdentity.displayName)",
      action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
    appMenu.addItem(.separator())
    let settings = appMenu.addItem(
      withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
    settings.target = self
    appMenu.addItem(.separator())
    appMenu.addItem(
      withTitle: "Hide \(AppIdentity.displayName)", action: #selector(NSApplication.hide(_:)),
      keyEquivalent: "h")
    let hideOthers = appMenu.addItem(
      withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)),
      keyEquivalent: "h")
    hideOthers.keyEquivalentModifierMask = [.command, .option]
    appMenu.addItem(
      withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)),
      keyEquivalent: "")
    let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
    services.submenu = NSMenu(title: "Services")
    appMenu.addItem(services)
    NSApp.servicesMenu = services.submenu
    appMenu.addItem(.separator())
    appMenu.addItem(
      withTitle: "Quit \(AppIdentity.displayName)",
      action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appItem.submenu = appMenu
    main.addItem(appItem)

    let fileItem = NSMenuItem()
    let fileMenu = NSMenu(title: "File")
    let add = fileMenu.addItem(
      withTitle: "Add EPUBs…", action: #selector(addEPUBs), keyEquivalent: "o")
    add.target = self
    fileMenu.addItem(.separator())
    fileMenu.addItem(
      withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    fileItem.submenu = fileMenu
    main.addItem(fileItem)

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

    let viewItem = NSMenuItem()
    let viewMenu = NSMenu(title: "View")
    viewMenu.addItem(
      withTitle: "Toggle Sidebar", action: #selector(NSSplitViewController.toggleSidebar(_:)),
      keyEquivalent: "s").keyEquivalentModifierMask = [.command, .control]
    for (index, section) in AppSection.menuSections.enumerated() {
      let item = viewMenu.addItem(
        withTitle: section.title, action: #selector(showSection(_:)),
        keyEquivalent: String(index + 1))
      item.target = self
      item.representedObject = section.rawValue
    }
    viewMenu.addItem(.separator())
    viewMenu.addItem(
      withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)),
      keyEquivalent: "f"
    ).keyEquivalentModifierMask = [.command, .control]
    viewItem.submenu = viewMenu
    main.addItem(viewItem)

    let productionItem = NSMenuItem()
    let productionMenu = NSMenu(title: "Production")
    let addProduction = productionMenu.addItem(
      withTitle: "Add EPUBs…", action: #selector(addEPUBs), keyEquivalent: "")
    addProduction.target = self
    productionMenu.addItem(.separator())
    for mode in ProductionWorkspaceMode.allCases {
      let item = productionMenu.addItem(
        withTitle: "Show \(mode.rawValue)", action: #selector(showProductionMode(_:)),
        keyEquivalent: "")
      item.target = self
      item.representedObject = mode.rawValue
    }
    productionMenu.addItem(.separator())
    let resumeQueue = productionMenu.addItem(
      withTitle: "Resume Queue", action: #selector(resumeProductionQueue), keyEquivalent: "")
    resumeQueue.target = self
    let pauseQueue = productionMenu.addItem(
      withTitle: "Pause After Current", action: #selector(pauseProductionQueue), keyEquivalent: "")
    pauseQueue.target = self
    let pauseNow = productionMenu.addItem(
      withTitle: "Pause Now", action: #selector(pauseProductionNow), keyEquivalent: "")
    pauseNow.target = self
    productionItem.submenu = productionMenu
    main.addItem(productionItem)

    let serverItem = NSMenuItem()
    let serverMenu = NSMenu(title: "Server")
    let restart = serverMenu.addItem(
      withTitle: "Restart TTS Server", action: #selector(restartTTSServer), keyEquivalent: "")
    restart.target = self
    let test = serverMenu.addItem(
      withTitle: "Test Opus and AAC Audio", action: #selector(testTTSServer), keyEquivalent: "")
    test.target = self
    serverItem.submenu = serverMenu
    main.addItem(serverItem)

    let windowItem = NSMenuItem()
    let windowMenu = NSMenu(title: "Window")
    windowMenu.addItem(
      withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
    windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
    windowMenu.addItem(.separator())
    let show = windowMenu.addItem(
      withTitle: "SpokenFolio", action: #selector(showMainWindow), keyEquivalent: "0")
    show.target = self
    windowMenu.addItem(.separator())
    windowMenu.addItem(
      withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)),
      keyEquivalent: "")
    windowItem.submenu = windowMenu
    main.addItem(windowItem)
    NSApp.windowsMenu = windowMenu

    let helpItem = NSMenuItem()
    let helpMenu = NSMenu(title: "Help")
    let docs = helpMenu.addItem(
      withTitle: "SpokenFolio Documentation", action: #selector(openDocumentation),
      keyEquivalent: "")
    docs.target = self
    helpItem.submenu = helpMenu
    main.addItem(helpItem)

    NSApp.mainMenu = main
  }
}

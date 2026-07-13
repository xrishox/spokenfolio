import AppKit

@MainActor
final class DesktopApplication: NSObject, NSApplicationDelegate {
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
      alert.addButton(withTitle: "Quit")
      alert.runModal()
      NSApp.terminate(nil)
      return
    }
    buildMainMenu()
    runtime.start()
    showMainWindow()
  }

  func applicationShouldHandleReopen(
    _ sender: NSApplication, hasVisibleWindows flag: Bool
  ) -> Bool {
    if !flag { showMainWindow() }
    return true
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if gracefulShutdownCompleted { return .terminateNow }
    if terminationInProgress { return .terminateLater }

    let hasDrafts = mainWindowController?.createModel.hasUnqueuedDrafts == true
    if runtime.coordinator.runningCount > 0 || runtime.coordinator.queuedCount > 0 || hasDrafts {
      let alert = NSAlert()
      alert.messageText = "Book production is unfinished"
      alert.informativeText = hasDrafts
        ? "Unqueued selections will be discarded. Queued and active work will be paused safely."
        : "Active work will be paused and the durable queue will remain suspended."
      alert.addButton(withTitle: "Quit Anyway")
      alert.addButton(withTitle: "Keep Working")
      NSApp.activate(ignoringOtherApps: true)
      guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
    }

    terminationInProgress = true
    Task {
      do {
        try await runtime.shutdown()
        gracefulShutdownCompleted = true
        sender.reply(toApplicationShouldTerminate: true)
      } catch {
        terminationInProgress = false
        runtime.presentShutdownError(error.localizedDescription)
        sender.reply(toApplicationShouldTerminate: false)
      }
    }
    return .terminateLater
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
    runtime.navigation.select(.create)
    mainWindowController?.createModel.requestBooks()
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
        withTitle: section.rawValue, action: #selector(showSection(_:)),
        keyEquivalent: String(index + 1))
      item.target = self
      item.representedObject = section.rawValue
    }
    viewItem.submenu = viewMenu
    main.addItem(viewItem)

    let windowItem = NSMenuItem()
    let windowMenu = NSMenu(title: "Window")
    windowMenu.addItem(
      withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
    windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
    windowMenu.addItem(.separator())
    let show = windowMenu.addItem(
      withTitle: "SpokenFolio", action: #selector(showMainWindow), keyEquivalent: "0")
    show.target = self
    windowItem.submenu = windowMenu
    main.addItem(windowItem)
    NSApp.windowsMenu = windowMenu

    let helpItem = NSMenuItem()
    let helpMenu = NSMenu(title: "Help")
    let docs = helpMenu.addItem(
      withTitle: "SpokenFolio Documentation", action: #selector(openDocumentation),
      keyEquivalent: "?")
    docs.target = self
    helpItem.submenu = helpMenu
    main.addItem(helpItem)

    NSApp.mainMenu = main
  }
}

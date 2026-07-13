import AppKit
import SwiftUI
import UniformTypeIdentifiers
import os

/// Hosts the single persistent SpokenFolio window. Closing it never owns the
/// gateway or durable production scheduler; Dock activation reuses this controller.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
  private(set) var runtime: ApplicationRuntime!
  private(set) var coordinator: StudioJobCoordinator!
  private(set) var createModel: StudioCreateModel!

  private static let log = Logger(
    subsystem: AppIdentity.bundleIdentifier, category: "main-window")

  convenience init(runtime: ApplicationRuntime) {
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: MainWindowGeometry.preferredContentSize),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false)
    window.title = AppIdentity.displayName
    window.isReleasedWhenClosed = false
    window.setFrameAutosaveName(AppIdentity.windowAutosaveName)
    let restored = window.setFrameUsingName(AppIdentity.windowAutosaveName)
    if !restored { window.center() }
    self.init(window: window)
    self.runtime = runtime
    self.coordinator = runtime.coordinator
    let createModel = StudioCreateModel(coordinator: runtime.coordinator)
    self.createModel = createModel
    window.delegate = self
    window.contentViewController = NSHostingController(
      rootView: AppRootView(runtime: runtime, create: createModel))
    createModel.presentOpenPanel = { [weak self] completion in
      guard let self, let window = self.window else {
        completion([])
        return
      }
      // A sheet is already up: don't stack another. AppKit's own state is
      // the only re-entry guard, so nothing can wedge.
      guard window.attachedSheet == nil else { return }
      let panel = NSOpenPanel()
      panel.message = "Choose EPUBs to turn into audiobooks"
      panel.allowedContentTypes = [.epub]
      panel.allowsMultipleSelection = true
      panel.beginSheetModal(for: window) { response in
        let urls = response == .OK ? panel.urls : []
        Task { @MainActor in
          Self.log.info("EPUB chooser ended: response=\(response.rawValue)")
          completion(urls)
        }
      }
    }
    createModel.presentDirectoryPanel = { [weak self] current, completion in
      guard let self, let window = self.window else {
        completion(nil)
        return
      }
      guard window.attachedSheet == nil else { return }
      let panel = NSOpenPanel()
      panel.canChooseFiles = false
      panel.canChooseDirectories = true
      panel.canCreateDirectories = true
      panel.allowsMultipleSelection = false
      panel.directoryURL = current
      panel.beginSheetModal(for: window) { response in
        let url = response == .OK ? panel.url : nil
        Task { @MainActor in completion(url) }
      }
    }
    fitWindowToCurrentScreen()
  }

  func show() {
    fitWindowToCurrentScreen()
    NSApp.activate(ignoringOtherApps: true)
    showWindow(nil)
    window?.makeKeyAndOrderFront(nil)
  }

  func windowDidChangeScreen(_ notification: Notification) { fitWindowToCurrentScreen() }

  private func fitWindowToCurrentScreen() {
    guard let window, let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame else {
      return
    }
    window.contentMinSize = MainWindowGeometry.minimumContentSize(visibleFrame: visible)
    window.setFrame(
      MainWindowGeometry.fittedFrame(window.frame, visibleFrame: visible), display: false)
  }

}

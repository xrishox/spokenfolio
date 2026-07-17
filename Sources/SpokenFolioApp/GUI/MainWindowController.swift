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
    window.tabbingMode = .disallowed
    window.toolbarStyle = .unified
    window.collectionBehavior.insert(.fullScreenPrimary)
    self.init(window: window)
    self.runtime = runtime
    self.coordinator = runtime.coordinator
    let createModel = StudioCreateModel(coordinator: runtime.coordinator)
    self.createModel = createModel
    window.delegate = self
    let hosting = NSHostingController(
      rootView: AppRootView(runtime: runtime, create: createModel))
    // SwiftUI must never dictate the window frame: with default sizing
    // options the hosting controller shrinks the window to the content's
    // ideal size after the first layout pass, scrunching the restored frame.
    hosting.sizingOptions = []
    // Order matters, measured, not guessed: assigning contentViewController
    // makes NSWindow itself resize to the view's fitting size (~the minimum),
    // independent of sizingOptions. Restore the saved frame only AFTER the
    // content is attached, or every launch collapses to the fitting size —
    // and the collapsed frame then poisons the autosave.
    window.contentViewController = hosting
    window.setFrameAutosaveName(AppIdentity.windowAutosaveName)
    if !window.setFrameUsingName(AppIdentity.windowAutosaveName) {
      window.setContentSize(MainWindowGeometry.preferredContentSize)
      window.center()
    }
    createModel.presentOpenPanel = { [weak self] completion in
      guard let self, let window = self.window else {
        completion([])
        return
      }
      // A sheet is already up: don't stack another. AppKit's own state is
      // the only re-entry guard, so nothing can wedge.
      guard window.attachedSheet == nil else {
        completion([])
        return
      }
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
      guard window.attachedSheet == nil else {
        completion(nil)
        return
      }
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
    // Fit exactly once, against the display that actually hosts the restored
    // frame. Later shows must not second-guess a size the user chose.
    fitRestoredWindow()
  }

  func show() {
    NSApp.activate(ignoringOtherApps: true)
    showWindow(nil)
    window?.makeKeyAndOrderFront(nil)
  }

  /// The user moved the window to another display (or the display arrangement
  /// changed). Only the resize floor may react here: calling setFrame during a
  /// live title-bar drag snatches the window out of the user's hand.
  func windowDidChangeScreen(_ notification: Notification) {
    guard let window, let visible = window.screen?.visibleFrame else { return }
    applyMinimumContentSize(for: visible)
  }

  func windowWillUseStandardFrame(
    _ window: NSWindow, defaultFrame newFrame: NSRect
  ) -> NSRect {
    guard let visible = window.screen?.visibleFrame else { return newFrame }
    return visible.insetBy(dx: MainWindowGeometry.margin, dy: MainWindowGeometry.margin)
  }

  /// Restores a usable frame at construction time. The window is not on screen
  /// yet, so `window.screen` is nil; pick the display sharing the most area
  /// with the saved frame, and fall back to the main display only when the
  /// saved display is gone.
  private func fitRestoredWindow() {
    guard let window else { return }
    guard let visible = MainWindowGeometry.restorationVisibleFrame(
      windowFrame: window.frame,
      screenVisibleFrames: NSScreen.screens.map(\.visibleFrame),
      mainVisibleFrame: NSScreen.main?.visibleFrame)
    else { return }
    let minimumFrameSize = applyMinimumContentSize(for: visible)
    window.setFrame(
      MainWindowGeometry.fittedFrame(
        window.frame, visibleFrame: visible, minimumFrameSize: minimumFrameSize),
      display: false)
  }

  @discardableResult
  private func applyMinimumContentSize(for visible: NSRect) -> NSSize? {
    guard let window else { return nil }
    let availableFrame = visible.insetBy(
      dx: MainWindowGeometry.margin, dy: MainWindowGeometry.margin)
    guard availableFrame.width > 0, availableFrame.height > 0 else { return nil }
    let maximumContentSize = window.contentRect(
      forFrameRect: NSRect(origin: .zero, size: availableFrame.size)
    ).size
    let minimumContentSize = MainWindowGeometry.minimumContentSize(
      maximumContentSize: maximumContentSize)
    window.contentMinSize = minimumContentSize
    return window.frameRect(
      forContentRect: NSRect(origin: .zero, size: minimumContentSize)
    ).size
  }

}

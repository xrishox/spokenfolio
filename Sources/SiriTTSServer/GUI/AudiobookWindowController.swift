import AppKit
import SwiftUI
import UniformTypeIdentifiers
import os

/// Hosts the SwiftUI Create Audiobook flow in the menu-bar app. One window,
/// one job at a time; closing the window hides it while a job keeps running.
@MainActor
final class AudiobookWindowController: NSWindowController, NSWindowDelegate {
  let model = AudiobookViewModel()

  /// Lets the menu application drop back to accessory policy when the
  /// window goes away.
  var onWindowWillClose: (() -> Void)?

  private static let log = Logger(
    subsystem: "com.xrishox.macos-tts-server", category: "audiobook-gui")

  convenience init() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false)
    window.title = "Create Audiobook"
    window.isReleasedWhenClosed = false
    window.center()
    self.init(window: window)
    window.delegate = self
    window.contentViewController = NSHostingController(
      rootView: AudiobookRootView(model: model))
    model.presentOpenPanel = { [weak self] completion in
      guard let self, let window = self.window else {
        completion(nil)
        return
      }
      // A sheet is already up: don't stack another. AppKit's own state is
      // the only re-entry guard, so nothing can wedge.
      guard window.attachedSheet == nil else { return }
      let panel = NSOpenPanel()
      panel.message = "Choose an EPUB to turn into an audiobook"
      panel.allowedContentTypes = [.epub]
      panel.allowsMultipleSelection = false
      panel.beginSheetModal(for: window) { response in
        let url = response == .OK ? panel.url : nil
        Task { @MainActor in
          Self.log.info("EPUB chooser ended: response=\(response.rawValue)")
          completion(url)
        }
      }
    }
    model.presentSavePanel = { [weak self] current, completion in
      guard let self, let window = self.window else {
        completion(nil)
        return
      }
      guard window.attachedSheet == nil else { return }
      let panel = NSSavePanel()
      panel.allowedContentTypes = [.init(filenameExtension: "m4b")].compactMap { $0 }
      panel.nameFieldStringValue = current?.lastPathComponent ?? "Audiobook.m4b"
      panel.directoryURL = current?.deletingLastPathComponent()
      panel.beginSheetModal(for: window) { response in
        let url = response == .OK ? panel.url : nil
        Task { @MainActor in completion(url) }
      }
    }
  }

  /// Selecting "Create Audiobook…" goes straight to choosing a book. The
  /// picker request is deferred one runloop turn so the window is fully on
  /// screen before the sheet attaches on first presentation.
  func show() {
    NSApp.activate(ignoringOtherApps: true)
    showWindow(nil)
    window?.makeKeyAndOrderFront(nil)
    DispatchQueue.main.async { [weak self] in
      self?.model.requestBookPicker()
    }
  }

  func windowWillClose(_ notification: Notification) {
    onWindowWillClose?()
  }

  var progressSummary: String? {
    guard model.isJobRunning else { return nil }
    if model.currentChapterNumber > 0 {
      return "Audiobook: chapter \(model.currentChapterNumber)/\(model.totalChapters) — "
        + model.percentText
    }
    return "Audiobook: \(model.percentText)"
  }
}

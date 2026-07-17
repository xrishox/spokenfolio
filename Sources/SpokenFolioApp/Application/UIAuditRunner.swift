import AppKit
import SwiftUI

/// Environment-gated UI audit: when `SPOKENFOLIO_UI_AUDIT` names a directory,
/// the app walks its full section/size/appearance matrix, writes a PNG
/// self-snapshot and a view-tree layout report for every state, then quits.
///
/// Self-snapshots use `cacheDisplay`, which renders the app's own window and
/// therefore needs no Screen Recording permission — this exists so UI defects
/// can be observed from a headless session instead of guessed at from code.
/// The walk is strictly non-mutating: navigation, window size, and appearance
/// only. It never touches jobs, drafts, the library, or remote connections.
@MainActor
enum UIAuditRunner {
  private struct AuditState {
    let name: String
    let apply: @MainActor (ApplicationRuntime) -> Void
  }

  private static let states: [AuditState] = [
    .init(name: "production-create") {
      $0.navigation.productionMode = .create
      $0.navigation.select(.production)
    },
    .init(name: "production-queue") {
      $0.navigation.productionMode = .queue
      $0.navigation.select(.production)
    },
    .init(name: "production-history") {
      $0.navigation.productionMode = .history
      $0.navigation.select(.production)
    },
    .init(name: "library") { $0.navigation.select(.library) },
    .init(name: "quality") { $0.navigation.select(.quality) },
    .init(name: "server") { $0.navigation.select(.server) },
    .init(name: "settings-general") {
      UserDefaults.standard.set(
        SettingsScope.general.rawValue, forKey: SettingsScope.persistenceKey)
      $0.navigation.select(.settings)
    },
    .init(name: "settings-storage") {
      UserDefaults.standard.set(
        SettingsScope.storage.rawValue, forKey: SettingsScope.persistenceKey)
      $0.navigation.select(.settings)
    },
    .init(name: "settings-readaloud") {
      UserDefaults.standard.set(
        SettingsScope.readAloud.rawValue, forKey: SettingsScope.persistenceKey)
      $0.navigation.select(.settings)
    },
    .init(name: "settings-storyteller") {
      UserDefaults.standard.set(
        SettingsScope.storyteller.rawValue, forKey: SettingsScope.persistenceKey)
      $0.navigation.select(.settings)
    },
  ]

  /// Content sizes: the documented minimum, defaults, large, and probes around
  /// the GeometryReader layout thresholds (detail-pane 720/760/820 with the
  /// ~205 pt sidebar in front of them).
  private static let contentSizes: [NSSize] = [
    NSSize(width: 900, height: 620),
    NSSize(width: 930, height: 620),
    NSSize(width: 980, height: 660),
    NSSize(width: 1_030, height: 660),
    NSSize(width: 1_180, height: 760),
    NSSize(width: 1_600, height: 1_000),
  ]

  static func runIfRequested(
    runtime: ApplicationRuntime, controller: MainWindowController
  ) {
    guard let path = ProcessInfo.processInfo.environment["SPOKENFOLIO_UI_AUDIT"],
      !path.isEmpty
    else { return }
    Task { await run(into: URL(fileURLWithPath: path), runtime: runtime, controller: controller) }
  }

  private static func run(
    into directory: URL, runtime: ApplicationRuntime, controller: MainWindowController
  ) async {
    guard let window = controller.window else { return }
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let frameAtLaunch = descriptor(window.frame)
    try? await Task.sleep(for: .seconds(2))
    var manifest: [[String: String]] = [
      ["state": "launch-settled", "windowFrame": descriptor(window.frame),
       "windowFrameAtLaunch": frameAtLaunch]
    ]
    for appearanceName in ["aqua", "darkAqua"] {
      NSApp.appearance = NSAppearance(
        named: appearanceName == "aqua" ? .aqua : .darkAqua)
      for size in contentSizes {
        window.setContentSize(size)
        window.center()
        for state in states {
          state.apply(runtime)
          try? await Task.sleep(for: .milliseconds(350))
          window.displayIfNeeded()
          let base = "\(appearanceName)-\(Int(size.width))x\(Int(size.height))-\(state.name)"
          // The theme frame (contentView's superview) includes the title bar,
          // so toolbar items and search fields are part of the evidence.
          let target = window.contentView?.superview ?? window.contentView
          if let target {
            snapshot(target, to: directory.appendingPathComponent("\(base).png"))
            writeLayoutReport(
              target, to: directory.appendingPathComponent("\(base).json"))
          }
          manifest.append(
            ["state": state.name, "size": "\(Int(size.width))x\(Int(size.height))",
             "appearance": appearanceName, "file": "\(base).png",
             "windowFrame": descriptor(window.frame)])
        }
      }
    }
    if let data = try? JSONSerialization.data(
      withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
    {
      try? data.write(to: directory.appendingPathComponent("manifest.json"))
    }
    NSApp.terminate(nil)
    // If graceful shutdown is vetoed or stalls (e.g. a Keychain subsystem
    // waiting on a prompt this session can never show), the audit evidence is
    // already on disk; a lingering headless test instance helps no one.
    try? await Task.sleep(for: .seconds(30))
    exit(0)
  }

  private static func descriptor(_ frame: NSRect) -> String {
    "\(Int(frame.minX)) \(Int(frame.minY)) \(Int(frame.width)) \(Int(frame.height))"
  }

  private static func snapshot(_ view: NSView, to url: URL) {
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
    view.cacheDisplay(in: view.bounds, to: rep)
    guard let data = rep.representation(using: .png, properties: [:]) else { return }
    try? data.write(to: url)
  }

  private static func writeLayoutReport(_ root: NSView, to url: URL) {
    func node(_ view: NSView) -> [String: Any] {
      var value: [String: Any] = [
        "class": String(describing: type(of: view)),
        "frame": [
          Int(view.frame.minX), Int(view.frame.minY),
          Int(view.frame.width), Int(view.frame.height),
        ],
      ]
      if view.isHidden { value["hidden"] = true }
      if view.frame.width <= 0 || view.frame.height <= 0 { value["zeroSize"] = true }
      let visible = view.visibleRect
      if !view.isHidden, view.frame.width > 0 {
        if visible.isEmpty {
          value["fullyClipped"] = true
        } else if visible.width + 0.5 < view.bounds.width
          || visible.height + 0.5 < view.bounds.height
        {
          value["visible"] = [Int(visible.width), Int(visible.height)]
        }
      }
      let children = view.subviews.map(node)
      if !children.isEmpty { value["children"] = children }
      return value
    }
    if let data = try? JSONSerialization.data(
      withJSONObject: node(root), options: [.sortedKeys])
    {
      try? data.write(to: url)
    }
  }
}

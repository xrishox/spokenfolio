import AppKit
import BookJobKit
import SwiftUI
import XCTest

@testable import SpokenFolioApp

/// Renders populated component states to PNGs for human inspection when
/// `SPOKENFOLIO_SNAPSHOT_DIR` is set; skipped otherwise. Uses a borderless
/// off-screen window with `NSHostingView` because Table/List are AppKit-backed
/// and render blank through `ImageRenderer`.
@MainActor
final class ComponentSnapshotTests: XCTestCase {
  func testWindowDelegateMethodsAreRealProtocolSelectors() {
    // A mistyped optional-protocol method compiles and is silently never
    // called (this bit windowWillUseStandardFrame once). #selector pins the
    // names to the protocol at compile time; responds(to:) pins the class.
    let controller = MainWindowController(runtime: ApplicationRuntime())
    XCTAssertTrue(
      controller.responds(to: #selector(NSWindowDelegate.windowDidChangeScreen(_:))))
    XCTAssertTrue(
      controller.responds(
        to: #selector(NSWindowDelegate.windowWillUseStandardFrame(_:defaultFrame:))))
    controller.window?.close()
  }

  func testProductionComponentSnapshots() async throws {
    guard let directory = snapshotDirectory() else {
      throw XCTSkip("SPOKENFOLIO_SNAPSHOT_DIR not set")
    }
    let fixture = try SnapshotFixture()
    _ = try await fixture.makeJob("Running Book", lifecycle: .running)
    _ = try await fixture.makeJob("Waiting Book", lifecycle: .queued)
    _ = try await fixture.makeJob("Paused Book", lifecycle: .paused)
    _ = try await fixture.makeJob(
      "Broken Book", lifecycle: .needsAttention,
      error: "Siri synthesis failed after 3 attempts: worker crashed")
    _ = try await fixture.makeJob("Finished Book", lifecycle: .completed)
    _ = try await fixture.makeJob("Cancelled Book", lifecycle: .cancelled)
    await fixture.coordinator.reload()

    for mode in [ProductionWorkspaceMode.queue, .history] {
      let view = ProductionJobsView(coordinator: fixture.coordinator, mode: mode)
      for width in [900.0, 1_180.0] {
        try snapshot(
          view, size: NSSize(width: width, height: 640),
          name: "jobs-\(mode.rawValue.lowercased())-\(Int(width))", into: directory)
      }
    }
  }

  func testCreateBatchSnapshots() async throws {
    guard let directory = snapshotDirectory() else {
      throw XCTSkip("SPOKENFOLIO_SNAPSHOT_DIR not set")
    }
    let coordinator = StudioJobCoordinator()
    let model = StudioCreateModel(coordinator: coordinator)
    // Nonexistent paths import-fail immediately: renders loading→failed rows
    // and the batch-level notice without touching real data.
    model.addBooks([
      URL(fileURLWithPath: "/nonexistent/A Very Long Book Title That Should Truncate Gracefully In The Draft List.epub"),
      URL(fileURLWithPath: "/nonexistent/Short.epub"),
      URL(fileURLWithPath: "/nonexistent/duplicate.epub"),
      URL(fileURLWithPath: "/nonexistent/duplicate.epub"),
    ])
    try await Task.sleep(for: .milliseconds(600))
    for width in [900.0, 1_180.0] {
      try snapshot(
        CreateBatchView(model: model), size: NSSize(width: width, height: 640),
        name: "create-failed-imports-\(Int(width))", into: directory)
    }
  }

  func testLibraryProcessSheetSnapshots() async throws {
    guard let directory = snapshotDirectory() else {
      throw XCTSkip("SPOKENFOLIO_SNAPSHOT_DIR not set")
    }
    var products: [BookCatalogProduct] = [
      .init(
        kind: .sourceEPUB, path: "/managed/Book/Book.epub", size: 10,
        sha256: String(repeating: "c", count: 64), verifiedAt: Date()),
      .init(
        kind: .m4b, path: "/managed/Book/Book.m4b", size: 99,
        sha256: String(repeating: "a", count: 64), verifiedAt: Date(),
        narration: .init(
          backendID: "siri", modelID: "siri-private", voiceID: "voice",
          includedSectionIDs: [], bitrateKbps: 256, workers: 2,
          paragraphPauseSeconds: 0.6, chapterPauseSeconds: 1.75,
          announceTitles: false)),
    ]
    let m4bOnly = BookCatalogRecord(
      source: .init(
        format: "epub", importerVersion: 1,
        sha256: String(repeating: "c", count: 64), size: 10),
      metadata: .init(title: "The Final Empire", author: "Brandon Sanderson"),
      outputDirectory: "/managed/Book", outputBaseName: "Book",
      products: products)
    products.append(
      .init(
        kind: .readAloudEPUB, path: "/managed/Book/Book.readaloud.epub", size: 55,
        sha256: String(repeating: "b", count: 64), verifiedAt: Date()))
    let complete = BookCatalogRecord(
      source: m4bOnly.source, metadata: m4bOnly.metadata,
      outputDirectory: "/managed/Book", outputBaseName: "Book", products: products)

    func processRow(_ id: String, record: BookCatalogRecord) -> StudioLibraryRow {
      StudioLibraryRow(
        id: id, title: record.metadata.title, author: record.metadata.author,
        record: record, remote: nil, level: .listenable, presence: .local,
        narration: .unknown, stale: false, localEPUBReady: true,
        localAudiobookReady: record.product(.m4b) != nil,
        localReadAloudReady: record.product(.readAloudEPUB) != nil,
        localReadAloudProductID: nil, ttsProvenance: nil,
        localQualityVerdict: nil, remoteQualityVerdict: nil,
        updatedAt: Date(), searchIndex: record.metadata.title)
    }

    for (name, record, intent) in [
      ("process-m4b-only", m4bOnly, LibraryProcessModel.Intent.process),
      ("process-recreate-readaloud", complete, .readAloud),
      ("process-send-only", complete, .sendOnly),
    ] {
      let model = LibraryProcessModel(
        rows: [processRow(name, record: record)], intent: intent,
        connections: [], preferredConnectionID: nil,
        coordinator: StudioJobCoordinator(),
        processedDirectory: FileManager.default.temporaryDirectory)
      try snapshot(
        LibraryProcessSheet(model: model), size: NSSize(width: 640, height: 640),
        name: "sheet-\(name)", into: directory)
    }
  }

  private func snapshotDirectory() -> URL? {
    guard let path = ProcessInfo.processInfo.environment["SPOKENFOLIO_SNAPSHOT_DIR"],
      !path.isEmpty
    else { return nil }
    let url = URL(fileURLWithPath: path)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func snapshot<V: View>(
    _ view: V, size: NSSize, name: String, into directory: URL
  ) throws {
    let window = NSWindow(
      contentRect: NSRect(origin: NSPoint(x: -12_000, y: -12_000), size: size),
      styleMask: [.borderless], backing: .buffered, defer: false)
    defer { window.orderOut(nil) }
    window.contentView = NSHostingView(
      rootView: view.frame(width: size.width, height: size.height))
    window.orderFront(nil)
    // SwiftUI needs run-loop turns to lay out its AppKit-backed children.
    for _ in 0..<8 {
      RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    window.contentView?.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    guard let content = window.contentView,
      let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds)
    else { return XCTFail("no bitmap rep for \(name)") }
    content.cacheDisplay(in: content.bounds, to: rep)
    guard let data = rep.representation(using: .png, properties: [:]) else {
      return XCTFail("no png for \(name)")
    }
    try data.write(to: directory.appendingPathComponent("\(name).png"))
  }
}

/// Same shape as ProductionWorkspaceTests' fixture, with an error override
/// for needs-attention renders. Temp-rooted; never touches real app support.
@MainActor
private final class SnapshotFixture {
  let root: URL
  let store: BookJobStore
  let scheduler: BookSchedulerStore
  let coordinator: StudioJobCoordinator

  init() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("snapshot-fixture-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    store = BookJobStore(root: root.appendingPathComponent("jobs", isDirectory: true))
    scheduler = BookSchedulerStore(
      url: root.appendingPathComponent("scheduler.json"))
    coordinator = StudioJobCoordinator(
      store: store, schedulerStore: scheduler, schedulerLockURL: nil)
  }

  func makeJob(
    _ title: String, lifecycle: BookJobLifecycle = .queued, error: String? = nil
  ) async throws -> UUID {
    let request = BookJobRequest(
      managedByStudio: true, title: title, author: "Fixture Author",
      source: .init(
        path: root.appendingPathComponent("\(title).epub").path,
        sha256: String(repeating: "a", count: 64), format: "epub",
        importerVersion: 1),
      narration: .init(
        backendID: "siri", modelID: "siri-private", voiceID: "fixture-voice",
        includedSectionIDs: [], bitrateKbps: 256, workers: 2,
        paragraphPauseSeconds: 0.6, chapterPauseSeconds: 1.75,
        announceTitles: true),
      m4bOutputPath: root.appendingPathComponent("\(title).m4b").path)
    try await store.create(request)
    if lifecycle != .queued {
      var state = try await store.loadState(request.id)
      state.lifecycle = lifecycle
      state.lastError = error
      state.updatedAt = Date()
      try await store.saveState(state)
    }
    if lifecycle == .queued {
      try await store.enqueue(request.id, sequence: UInt64.random(in: 1...1_000))
    }
    return request.id
  }
}

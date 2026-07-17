import Foundation
import LibraryKit
import XCTest

@testable import SpokenFolioApp

/// Executes the real ReadAloudQualityModel against a temp library store —
/// sequence bugs (zombie runs, misclassified cancellations, selection churn)
/// only show up when the state machine actually runs.
@MainActor
final class QualityModelSimulationTests: XCTestCase {
  private var root: URL!

  override func setUp() async throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("quality-sim-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDown() async throws {
    if let root { try? FileManager.default.removeItem(at: root) }
  }

  private func makeModel() -> (ReadAloudQualityModel, URL) {
    let databaseURL = root.appendingPathComponent("library.sqlite")
    return (ReadAloudQualityModel(databaseURL: databaseURL), databaseURL)
  }

  private struct SyntheticExecutionFailure: Error, LocalizedError {
    var errorDescription: String? { "synthetic execution failure" }
  }

  /// A failing audit must drain to a terminal state — never a zombie
  /// `.running` or stuck `.queued` row — and the model must return to idle.
  func testFailingExecutionsDrainToTerminalStatesWithoutZombies() async throws {
    let (model, databaseURL) = makeModel()
    model.executeOverride = { _ in throw SyntheticExecutionFailure() }

    let queued = model.enqueue([
      .standalone(path: "/books/one.epub"), .standalone(path: "/books/two.epub"),
    ])
    XCTAssertNil(model.error, "enqueue reported: \(model.error ?? "")")
    XCTAssertEqual(queued, 2)

    // Poll the durable store, not the model's transient flags: isBusy is
    // false both before the queue starts and after it drains.
    var drained = false
    for _ in 0..<200 {
      let runs = try LibraryStore(databaseURL: databaseURL).readAloudAudits()
      if runs.count == 2,
        runs.allSatisfy({ ![.queued, .running].contains($0.lifecycle) })
      {
        drained = true
        break
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertTrue(drained, "quality queue never drained; error=\(model.error ?? "nil")")

    let runs = try LibraryStore(databaseURL: databaseURL).readAloudAudits()
    XCTAssertEqual(runs.count, 2)
    for run in runs {
      XCTAssertEqual(run.lifecycle, .failed, "expected failed, got \(run.lifecycle)")
      XCTAssertNotNil(run.completedAt, "terminal run without completedAt")
      XCTAssertEqual(run.error, "synthetic execution failure")
    }
  }

  /// User cancellation must classify the run as `.cancelled` ("Cancelled by
  /// user"), never as a failure, and the queue must return to idle.
  func testUserCancellationIsClassifiedAsCancelledNotFailed() async throws {
    let (model, databaseURL) = makeModel()
    model.executeOverride = { _ in try await Task.sleep(for: .seconds(30)) }

    XCTAssertEqual(model.enqueue([.standalone(path: "/books/slow.epub")]), 1)
    var started = false
    for _ in 0..<200 {
      if model.currentRunID != nil { started = true; break }
      try await Task.sleep(for: .milliseconds(25))
    }
    XCTAssertTrue(started, "audit never started")

    model.cancelCurrentAudit()

    var terminal: LibraryReadAloudAuditRun?
    for _ in 0..<200 {
      let runs = try LibraryStore(databaseURL: databaseURL).readAloudAudits()
      if let run = runs.first, ![.queued, .running].contains(run.lifecycle) {
        terminal = run
        break
      }
      try await Task.sleep(for: .milliseconds(25))
    }
    XCTAssertEqual(terminal?.lifecycle, .cancelled)
    XCTAssertEqual(terminal?.progressMessage, "Cancelled by user")
    XCTAssertNil(terminal?.error, "user cancellation recorded as an error")
  }

  /// Cancelling waiting checks marks exactly the selected ones cancelled and
  /// leaves the rest queued.
  func testCancelWaitingAuditsIsSelectiveAndTerminal() throws {
    let (model, databaseURL) = makeModel()
    let store = try LibraryStore(databaseURL: databaseURL)
    let runs = ReadAloudQualityModel.queueRuns(
      targets: [
        .standalone(path: "/x/one.epub"),
        .standalone(path: "/x/two.epub"),
        .standalone(path: "/x/three.epub"),
      ],
      excluding: [], mode: .standard, now: Date())
    try store.saveReadAloudAudits(runs)

    model.cancelWaitingAudits([runs[0].id, runs[2].id])
    XCTAssertNil(model.error, "cancelWaitingAudits reported: \(model.error ?? "")")

    let after = Dictionary(
      uniqueKeysWithValues: try store.readAloudAudits().map { ($0.id, $0.lifecycle) })
    XCTAssertEqual(after[runs[0].id], .cancelled)
    XCTAssertEqual(after[runs[1].id], .queued)
    XCTAssertEqual(after[runs[2].id], .cancelled)
  }

  /// Reload must not invent a selection (regression: the old auto-select-first
  /// hid the empty state and broke batch workflows), and filtering away the
  /// whole selection empties it rather than force-selecting the first row.
  func testSelectionIsNeverInventedByReloadOrFiltering() async throws {
    let (model, databaseURL) = makeModel()
    let store = try LibraryStore(databaseURL: databaseURL)
    try store.saveReadAloudAudits(
      ReadAloudQualityModel.queueRuns(
        targets: [
          .standalone(path: "/books/Alpha.epub"),
          .standalone(path: "/books/Beta.epub"),
          .standalone(path: "/books/Gamma.epub"),
        ],
        excluding: [], mode: .standard, now: Date()))

    await model.reload()

    XCTAssertEqual(model.artifacts.count, 3)
    XCTAssertTrue(model.selectedArtifactIDs.isEmpty, "reload invented a selection")

    model.selectAllVisibleArtifacts()
    XCTAssertEqual(model.selectedArtifactIDs.count, 3)

    model.search = "Beta"
    model.keepSelectionVisible()
    XCTAssertEqual(model.selectedArtifacts.map(\.title), ["Beta"])

    model.search = "matches nothing"
    model.keepSelectionVisible()
    XCTAssertTrue(
      model.selectedArtifactIDs.isEmpty,
      "empty filter result force-selected a hidden row")
  }
}

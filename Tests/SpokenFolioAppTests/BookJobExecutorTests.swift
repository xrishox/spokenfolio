import BookJobKit
import CryptoKit
import Foundation
import XCTest

@testable import SpokenFolioApp

final class BookJobExecutorTests: XCTestCase {
  private func request(root: URL) throws -> BookJobRequest {
    let source = root.appendingPathComponent("book.epub")
    let data = Data("not an epub".utf8)
    try data.write(to: source)
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return BookJobRequest(
      title: "Fixture", author: nil,
      source: .init(path: source.path, sha256: digest, format: "epub", importerVersion: 1),
      narration: .init(
        backendID: "siri", modelID: "siri-private", voiceID: "invalid",
        includedSectionIDs: [], bitrateKbps: 64, workers: 1,
        paragraphPauseSeconds: 0.6, chapterPauseSeconds: 1.75, announceTitles: true),
      m4bOutputPath: root.appendingPathComponent("out.m4b").path)
  }

  func testStaleRunningStateIsRecoveredBeforeAttempt() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appendingPathComponent("invalid.epub")
    let sourceData = Data("not an epub".utf8)
    try sourceData.write(to: source)
    let digest = SHA256.hash(data: sourceData).map { String(format: "%02x", $0) }.joined()
    let request = BookJobRequest(
      title: "Crash recovery", author: nil,
      source: .init(path: source.path, sha256: digest, format: "epub", importerVersion: 1),
      narration: .init(
        backendID: "siri", modelID: "siri-private", voiceID: "invalid",
        includedSectionIDs: [], bitrateKbps: 64, workers: 1,
        paragraphPauseSeconds: 0.6, chapterPauseSeconds: 1.75, announceTitles: true),
      m4bOutputPath: root.appendingPathComponent("out.m4b").path)
    let store = BookJobStore(root: root.appendingPathComponent("jobs"))
    var state = try await store.create(request)
    try state.transition(to: .running)
    try state.updateStage(.m4bSynthesis, status: .running, fraction: 0.2)
    try await store.saveState(state)

    do {
      try await BookJobExecutor(
        store: store, audiobookExecutable: URL(fileURLWithPath: "/usr/bin/false"),
        executionLockURL: nil
      ).run(id: request.id)
      XCTFail("invalid source should not complete")
    } catch {}

    let recovered = try await store.loadState(request.id)
    XCTAssertEqual(recovered.lifecycle, .needsAttention)
    XCTAssertFalse(recovered.stages.contains(where: { $0.status == .running }))
    XCTAssertFalse(recovered.lastError?.contains("only one job stage") == true)
  }

  func testCancelDuringQueuedLaunchTargetsNextAttempt() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = BookJobStore(root: root.appendingPathComponent("jobs"))
    let value = try request(root: root)
    _ = try await store.create(value)
    let runner = BookJobProcessRunner(
      executable: URL(fileURLWithPath: "/usr/bin/false"), store: store)
    let stream = runner.run(id: value.id)
    try await runner.interrupt(.cancel)
    for _ in 0..<100 {
      if try await store.loadControl(value.id).cancelRequestedForAttempt == 1 { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    let control = try await store.loadControl(value.id)
    XCTAssertEqual(control.cancelRequestedForAttempt, 1)
    XCTAssertEqual(control.interruption?.kind, .cancel)
    _ = stream
  }

  func testDeliveryOnlyJobSkipsSynthesisAndVerifiesSelectedSource() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    var value = try request(root: root)
    value.operation = .storytellerDelivery
    value.storyteller = .init(
      connectionID: UUID(),
      remoteBookID: UUID(),
      products: [.sourceEPUB])
    let store = BookJobStore(root: root.appendingPathComponent("jobs"))
    _ = try await store.create(value)

    do {
      try await BookJobExecutor(
        store: store, audiobookExecutable: URL(fileURLWithPath: "/usr/bin/false"),
        executionLockURL: nil
      ).run(id: value.id)
      XCTFail("the intentionally missing Storyteller connection must stop delivery")
    } catch {}

    let state = try await store.loadState(value.id)
    XCTAssertEqual(state.products.map(\.kind), [.sourceEPUB])
    XCTAssertEqual(
      state.stages.first(where: { $0.stage == .m4bSynthesis })?.status, .skipped)
    XCTAssertFalse(FileManager.default.fileExists(atPath: value.m4bOutputPath))
  }
}

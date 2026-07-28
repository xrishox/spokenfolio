import Foundation
import LibraryKit
import ReadAloudKit
import StorytellerKit

struct ReadAloudAuditService: Sendable {
  private let auditor = ReadAloudQualityAuditor()

  func auditLocal(
    epub: URL, sourceEPUB: URL? = nil,
    target: LibraryReadAloudAuditTarget? = nil,
    runID: UUID? = nil,
    mode: ReadAloudAuditMode = .standard,
    retainedTranscriptions: URL? = nil,
    retainedTranscriptionsAreBound: Bool = false,
    workDirectory: URL? = nil, useFreshASR: Bool = true,
    progress: @escaping @Sendable (ReadAloudAuditProgress) -> Void = { _ in }
  ) async throws -> ReadAloudAuditReport {
    let store = try LibraryStore(databaseURL: AppPaths.libraryDatabaseURL)
    let recorder = try ReadAloudAuditRecorder(
      store: store,
      target: target ?? .standalone(path: epub.standardizedFileURL.path),
      mode: mode, runID: runID)
    return try await performAudit(
      epub: epub, sourceEPUB: sourceEPUB, mode: mode,
      retainedTranscriptions: retainedTranscriptions,
      retainedTranscriptionsAreBound: retainedTranscriptionsAreBound,
      workDirectory: workDirectory, useFreshASR: useFreshASR,
      recorder: recorder, progress: progress)
  }

  private func performAudit(
    epub: URL, sourceEPUB: URL?, mode: ReadAloudAuditMode,
    retainedTranscriptions: URL?, retainedTranscriptionsAreBound: Bool,
    workDirectory: URL?, useFreshASR: Bool,
    recorder: ReadAloudAuditRecorder,
    progress: @escaping @Sendable (ReadAloudAuditProgress) -> Void
  ) async throws -> ReadAloudAuditReport {
    let progressSerial = ReadAloudProgressSerial(recorder: recorder)
    do {
      let tools = try await resolveTools(requireASR: useFreshASR)
      let report = try await auditor.audit(
        .init(
          epub: epub, sourceEPUB: sourceEPUB, mode: mode,
          retainedTranscriptions: retainedTranscriptions,
          retainedTranscriptionsAreBound: retainedTranscriptionsAreBound,
          workDirectory: workDirectory, useFreshASR: useFreshASR),
        tools: tools
      ) { value in
        progress(value)
        progressSerial.submit(value)
      }
      await progressSerial.drain()
      return try await recorder.complete(report)
    } catch is CancellationError {
      try await recorder.fail("Audit cancelled", cancelled: true)
      throw CancellationError()
    } catch {
      try await recorder.fail(error.localizedDescription, cancelled: false)
      throw error
    }
  }

  /// Downloads only Storyteller's ReadAloud and optional source EPUB into a
  /// private disposable workspace. The remote audiobook is never requested.
  /// Retained server transcripts are advisory; fresh ASR remains the standard
  /// semantic check unless a future adapter can cryptographically bind them to
  /// the embedded members.
  func auditStoryteller(
    client: StorytellerClient, connectionID: UUID, book: StorytellerBook,
    runID: UUID? = nil,
    mode: ReadAloudAuditMode = .standard,
    progress: @escaping @Sendable (ReadAloudAuditProgress) -> Void = { _ in }
  ) async throws -> ReadAloudAuditReport {
    guard let asset = book.asset(.readaloud) else {
      throw StorytellerAPIError.invalidResponse("the book has no available ReadAloud asset")
    }
    let store = try LibraryStore(databaseURL: AppPaths.libraryDatabaseURL)
    let recorder = try ReadAloudAuditRecorder(
      store: store,
      target: .remote(
        connectionID: connectionID, bookID: book.uuid, assetID: asset.uuid),
      mode: mode, runID: runID)
    do {
    let root = AppPaths.applicationSupportDirectory
      .appendingPathComponent("readaloud-audits", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let readAloud = root.appendingPathComponent("remote-readaloud.epub")
    progress(.init(fraction: 0.01, message: "Downloading Storyteller ReadAloud"))
    _ = try await client.downloadAsset(
      bookID: book.uuid, format: .readaloud, to: readAloud)

    var source: URL?
    if book.asset(.ebook) != nil {
      let value = root.appendingPathComponent("remote-source.epub")
      do {
        _ = try await client.downloadAsset(bookID: book.uuid, format: .ebook, to: value)
        source = value
      } catch {
        // Source comparison improves diagnosis but is not required to inspect
        // the ReadAloud itself. The final report remains explicit about its
        // semantic evidence adequacy.
      }
    }

    let transcriptions = root.appendingPathComponent("retained-transcriptions", isDirectory: true)
    if let report = try? await client.alignmentReport(bookID: book.uuid) {
      try? report.write(
        to: root.appendingPathComponent("storyteller-report.json"), options: .atomic)
      let candidates = Self.transcriptionCandidates(report)
      if !candidates.isEmpty {
        try FileManager.default.createDirectory(
          at: transcriptions, withIntermediateDirectories: true)
        var totalBytes = 0
        for filename in candidates.prefix(256) {
          if let data = try? await client.retainedTranscription(
            bookID: book.uuid, filename: filename, maximumBytes: 8 << 20)
          {
            guard totalBytes + data.count <= 128 << 20 else { break }
            totalBytes += data.count
            try? data.write(to: transcriptions.appendingPathComponent(filename), options: .atomic)
          }
        }
      }
    }
    let hasTranscriptions =
      (try? FileManager.default.contentsOfDirectory(atPath: transcriptions.path))
      .map { !$0.isEmpty } ?? false
    return try await performAudit(
      epub: readAloud, sourceEPUB: source,
      mode: mode,
      retainedTranscriptions: hasTranscriptions ? transcriptions : nil,
      retainedTranscriptionsAreBound: false,
      workDirectory: root.appendingPathComponent("analysis", isDirectory: true),
      useFreshASR: true, recorder: recorder, progress: progress)
    } catch is CancellationError {
      try await recorder.fail("Audit cancelled", cancelled: true)
      throw CancellationError()
    } catch {
      try await recorder.fail(error.localizedDescription, cancelled: false)
      throw error
    }
  }

  private func resolveTools(requireASR: Bool) async throws -> ReadAloudAuditTools {
    if requireASR {
      let tools = try await ReadAloudTools.resolve(managedStalign: AppPaths.managedStalignURL)
      return ReadAloudAuditTools(
        stalign: tools.stalign, ffmpeg: tools.ffmpeg, ffprobe: tools.ffprobe,
        epubcheck: tools.epubcheck,
        modelHome: AppPaths.readAloudToolDirectory.appendingPathComponent("stalign-home"),
        stalignIdentity: "stalign:\(tools.stalignVersion):\(tools.stalignSHA256)",
        ffmpegIdentity: tools.ffmpeg.path,
        epubcheckIdentity: tools.epubcheckVersion)
    }
    let tools = try ReadAloudTools.resolveFFmpegOnly()
    let compliance = try await ReadAloudTools.resolveEPUBCompliance()
    return ReadAloudAuditTools(
      stalign: nil, ffmpeg: tools.ffmpeg, ffprobe: tools.ffprobe,
      epubcheck: compliance.epubcheck,
      ffmpegIdentity: tools.ffmpeg.path, epubcheckIdentity: compliance.version)
  }

  static func transcriptionCandidates(_ data: Data) -> [String] {
    guard let root = try? JSONSerialization.jsonObject(with: data) else { return [] }
    var values = Set<String>()
    func visit(_ value: Any) {
      if let array = value as? [Any] {
        array.forEach(visit)
      } else if let object = value as? [String: Any] {
        if let audioFiles = object["audioFiles"] as? [[String: Any]] {
          for audio in audioFiles {
            guard let path = audio["filepath"] as? String else { continue }
            let basename = URL(fileURLWithPath: path).lastPathComponent
            let stem = (basename as NSString).deletingPathExtension
            guard !stem.isEmpty, stem.utf8.count <= 240,
              stem.unicodeScalars.allSatisfy({
                CharacterSet.alphanumerics.contains($0) || "-_. ".unicodeScalars.contains($0)
              })
            else { continue }
            values.insert(stem + ".json")
          }
        }
        object.values.forEach(visit)
      }
    }
    visit(root)
    return values.sorted()
  }

  static func persistCompleted(
    _ report: ReadAloudAuditReport, target: LibraryReadAloudAuditTarget,
    store: LibraryStore
  ) throws {
    if case .remote(let connectionID, let bookID, let assetID) = target {
      try store.recordRemoteAssetHash(
        connectionID: connectionID, bookID: bookID, assetID: assetID,
        format: .readaloud, sha256: report.artifactSHA256)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let findings = try report.findings.map { finding in
      LibraryReadAloudAuditFinding(
        id: finding.id, dimension: finding.dimension.rawValue,
        code: finding.code.rawValue, verdict: finding.verdict.rawValue,
        confidence: finding.confidence.rawValue, summary: finding.summary,
        evidenceData: try encoder.encode(finding))
    }
    try store.saveReadAloudAudit(
      LibraryReadAloudAuditRun(
        id: report.id, target: target, artifactSHA256: report.artifactSHA256,
        referenceSHA256: report.referenceSHA256,
        analyzerIdentity: report.analyzerIdentity, policyVersion: report.policyVersion,
        mode: report.mode.rawValue, lifecycle: .completed, progress: 1,
        progressMessage: "Complete", verdict: report.verdict.rawValue,
        evidenceAdequacy: report.evidenceAdequacy.rawValue,
        modelIdentity: report.modelIdentity, toolIdentity: report.toolIdentity,
        metricsData: try encoder.encode(report.metrics), reportData: try encoder.encode(report),
        startedAt: report.startedAt, updatedAt: report.completedAt,
        completedAt: report.completedAt, findings: findings))
  }
}

private actor ReadAloudAuditRecorder {
  private let store: LibraryStore
  private var run: LibraryReadAloudAuditRun

  init(
    store: LibraryStore, target: LibraryReadAloudAuditTarget,
    mode: ReadAloudAuditMode, runID: UUID? = nil
  ) throws {
    self.store = store
    run = LibraryReadAloudAuditRun(
      id: runID ?? UUID(), target: target, mode: mode.rawValue, lifecycle: .running,
      progress: 0, progressMessage: "Starting audit")
    try store.saveReadAloudAudit(run)
  }

  func record(_ value: ReadAloudAuditProgress) {
    run.progress = max(run.progress, min(0.99, value.fraction))
    run.progressMessage = value.message
    run.updatedAt = Date()
    try? store.saveReadAloudAudit(run)
  }

  func complete(_ report: ReadAloudAuditReport) throws -> ReadAloudAuditReport {
    var stable = report
    stable.id = run.id
    try ReadAloudAuditService.persistCompleted(stable, target: run.target, store: store)
    return stable
  }

  func fail(_ message: String, cancelled: Bool) throws {
    run.lifecycle = cancelled ? .cancelled : .failed
    run.error = String(message.prefix(4_096))
    run.progressMessage = cancelled ? "Cancelled" : "Failed"
    run.updatedAt = Date()
    run.completedAt = run.updatedAt
    try store.saveReadAloudAudit(run)
  }
}

private final class ReadAloudProgressSerial: @unchecked Sendable {
  private let lock = NSLock()
  private let recorder: ReadAloudAuditRecorder
  private var tail: Task<Void, Never>?

  init(recorder: ReadAloudAuditRecorder) { self.recorder = recorder }

  func submit(_ value: ReadAloudAuditProgress) {
    lock.withLock {
      let previous = tail
      tail = Task {
        await previous?.value
        await recorder.record(value)
      }
    }
  }

  func drain() async {
    let current = lock.withLock { tail }
    await current?.value
  }
}

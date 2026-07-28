import AudiobookKit
import BookJobKit
import EPUBKit
import Foundation
import PublicationKit

/// A server-side Create draft: one imported (or importing) EPUB with the
/// planning data the Create screen needs. Value type, safe for any interface.
struct WebDraft: Identifiable, Sendable {
  enum Status: Sendable, Equatable {
    case uploading
    case loading
    case ready
    case invalid(String)
    case skipped(String)
    case queued
  }

  struct Section: Sendable, Equatable {
    let id: Int
    let title: String
    let role: String
    let characterCount: Int
    let initiallyIncluded: Bool
    var included: Bool
  }

  let id: UUID
  var sourceURL: URL
  var displayName: String
  var status: Status = .uploading
  var sourceSHA256 = ""
  var sourceSize: UInt64 = 0
  var metadata: PublicationMetadata?
  var coverData: Data?
  var chapterCount = 0
  var sections: [Section] = []
  var catalogRecord: BookCatalogRecord?
}

/// Server-side Create drafts for the web interface: uploads land in a
/// bounded scratch directory and go through the exact import pipeline the
/// desktop Create screen uses (source stability → EPUB 3 normalization and
/// EPUBCheck → import → audiobook plan → duplicate detection → catalog
/// lookup), at most two imports at a time. Scratch files from prior processes
/// are removed on construction; drafts are volatile, matching the desktop
/// batch.
actor DraftImportService {
  static let maximumUploadBytes: UInt64 = 2 << 30
  static let maximumConcurrentImports = 2

  private let catalogStore: BookCatalogStore
  private let scratchRoot: URL
  private let complianceToolchain: EPUBComplianceToolchain?
  private var drafts: [WebDraft] = []
  private var running = 0
  private var waiting: [UUID] = []
  private var revision: UInt64 = 0
  private var subscribers: [UUID: AsyncStream<UInt64>.Continuation] = [:]

  init(
    catalogStore: BookCatalogStore = BookCatalogStore(root: AppPaths.bookCatalogRoot),
    scratchRoot: URL = AppPaths.applicationSupportDirectory
      .appendingPathComponent("web-uploads", isDirectory: true),
    complianceToolchain: EPUBComplianceToolchain? = nil
  ) {
    self.catalogStore = catalogStore
    self.scratchRoot = scratchRoot
    self.complianceToolchain = complianceToolchain
    try? FileManager.default.removeItem(at: scratchRoot)
    try? FileManager.default.createDirectory(
      at: scratchRoot, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
  }

  // MARK: - Observation

  var currentRevision: UInt64 { revision }
  var allDrafts: [WebDraft] { drafts }

  func draft(_ id: UUID) -> WebDraft? {
    drafts.first { $0.id == id }
  }

  /// Yields the current revision immediately, then after every change.
  func revisions() -> AsyncStream<UInt64> {
    let id = UUID()
    return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
      subscribers[id] = continuation
      continuation.yield(revision)
      continuation.onTermination = { _ in
        Task { [weak self] in await self?.removeSubscriber(id) }
      }
    }
  }

  private func removeSubscriber(_ id: UUID) {
    subscribers[id] = nil
  }

  private func changed() {
    revision &+= 1
    for continuation in subscribers.values { continuation.yield(revision) }
  }

  // MARK: - Draft creation

  /// Reserves a scratch destination for a streamed upload. The caller
  /// streams the request body to `scratchURL` and then calls
  /// `finishUpload`; on failure it calls `abandonUpload`.
  func allocateUpload(filename: String) -> (id: UUID, scratchURL: URL) {
    let id = UUID()
    let safeName = filename.split(separator: "/").last.map(String.init) ?? "book.epub"
    let directory = scratchRoot.appendingPathComponent(id.uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let url = directory.appendingPathComponent(safeName)
    var draft = WebDraft(id: id, sourceURL: url, displayName: safeName)
    draft.status = .uploading
    drafts.append(draft)
    changed()
    return (id, url)
  }

  func finishUpload(_ id: UUID) {
    guard let index = drafts.firstIndex(where: { $0.id == id }) else { return }
    drafts[index].status = .loading
    changed()
    scheduleImport(id)
  }

  func abandonUpload(_ id: UUID) {
    remove(id)
  }

  /// Imports an EPUB already on this Mac without copying it.
  func createFromPath(_ path: String) throws -> WebDraft {
    let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
      .standardizedFileURL
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
      !isDirectory.boolValue, url.pathExtension.lowercased() == "epub"
    else {
      throw BookJobError.io("the path does not name an EPUB file")
    }
    var draft = WebDraft(id: UUID(), sourceURL: url, displayName: url.lastPathComponent)
    draft.status = .loading
    drafts.append(draft)
    changed()
    scheduleImport(draft.id)
    return draft
  }

  func remove(_ id: UUID) {
    guard let index = drafts.firstIndex(where: { $0.id == id }) else { return }
    let draft = drafts.remove(at: index)
    waiting.removeAll { $0 == id }
    if draft.sourceURL.path.hasPrefix(scratchRoot.path) {
      try? FileManager.default.removeItem(
        at: draft.sourceURL.deletingLastPathComponent())
    }
    changed()
  }

  func retry(_ id: UUID) {
    guard let index = drafts.firstIndex(where: { $0.id == id }) else { return }
    switch drafts[index].status {
    case .invalid, .skipped:
      drafts[index].status = .loading
      changed()
      scheduleImport(id)
    default:
      break
    }
  }

  func setSectionIncluded(_ id: UUID, sectionID: Int, included: Bool) {
    guard let index = drafts.firstIndex(where: { $0.id == id }),
      let sectionIndex = drafts[index].sections.firstIndex(where: { $0.id == sectionID })
    else { return }
    drafts[index].sections[sectionIndex].included = included
    changed()
  }

  func markQueued(_ ids: [UUID]) {
    for id in ids {
      guard let index = drafts.firstIndex(where: { $0.id == id }) else { continue }
      drafts[index].status = .queued
      if drafts[index].sourceURL.path.hasPrefix(scratchRoot.path) {
        try? FileManager.default.removeItem(
          at: drafts[index].sourceURL.deletingLastPathComponent())
      }
    }
    changed()
  }

  // MARK: - Import pipeline

  private func scheduleImport(_ id: UUID) {
    waiting.append(id)
    startNextImportsIfPossible()
  }

  private func startNextImportsIfPossible() {
    while running < Self.maximumConcurrentImports, !waiting.isEmpty {
      let id = waiting.removeFirst()
      guard let draft = drafts.first(where: { $0.id == id }) else { continue }
      running += 1
      let url = draft.sourceURL
      let toolchain = complianceToolchain
      Task {
        let result: Result<ImportPayload, Error>
        do {
          result = .success(
            try await Self.importPayload(url: url, complianceToolchain: toolchain))
        } catch {
          result = .failure(error)
        }
        await self.finishImport(id, result: result)
      }
    }
  }

  private struct ImportPayload: Sendable {
    let sha256: String
    let size: UInt64
    let metadata: PublicationMetadata
    let coverData: Data?
    let chapterCount: Int
    let sections: [(Int, String, String, Int, Bool)]
    let prepared: PreparedEPUB
  }

  /// The desktop Create screen's exact import pipeline, including source and
  /// normalized-artifact stability checks.
  private static func importPayload(
    url: URL, complianceToolchain: EPUBComplianceToolchain?
  ) async throws -> ImportPayload {
    let originalHash = try BookFileDigest.sha256(url)
    let originalSize = try BookFileDigest.size(url)
    let prepared = try await EPUBCompliance.prepare(
      source: url, toolchain: complianceToolchain)
    do {
      guard try BookFileDigest.sha256(url) == originalHash,
        try BookFileDigest.size(url) == originalSize
      else {
        throw BookJobError.io(
          "the EPUB changed while it was being checked; retry with a stable source file")
      }
      let hashBeforeImport = try BookFileDigest.sha256(prepared.url)
      let sizeBeforeImport = try BookFileDigest.size(prepared.url)
      let publication = try EPUBImporter().load(url: prepared.url)
      let plan = try AudiobookPlanner.plan(publication: publication)
      let hashAfterImport = try BookFileDigest.sha256(prepared.url)
      let sizeAfterImport = try BookFileDigest.size(prepared.url)
      guard hashBeforeImport == hashAfterImport, sizeBeforeImport == sizeAfterImport else {
        throw BookJobError.io(
          "the EPUB changed while it was being imported; retry with a stable source file")
      }
      return ImportPayload(
        sha256: hashAfterImport, size: sizeAfterImport,
        metadata: plan.metadata, coverData: plan.cover?.data,
        chapterCount: plan.chapters.count,
        sections: plan.sections.map {
          ($0.index, $0.title, $0.role.rawValue, $0.characterCount, $0.included)
        }, prepared: prepared)
    } catch {
      prepared.cleanup()
      throw error
    }
  }

  private func finishImport(_ id: UUID, result: Result<ImportPayload, Error>) async {
    defer {
      running -= 1
      startNextImportsIfPossible()
    }
    guard let index = drafts.firstIndex(where: { $0.id == id }) else { return }
    switch result {
    case .success(let payload):
      defer { payload.prepared.cleanup() }
      if let duplicate = drafts.first(where: {
        guard $0.id != id, !$0.sourceSHA256.isEmpty, $0.sourceSHA256 == payload.sha256
        else { return false }
        switch $0.status {
        case .invalid, .skipped: return false
        default: return true
        }
      }) {
        drafts[index].status = .skipped("Same edition as \(duplicate.displayName)")
      } else {
        if payload.prepared.wasConverted {
          do {
            let directory = scratchRoot.appendingPathComponent(id.uuidString, isDirectory: true)
            try FileManager.default.createDirectory(
              at: directory, withIntermediateDirectories: true,
              attributes: [.posixPermissions: 0o700])
            let normalized = directory.appendingPathComponent("normalized.epub")
            try? FileManager.default.removeItem(at: normalized)
            try FileManager.default.copyItem(at: payload.prepared.url, to: normalized)
            guard try BookFileDigest.sha256(normalized) == payload.sha256 else {
              throw BookJobError.io("the checked EPUB changed while it was staged")
            }
            drafts[index].sourceURL = normalized
          } catch {
            drafts[index].status = .invalid(error.localizedDescription)
            changed()
            return
          }
        }
        drafts[index].sourceSHA256 = payload.sha256
        drafts[index].sourceSize = payload.size
        drafts[index].metadata = payload.metadata
        drafts[index].coverData = payload.coverData
        drafts[index].chapterCount = payload.chapterCount
        drafts[index].sections = payload.sections.map {
          WebDraft.Section(
            id: $0.0, title: $0.1, role: $0.2, characterCount: $0.3,
            initiallyIncluded: $0.4, included: $0.4)
        }
        do {
          drafts[index].catalogRecord = try await catalogStore.find(
            sourceSHA256: payload.sha256)
          drafts[index].status = .ready
        } catch {
          drafts[index].status = .invalid(
            "Library lookup failed: \(error.localizedDescription)")
        }
      }
    case .failure(let error):
      drafts[index].status = .invalid(error.localizedDescription)
    }
    changed()
  }
}

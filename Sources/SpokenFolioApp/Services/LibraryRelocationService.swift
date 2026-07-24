import BookJobKit
import Foundation
import LibraryKit

/// Moves the whole managed book library — one folder per book — to a new
/// user-chosen root. Modeled on `LibraryMirrorService`'s snapshot+publish
/// shape so the desktop pane and the web API poll the same actor.
///
/// One book at a time, sequential, crash-consistent per book: each book's
/// folder is physically moved first (rename, or copy+verify+remove across
/// volumes) and only then are its catalog paths rewritten. Per-book failures
/// never abort the run; a failed book stays at the old root with its catalog
/// paths untouched and appears in `failures`. The run finishes by persisting
/// the destination as the new processed-books root.
actor LibraryRelocationService {
  struct Snapshot: Sendable {
    var isBusy = false
    var total = 0
    var completed = 0
    var currentTitle: String?
    var failures: [(title: String, reason: String)] = []
    var destination: String?
    var sequence: UInt64 = 0
  }

  /// A precondition failure: nothing was moved and nothing was saved.
  struct BlockedError: Error, LocalizedError, Sendable {
    let reason: String
    var errorDescription: String? { reason }
  }

  private struct Plan: Sendable {
    let destination: URL
    let movable: [BookCatalogRecord]
  }

  private let jobs: JobSchedulerService
  private let quality: QualityQueueService
  private let mirror: LibraryMirrorService
  private let libraryDatabaseURL: URL
  private var snapshot = Snapshot()
  private var isStarting = false
  private var worker: Task<Void, Never>?

  init(
    jobs: JobSchedulerService,
    quality: QualityQueueService,
    mirror: LibraryMirrorService,
    libraryDatabaseURL: URL
  ) {
    self.jobs = jobs
    self.quality = quality
    self.mirror = mirror
    self.libraryDatabaseURL = libraryDatabaseURL
  }

  var currentSnapshot: Snapshot { snapshot }

  private func publish(_ mutate: (inout Snapshot) -> Void) {
    mutate(&snapshot)
    snapshot.sequence &+= 1
  }

  /// Validates preconditions and runs the whole relocation to completion
  /// (the desktop path awaits this while polling `currentSnapshot`).
  func relocate(to destination: URL) async throws {
    let plan = try await prepare(destination)
    await run(plan)
  }

  /// Validates preconditions synchronously with respect to the caller, then
  /// runs the relocation in the background (the web PUT path): every
  /// precondition failure throws before any file is touched so the HTTP
  /// handler can answer 409, and a success returns with `isBusy` already
  /// published for the immediate settings response.
  func start(to destination: URL) async throws {
    let plan = try await prepare(destination)
    worker = Task { await self.run(plan) }
  }

  // MARK: - Preconditions

  private func prepare(_ destination: URL) async throws -> Plan {
    guard !snapshot.isBusy, !isStarting else {
      throw BlockedError(reason: "A library move is already in progress.")
    }
    isStarting = true
    defer { isStarting = false }

    let jobsSnapshot = await jobs.currentSnapshot
    guard jobsSnapshot.queuedCount == 0, jobsSnapshot.runningCount == 0 else {
      throw BlockedError(
        reason: "Book production jobs are queued or running. "
          + "Finish or cancel them before moving the library.")
    }
    guard !quality.currentSnapshot.isBusy else {
      throw BlockedError(
        reason: "A ReadAloud quality check is running. "
          + "Wait for it to finish before moving the library.")
    }
    let databaseURL = libraryDatabaseURL
    let hasQueuedAudits: Bool
    do {
      hasQueuedAudits = try await Task.detached(priority: .utility) {
        try LibraryStore(databaseURL: databaseURL)
          .readAloudAudits(limit: 5_000)
          .contains { $0.lifecycle == .queued }
      }.value
    } catch {
      throw BlockedError(
        reason: "Could not read the quality queue: \(Self.message(error))")
    }
    guard !hasQueuedAudits else {
      throw BlockedError(
        reason: "ReadAloud quality checks are waiting in the queue. "
          + "Run or cancel them before moving the library.")
    }
    let mirrorBusy = await mirror.currentSnapshot.isBusy
    guard !mirrorBusy else {
      throw BlockedError(
        reason: "Storyteller downloads are in progress. "
          + "Wait for them to finish before moving the library.")
    }

    guard destination.isFileURL, (destination.path as NSString).isAbsolutePath else {
      throw BlockedError(reason: "The destination must be an absolute folder path.")
    }
    let dest = destination.standardizedFileURL
    let home = FileManager.default.homeDirectoryForCurrentUser
    let currentRoot: URL
    do {
      currentRoot = (try await StudioSettingsStore(url: AppPaths.studioSettingsURL).load())
        .resolvedProcessedDirectory(home: home).standardizedFileURL
    } catch {
      throw BlockedError(
        reason: "Could not read the current storage settings: \(Self.message(error))")
    }
    if dest.path == currentRoot.path
      || dest.path.hasPrefix(currentRoot.path + "/")
      || currentRoot.path.hasPrefix(dest.path + "/") {
      throw BlockedError(
        reason: "The new folder must be outside the current book library "
          + "at \(currentRoot.path).")
    }
    do {
      try FileManager.default.createDirectory(
        at: dest, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o755])
    } catch {
      throw BlockedError(
        reason: "Could not create the destination folder: \(Self.message(error))")
    }
    guard FileManager.default.isWritableFile(atPath: dest.path) else {
      throw BlockedError(reason: "The destination folder is not writable.")
    }

    let records: [BookCatalogRecord]
    do {
      records = try await BookCatalogStore(root: AppPaths.bookCatalogRoot).scan().records
    } catch {
      throw BlockedError(reason: "Could not read the book catalog: \(Self.message(error))")
    }
    let movable = records.filter {
      let path = URL(fileURLWithPath: $0.outputDirectory).standardizedFileURL.path
      return path != currentRoot.path && path.hasPrefix(currentRoot.path + "/")
    }.sorted {
      $0.outputBaseName.localizedStandardCompare($1.outputBaseName) == .orderedAscending
    }
    publish {
      $0.isBusy = true
      $0.total = movable.count
      $0.completed = 0
      $0.currentTitle = nil
      $0.failures = []
      $0.destination = dest.path
    }
    return Plan(destination: dest, movable: movable)
  }

  // MARK: - Execution

  private func run(_ plan: Plan) async {
    defer { worker = nil }
    let databaseURL = libraryDatabaseURL
    for record in plan.movable {
      publish { $0.currentTitle = record.metadata.title }
      let source = URL(fileURLWithPath: record.outputDirectory, isDirectory: true)
        .standardizedFileURL
      let target = plan.destination
        .appendingPathComponent(record.outputBaseName, isDirectory: true)
      // The exact stored string is the rewrite prefix; the database matches
      // prefixes literally.
      let oldPrefix = record.outputDirectory
      do {
        try await Task.detached(priority: .utility) {
          try Self.performMove(record: record, source: source, target: target)
          // The physical move succeeded; now make the database agree. A
          // failure here is reported, not rolled back — the files at the
          // destination are authoritative for a retry.
          do {
            try LibraryStore(databaseURL: databaseURL)
              .rewriteOwnedPathPrefix(from: oldPrefix, to: target.path)
          } catch {
            throw BookJobError.corruptState(
              "the files moved, but the catalog paths could not be updated: "
                + Self.message(error))
          }
        }.value
      } catch {
        publish { $0.failures.append((record.metadata.title, Self.message(error))) }
      }
      publish { $0.completed += 1 }
    }
    do {
      try await StudioSettingsStore(url: AppPaths.studioSettingsURL)
        .save(StudioSettings(processedDirectory: plan.destination.path))
    } catch {
      publish {
        $0.failures.append(
          ("Storage settings", "could not save the new location: \(Self.message(error))"))
      }
    }
    publish {
      $0.isBusy = false
      $0.currentTitle = nil
    }
  }

  /// Renames one book folder into the destination, falling back to
  /// copy+verify+remove when the destination is on another volume.
  nonisolated static func performMove(
    record: BookCatalogRecord, source: URL, target: URL
  ) throws {
    let fileManager = FileManager.default
    guard !fileManager.fileExists(atPath: target.path) else {
      throw BookJobError.invalidRequest(
        "a folder named “\(target.lastPathComponent)” already exists at the destination")
    }
    do {
      try fileManager.moveItem(at: source, to: target)
    } catch let error where isCrossVolume(error) {
      try copyVerifyRemove(record: record, source: source, target: target)
    }
  }

  /// Cross-volume path: copy the folder, verify every catalog product's
  /// digest in the copy, then remove the source. Any failure removes the
  /// half-copied target and leaves the source untouched.
  nonisolated static func copyVerifyRemove(
    record: BookCatalogRecord, source: URL, target: URL
  ) throws {
    let fileManager = FileManager.default
    do {
      try fileManager.copyItem(at: source, to: target)
      let sourcePath = source.standardizedFileURL.path
      for product in record.products {
        let productPath = URL(fileURLWithPath: product.path).standardizedFileURL.path
        guard productPath.hasPrefix(sourcePath + "/") else { continue }
        let copied = URL(fileURLWithPath: target.path + productPath.dropFirst(sourcePath.count))
        guard try BookFileDigest.sha256(copied) == product.sha256 else {
          throw BookJobError.io(
            "the copy of \(copied.lastPathComponent) failed checksum verification")
        }
      }
    } catch {
      try? fileManager.removeItem(at: target)
      throw error
    }
    try fileManager.removeItem(at: source)
  }

  private nonisolated static func isCrossVolume(_ error: Error) -> Bool {
    var current: (any Error)? = error
    while let value = current {
      let nsError = value as NSError
      if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(EXDEV) { return true }
      if nsError.domain == NSCocoaErrorDomain,
        nsError.code == NSFileWriteVolumeReadOnlyError {
        return true
      }
      current = nsError.userInfo[NSUnderlyingErrorKey] as? any Error
    }
    return false
  }

  private nonisolated static func message(_ error: Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
  }
}

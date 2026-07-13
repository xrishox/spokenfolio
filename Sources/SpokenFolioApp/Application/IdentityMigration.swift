import BookJobKit
import CryptoKit
import Darwin
import Foundation

enum IdentityMigrationOutcome: Equatable {
  case freshInstall, alreadyCurrent, migrated, cleanupCompleted
}

struct IdentityMigrationError: Error, LocalizedError, Equatable {
  let message: String
  var errorDescription: String? { message }
}

/// The sole compatibility boundary for the former product identity. It is a
/// journaled same-volume move: large audio and alignment artifacts are never copied.
struct IdentityMigrationCoordinator {
  private enum Phase: String, Codable {
    case prepared, dataMoved, dataValidated, committed
  }

  private struct Journal: Codable {
    var version = 1
    var transactionID: UUID
    var phase: Phase
    var connectionIDs: [UUID]
  }

  private struct Inventory: Equatable {
    var jobCount: Int
    var jobIssues: Set<String>
    var catalogCount: Int
    var catalogIssues: Set<String>
    var fileCount: Int
    var stalignHash: String?
  }

  private let fileManager: FileManager
  private let legacyRoot: URL
  private let currentRoot: URL
  private let defaults: UserDefaults
  private let legacyDefaultsDomain: String
  private let currentDefaultsDomain: String
  private let afterDataValidation: () throws -> Void

  init(
    fileManager: FileManager = .default,
    legacyRoot: URL = AppIdentity.legacyApplicationSupportDirectory,
    currentRoot: URL = AppIdentity.applicationSupportDirectory,
    defaults: UserDefaults = .standard,
    legacyDefaultsDomain: String = AppIdentity.legacyBundleIdentifier,
    currentDefaultsDomain: String = AppIdentity.bundleIdentifier,
    afterDataValidation: @escaping () throws -> Void = {}
  ) {
    self.fileManager = fileManager
    self.legacyRoot = legacyRoot.standardizedFileURL
    self.currentRoot = currentRoot.standardizedFileURL
    self.defaults = defaults
    self.legacyDefaultsDomain = legacyDefaultsDomain
    self.currentDefaultsDomain = currentDefaultsDomain
    self.afterDataValidation = afterDataValidation
  }

  func run() throws -> IdentityMigrationOutcome {
    if let recovered = try recoverIfNeeded() { return recovered }
    let legacyExists = fileManager.fileExists(atPath: legacyRoot.path)
    let currentExists = fileManager.fileExists(atPath: currentRoot.path)
    if currentExists && legacyExists {
      throw IdentityMigrationError(
        message: "Both legacy and SpokenFolio data directories contain state; refusing to merge them.")
    }
    if currentExists { return .alreadyCurrent }
    guard legacyExists else { return .freshInstall }

    let locks = try acquireLegacyLocks()
    defer { _fixLifetime(locks) }
    let before = try inventory(root: legacyRoot)
    let connections = try loadConnections(root: legacyRoot)
    let connectionIDs = connections.map(\.id)
    let journal = Journal(
      transactionID: UUID(), phase: .prepared, connectionIDs: connectionIDs)
    try saveJournal(journal)

    let previousCurrentDefaults = defaults.persistentDomain(
      forName: currentDefaultsDomain)
    do {
      try fileManager.moveItem(at: legacyRoot, to: stagingRoot)
      try updateJournal(journal, phase: .dataMoved)
      try rewriteOwnedPaths(root: stagingRoot, mappings: forwardMappings)
      try fileManager.moveItem(at: stagingRoot, to: currentRoot)
      let after = try inventory(root: currentRoot)
      guard before == after else {
        throw IdentityMigrationError(
          message: "Migrated jobs, catalog records, files, or tool identity did not validate.")
      }
      try updateJournal(journal, phase: .dataValidated)
      try afterDataValidation()

      migrateWindowFrame()
      try updateJournal(journal, phase: .committed)
      do {
        cleanupLegacy()
        try fileManager.removeItem(at: journalURL)
      } catch {
        // The new identity is authoritative after commit. A credential-free
        // journal lets the next launch retry cleanup without exposing tokens.
      }
      return .migrated
    } catch {
      if let previousCurrentDefaults {
        defaults.setPersistentDomain(previousCurrentDefaults, forName: currentDefaultsDomain)
      } else {
        defaults.removePersistentDomain(forName: currentDefaultsDomain)
      }
      do {
        try restoreLegacyRoot()
        try rewriteOwnedPaths(root: legacyRoot, mappings: reverseMappings)
        try fileManager.removeItem(at: journalURL)
      } catch let rollbackError {
        throw IdentityMigrationError(
          message: "Migration failed and automatic rollback could not be completed: \(rollbackError.localizedDescription)")
      }
      throw error
    }
  }

  private var stagingRoot: URL {
    currentRoot.deletingLastPathComponent().appendingPathComponent(
      ".\(currentRoot.lastPathComponent).migrating", isDirectory: true)
  }

  private var journalURL: URL {
    currentRoot.deletingLastPathComponent().appendingPathComponent(
      ".\(currentRoot.lastPathComponent).migration.json")
  }

  private func recoverIfNeeded() throws -> IdentityMigrationOutcome? {
    guard fileManager.fileExists(atPath: journalURL.path) else {
      if fileManager.fileExists(atPath: stagingRoot.path) {
        throw IdentityMigrationError(
          message: "An unrecognized SpokenFolio migration staging directory exists.")
      }
      return nil
    }
    let journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: journalURL))
    guard journal.version == 1 else {
      throw IdentityMigrationError(message: "Unsupported identity migration journal.")
    }
    if journal.phase == .committed {
      cleanupLegacy()
      try fileManager.removeItem(at: journalURL)
      return .cleanupCompleted
    }
    defaults.removePersistentDomain(forName: currentDefaultsDomain)
    try restoreLegacyRoot()
    try rewriteOwnedPaths(root: legacyRoot, mappings: reverseMappings)
    try fileManager.removeItem(at: journalURL)
    return nil
  }

  private func restoreLegacyRoot() throws {
    if fileManager.fileExists(atPath: legacyRoot.path) { return }
    if fileManager.fileExists(atPath: currentRoot.path) {
      try fileManager.moveItem(at: currentRoot, to: legacyRoot)
    } else if fileManager.fileExists(atPath: stagingRoot.path) {
      try fileManager.moveItem(at: stagingRoot, to: legacyRoot)
    }
  }

  private func acquireLegacyLocks() throws -> [BookFileLock] {
    do {
      var locks = [
        try BookFileLock(url: legacyRoot.appendingPathComponent("scheduler.lock"), nonblocking: true),
        try BookFileLock(
          url: legacyRoot.appendingPathComponent("studio-execution.lock"), nonblocking: true),
      ]
      let jobs = legacyRoot.appendingPathComponent("production-jobs")
      if let directories = try? fileManager.contentsOfDirectory(
        at: jobs, includingPropertiesForKeys: [.isDirectoryKey])
      {
        for directory in directories where (try? directory.resourceValues(
          forKeys: [.isDirectoryKey]).isDirectory) == true
        {
          locks.append(
            try BookFileLock(url: directory.appendingPathComponent("run.lock"), nonblocking: true))
        }
      }
      return locks
    } catch {
      throw IdentityMigrationError(
        message: "SpokenFolio cannot migrate data while the legacy scheduler or a book job is active.")
    }
  }

  private func inventory(root: URL) throws -> Inventory {
    var validJobs = 0
    var jobIssues = Set<String>()
    let jobRoot = root.appendingPathComponent("production-jobs")
    for directory in (try? fileManager.contentsOfDirectory(
      at: jobRoot, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
    where (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
      guard UUID(uuidString: directory.lastPathComponent) != nil else { continue }
      do { try validateJob(directory); validJobs += 1 } catch { jobIssues.insert(directory.lastPathComponent) }
    }

    var validCatalog = 0
    var catalogIssues = Set<String>()
    let catalogRoot = root.appendingPathComponent("book-catalog")
    for directory in (try? fileManager.contentsOfDirectory(
      at: catalogRoot, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
    where (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
      guard UUID(uuidString: directory.lastPathComponent) != nil else { continue }
      do {
        let record = try JSONDecoder().decode(
          BookCatalogRecord.self,
          from: Data(contentsOf: directory.appendingPathComponent("record.json")))
        try record.validate()
        validCatalog += 1
      } catch { catalogIssues.insert(directory.lastPathComponent) }
    }

    var fileCount = 0
    if let files = fileManager.enumerator(
      at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
    {
      while let url = files.nextObject() as? URL {
        if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
          fileCount += 1
        }
      }
    }
    let stalign = root.appendingPathComponent("tools/readaloud/stalign")
    return Inventory(
      jobCount: validJobs, jobIssues: jobIssues,
      catalogCount: validCatalog, catalogIssues: catalogIssues,
      fileCount: fileCount,
      stalignHash: fileManager.fileExists(atPath: stalign.path) ? try sha256(stalign) : nil)
  }

  private func validateJob(_ directory: URL) throws {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .deferredToDate
    let requestData = try Data(contentsOf: directory.appendingPathComponent("request.json"))
    let request = try decoder.decode(BookJobRequest.self, from: requestData)
    try request.validate()
    let state = try decoder.decode(
      BookJobState.self, from: Data(contentsOf: directory.appendingPathComponent("state.json")))
    guard state.jobID == request.id, state.requestSHA256 == sha256(requestData) else {
      throw IdentityMigrationError(message: "Job request checksum mismatch.")
    }
    _ = try decoder.decode(
      BookJobControl.self, from: Data(contentsOf: directory.appendingPathComponent("control.json")))
  }

  private func loadConnections(root: URL) throws -> [StorytellerConnection] {
    let url = root.appendingPathComponent("storyteller-connections.json")
    guard fileManager.fileExists(atPath: url.path) else { return [] }
    return try JSONDecoder().decode([StorytellerConnection].self, from: Data(contentsOf: url))
  }

  private var forwardMappings: [(String, String)] {
    [
      (legacyRoot.path, currentRoot.path),
      ("/Applications/\(AppIdentity.legacyDisplayName).app/Contents/MacOS/\(AppIdentity.legacyExecutableName)",
       "/Applications/\(AppIdentity.displayName).app/Contents/MacOS/\(AppIdentity.executableName)"),
    ]
  }

  private var reverseMappings: [(String, String)] {
    forwardMappings.map { ($0.1, $0.0) }
  }

  private func rewriteOwnedPaths(root: URL, mappings: [(String, String)]) throws {
    let enumerator = fileManager.enumerator(
      at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles])
    var jobRequestURLs: [URL] = []
    while let url = enumerator?.nextObject() as? URL {
      let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      if values.isSymbolicLink == true {
        let target = try fileManager.destinationOfSymbolicLink(atPath: url.path)
        if let replacement = replacePrefix(target, mappings: mappings), replacement != target {
          try fileManager.removeItem(at: url)
          try fileManager.createSymbolicLink(atPath: url.path, withDestinationPath: replacement)
        }
        continue
      }
      guard values.isRegularFile == true, ["json", "ndjson"].contains(url.pathExtension) else {
        continue
      }
      let original = try Data(contentsOf: url)
      let rewritten = try rewriteJSONData(original, ndjson: url.pathExtension == "ndjson", mappings: mappings)
      if rewritten != original { try atomicWrite(rewritten, to: url) }
      if url.lastPathComponent == "request.json",
        url.path.contains("/production-jobs/") { jobRequestURLs.append(url) }
    }
    for requestURL in jobRequestURLs {
      let data = try Data(contentsOf: requestURL)
      let stateURL = requestURL.deletingLastPathComponent().appendingPathComponent("state.json")
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .deferredToDate
      var state = try decoder.decode(BookJobState.self, from: Data(contentsOf: stateURL))
      state.requestSHA256 = sha256(data)
      if let runner = state.runner,
        mappings.contains(where: { runner.executablePath == $0.0 || runner.executablePath.hasPrefix($0.0 + "/") })
      {
        state.runner = nil
      }
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .deferredToDate
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try atomicWrite(try encoder.encode(state), to: stateURL)
    }
  }

  private func rewriteJSONData(
    _ data: Data, ndjson: Bool, mappings: [(String, String)]
  ) throws -> Data {
    if ndjson {
      var result = Data()
      for line in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
        let lineData = Data(line)
        let object = try JSONSerialization.jsonObject(with: lineData, options: [.fragmentsAllowed])
        var changed = false
        let value = rewrite(object, mappings: mappings, changed: &changed)
        result.append(changed ? try JSONSerialization.data(withJSONObject: value) : lineData)
        result.append(UInt8(ascii: "\n"))
      }
      return result
    }
    let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    var changed = false
    let value = rewrite(object, mappings: mappings, changed: &changed)
    guard changed else { return data }
    return try JSONSerialization.data(
      withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
  }

  private func rewrite(
    _ value: Any, mappings: [(String, String)], changed: inout Bool
  ) -> Any {
    switch value {
    case let string as String:
      guard let replacement = replacePrefix(string, mappings: mappings), replacement != string
      else { return string }
      changed = true
      return replacement
    case let array as [Any]:
      return array.map { rewrite($0, mappings: mappings, changed: &changed) }
    case let object as [String: Any]:
      return object.mapValues { rewrite($0, mappings: mappings, changed: &changed) }
    default: return value
    }
  }

  private func replacePrefix(_ value: String, mappings: [(String, String)]) -> String? {
    for (old, new) in mappings where value == old || value.hasPrefix(old + "/") {
      return new + value.dropFirst(old.count)
    }
    return nil
  }

  private func migrateWindowFrame() {
    let oldDomain = defaults.persistentDomain(forName: legacyDefaultsDomain) ?? [:]
    let oldKey = "NSWindow Frame \(AppIdentity.legacyWindowAutosaveName)"
    let newKey = "NSWindow Frame \(AppIdentity.windowAutosaveName)"
    guard let frame = oldDomain[oldKey] else { return }
    var newDomain = defaults.persistentDomain(forName: currentDefaultsDomain) ?? [:]
    if newDomain[newKey] == nil { newDomain[newKey] = frame }
    defaults.setPersistentDomain(newDomain, forName: currentDefaultsDomain)
  }

  private func cleanupLegacy() {
    defaults.removePersistentDomain(forName: legacyDefaultsDomain)
  }

  private func updateJournal(_ journal: Journal, phase: Phase) throws {
    var value = journal
    value.phase = phase
    try saveJournal(value)
  }

  private func saveJournal(_ journal: Journal) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try atomicWrite(try encoder.encode(journal), to: journalURL)
  }

  private func atomicWrite(_ data: Data, to url: URL) throws {
    try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let temporary = url.appendingPathExtension(UUID().uuidString)
    try data.write(to: temporary, options: [])
    _ = chmod(temporary.path, 0o600)
    if rename(temporary.path, url.path) != 0 {
      try? fileManager.removeItem(at: temporary)
      throw IdentityMigrationError(message: String(cString: strerror(errno)))
    }
  }

  private func sha256(_ url: URL) throws -> String { try sha256(Data(contentsOf: url)) }
  private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

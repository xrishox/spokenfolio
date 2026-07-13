import CryptoKit
import Darwin
import Foundation
import PublicationKit

package struct BookCatalogMetadata: Codable, Sendable, Equatable {
  package var title: String
  package var author: String?
  package var language: String?
  package var publisher: String?
  package var publicationDate: String?
  package var identifiers: [PublicationIdentifier]

  package init(
    title: String, author: String?, language: String? = nil, publisher: String? = nil,
    publicationDate: String? = nil, identifiers: [PublicationIdentifier] = []
  ) {
    self.title = title
    self.author = author
    self.language = language
    self.publisher = publisher
    self.publicationDate = publicationDate
    self.identifiers = identifiers
  }
}

package struct BookCatalogSource: Codable, Sendable, Equatable {
  package var format: String
  package var importerVersion: Int
  package var sha256: String
  package var size: UInt64

  package init(format: String, importerVersion: Int, sha256: String, size: UInt64) {
    self.format = format
    self.importerVersion = importerVersion
    self.sha256 = sha256
    self.size = size
  }
}

package struct BookCatalogProduct: Codable, Sendable, Equatable {
  package var kind: BookProductKind
  package var path: String
  package var size: UInt64
  package var sha256: String
  package var verifiedAt: Date
  package var producerJobID: UUID?
  package var narration: BookJobRequest.Narration?
  package var readAloud: BookJobRequest.ReadAloud?

  package init(
    kind: BookProductKind, path: String, size: UInt64, sha256: String,
    verifiedAt: Date, producerJobID: UUID? = nil,
    narration: BookJobRequest.Narration? = nil,
    readAloud: BookJobRequest.ReadAloud? = nil
  ) {
    self.kind = kind
    self.path = path
    self.size = size
    self.sha256 = sha256
    self.verifiedAt = verifiedAt
    self.producerJobID = producerJobID
    self.narration = narration
    self.readAloud = readAloud
  }
}

package struct BookCatalogRemoteReceipt: Codable, Sendable, Equatable {
  package var format: String
  package var localSHA256: String
  package var remoteAssetID: String?
  package var remoteSize: UInt64?
  package var remoteFingerprint: String?
  package var remoteSHA256: String?
  package var observedAt: Date

  package init(
    format: String, localSHA256: String, remoteAssetID: String? = nil,
    remoteSize: UInt64? = nil, remoteFingerprint: String? = nil,
    remoteSHA256: String? = nil, observedAt: Date = Date()
  ) {
    self.format = format
    self.localSHA256 = localSHA256
    self.remoteAssetID = remoteAssetID
    self.remoteSize = remoteSize
    self.remoteFingerprint = remoteFingerprint
    self.remoteSHA256 = remoteSHA256
    self.observedAt = observedAt
  }
}

package struct BookCatalogRemoteLink: Codable, Sendable, Equatable {
  package enum Evidence: String, Codable, Sendable {
    case userConfirmed, exactAssetHash, validatedIdentifier, uploadCreated, legacyJob
  }

  package var providerID: String
  package var connectionID: UUID
  package var remoteBookID: String
  package var evidence: Evidence
  package var linkedAt: Date
  package var lastObservedAt: Date?
  package var remoteTitle: String?
  package var remoteAuthors: [String]
  package var receipts: [BookCatalogRemoteReceipt]
  package var excludedRemoteBookIDs: [String]

  package init(
    providerID: String, connectionID: UUID, remoteBookID: String, evidence: Evidence,
    linkedAt: Date = Date(), lastObservedAt: Date? = nil, remoteTitle: String? = nil,
    remoteAuthors: [String] = [], receipts: [BookCatalogRemoteReceipt] = [],
    excludedRemoteBookIDs: [String] = []
  ) {
    self.providerID = providerID
    self.connectionID = connectionID
    self.remoteBookID = remoteBookID
    self.evidence = evidence
    self.linkedAt = linkedAt
    self.lastObservedAt = lastObservedAt
    self.remoteTitle = remoteTitle
    self.remoteAuthors = remoteAuthors
    self.receipts = receipts
    self.excludedRemoteBookIDs = excludedRemoteBookIDs
  }
}

package struct BookCatalogRecord: Codable, Sendable, Identifiable, Equatable {
  package static let schemaVersion = 1
  package var schemaVersion: Int
  package var id: UUID
  package var revision: UInt64
  package var createdAt: Date
  package var updatedAt: Date
  package var source: BookCatalogSource
  package var metadata: BookCatalogMetadata
  package var outputDirectory: String
  package var outputBaseName: String
  package var products: [BookCatalogProduct]
  package var remoteLinks: [BookCatalogRemoteLink]

  package init(
    id: UUID = UUID(), createdAt: Date = Date(), source: BookCatalogSource,
    metadata: BookCatalogMetadata, outputDirectory: String, outputBaseName: String,
    products: [BookCatalogProduct] = [], remoteLinks: [BookCatalogRemoteLink] = []
  ) {
    schemaVersion = Self.schemaVersion
    self.id = id
    revision = 0
    self.createdAt = createdAt
    updatedAt = createdAt
    self.source = source
    self.metadata = metadata
    self.outputDirectory = outputDirectory
    self.outputBaseName = outputBaseName
    self.products = products
    self.remoteLinks = remoteLinks
  }

  package var layout: ManagedBookLayout {
    ManagedBookLayout(
      directory: URL(fileURLWithPath: outputDirectory), baseName: outputBaseName)
  }

  package func product(_ kind: BookProductKind) -> BookCatalogProduct? {
    products.first { $0.kind == kind }
  }

  package mutating func reconcile(_ product: BookCatalogProduct) throws {
    if let current = self.product(product.kind) {
      guard current.sha256 == product.sha256, current.path == product.path else {
        throw BookJobError.invalidRequest(
          "catalog already has a different \(product.kind.rawValue) product")
      }
      return
    }
    products.append(product)
    touch()
  }

  package mutating func upsertRemoteLink(_ link: BookCatalogRemoteLink) {
    remoteLinks.removeAll {
      $0.providerID == link.providerID && $0.connectionID == link.connectionID
    }
    remoteLinks.append(link)
    touch()
  }

  package mutating func touch() {
    revision += 1
    updatedAt = Date()
  }

  package func validate() throws {
    let remoteKeys = remoteLinks.map { "\($0.providerID):\($0.connectionID.uuidString)" }
    guard schemaVersion == Self.schemaVersion,
      source.format == "epub", source.size > 0,
      Self.validHash(source.sha256),
      (outputDirectory as NSString).isAbsolutePath,
      !outputBaseName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      Set(products.map(\.kind)).count == products.count,
      products.allSatisfy({
        $0.size > 0 && Self.validHash($0.sha256) && ($0.path as NSString).isAbsolutePath
      }),
      product(.sourceEPUB).map({ $0.size == source.size && $0.sha256 == source.sha256 }) ?? true,
      Set(remoteKeys).count == remoteKeys.count,
      remoteLinks.allSatisfy(Self.validRemoteLink)
    else { throw BookJobError.corruptState("invalid catalog record") }
  }

  private static func validHash(_ value: String) -> Bool {
    value.count == 64 && value == value.lowercased() && value.allSatisfy(\.isHexDigit)
  }

  private static func validRemoteLink(_ link: BookCatalogRemoteLink) -> Bool {
    let formats = Set(["ebook", "audiobook", "readaloud"])
    return !link.providerID.isEmpty && UUID(uuidString: link.remoteBookID) != nil
      && Set(link.receipts.map(\.format)).count == link.receipts.count
      && link.receipts.allSatisfy {
        formats.contains($0.format) && validHash($0.localSHA256)
          && ($0.remoteSHA256.map(validHash) ?? true)
          && ($0.remoteAssetID.map { UUID(uuidString: $0) != nil } ?? true)
          && ($0.remoteSize.map { $0 > 0 } ?? true)
      }
      && link.excludedRemoteBookIDs.allSatisfy { UUID(uuidString: $0) != nil }
  }
}

package struct ManagedBookLayout: Sendable, Equatable {
  package let directory: URL
  package let baseName: String

  package init(directory: URL, baseName: String) {
    self.directory = directory.standardizedFileURL
    self.baseName = baseName
  }

  package init(directory: URL, title: String, author: String?, collisionHash: String? = nil) {
    let suffix = author.flatMap { value -> String? in
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : " - \(trimmed)"
    } ?? ""
    var base = Self.sanitize("\(title)\(suffix)")
    if let collisionHash { base += " [\(collisionHash.prefix(8))]" }
    self.init(directory: directory, baseName: base)
  }

  package var sourceEPUB: URL { directory.appendingPathComponent("\(baseName) (E).epub") }
  package var audiobook: URL { directory.appendingPathComponent("\(baseName) (A).m4b") }
  package var readAloud: URL { directory.appendingPathComponent("\(baseName) (R).epub") }

  package static func sanitize(_ value: String) -> String {
    let forbidden = CharacterSet(charactersIn: "/:\\?%*|\"<>")
    var result = String(value.unicodeScalars.map { forbidden.contains($0) ? "-" : Character($0) })
    if result.count > 120 { result = String(result.prefix(120)) }
    result = result.trimmingCharacters(in: .whitespacesAndNewlines)
    return result.isEmpty ? "untitled" : result
  }

  package func stageSource(from source: URL, expectedSHA256: String) throws {
    let fileManager = FileManager.default
    try fileManager.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o755])
    if fileManager.fileExists(atPath: sourceEPUB.path) {
      guard try BookFileDigest.sha256(sourceEPUB) == expectedSHA256 else {
        throw BookJobError.invalidRequest(
          "Processed output already contains a different file named \(sourceEPUB.lastPathComponent)")
      }
      return
    }
    let temporary = directory.appendingPathComponent(".\(UUID().uuidString).epub")
    defer { try? fileManager.removeItem(at: temporary) }
    try fileManager.copyItem(at: source, to: temporary)
    guard try BookFileDigest.sha256(temporary) == expectedSHA256 else {
      throw BookJobError.io("the staged EPUB did not match the selected source")
    }
    if rename(temporary.path, sourceEPUB.path) != 0 {
      throw BookJobError.io(String(cString: strerror(errno)))
    }
  }
}

package actor BookCatalogStore {
  package struct ScanResult: Sendable {
    package var records: [BookCatalogRecord]
    package var issues: [String]
  }

  package let root: URL
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  package init(root: URL) {
    self.root = root
    encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .deferredToDate
    decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .deferredToDate
  }

  package func scan() throws -> ScanResult {
    try ensureRoot()
    var records: [BookCatalogRecord] = []
    var issues: [String] = []
    for url in try FileManager.default.contentsOfDirectory(
      at: root, includingPropertiesForKeys: [.isDirectoryKey])
    where (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
      guard let id = UUID(uuidString: url.lastPathComponent) else { continue }
      do { records.append(try loadUnlocked(id)) } catch {
        issues.append("\(url.lastPathComponent): \(error.localizedDescription)")
      }
    }
    records.sort { $0.updatedAt > $1.updatedAt }
    return ScanResult(records: records, issues: issues)
  }

  package func load(_ id: UUID) throws -> BookCatalogRecord { try loadUnlocked(id) }

  package func find(sourceSHA256: String) throws -> BookCatalogRecord? {
    let matches = try scan().records.filter { $0.source.sha256 == sourceSHA256 }
    guard matches.count <= 1 else {
      throw BookJobError.corruptState("duplicate catalog source identity")
    }
    return matches.first
  }

  package func create(_ record: BookCatalogRecord) throws {
    try record.validate()
    try ensureRoot()
    let lock = try BookFileLock(url: root.appendingPathComponent("catalog.lock"))
    defer { _fixLifetime(lock) }
    let existing = try scan().records
    guard !existing.contains(where: { $0.id == record.id }) else {
      throw BookJobError.invalidRequest("catalog record already exists")
    }
    guard !existing.contains(where: { $0.source.sha256 == record.source.sha256 }) else {
      throw BookJobError.invalidRequest("source EPUB is already cataloged")
    }
    let directory = recordDirectory(record.id)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    do {
      try AtomicBookFile.write(encoder.encode(record), to: directory.appendingPathComponent("record.json"))
    } catch {
      try? FileManager.default.removeItem(at: directory)
      throw error
    }
  }

  package func update(_ record: BookCatalogRecord, expectedRevision: UInt64? = nil) throws {
    try record.validate()
    let lock = try BookFileLock(url: root.appendingPathComponent("catalog.lock"))
    defer { _fixLifetime(lock) }
    let current = try loadUnlocked(record.id)
    if let expectedRevision, current.revision != expectedRevision {
      throw BookJobError.invalidRequest("catalog record changed concurrently")
    }
    guard record.revision == current.revision + 1,
      record.createdAt == current.createdAt, record.source == current.source,
      record.metadata == current.metadata, record.outputDirectory == current.outputDirectory,
      record.outputBaseName == current.outputBaseName, record.products == current.products
    else {
      throw BookJobError.invalidRequest(
        "catalog updates may change only remote links by one revision")
    }
    try AtomicBookFile.write(
      encoder.encode(record), to: recordDirectory(record.id).appendingPathComponent("record.json"))
  }

  package func reconcile(
    catalogID: UUID, product: BookCatalogProduct
  ) throws -> BookCatalogRecord {
    let lock = try BookFileLock(url: root.appendingPathComponent("catalog.lock"))
    defer { _fixLifetime(lock) }
    var record = try loadUnlocked(catalogID)
    try record.reconcile(product)
    try AtomicBookFile.write(
      encoder.encode(record), to: recordDirectory(catalogID).appendingPathComponent("record.json"))
    return record
  }

  package func recordDirectory(_ id: UUID) -> URL {
    root.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
  }

  private func loadUnlocked(_ id: UUID) throws -> BookCatalogRecord {
    do {
      let data = try Data(contentsOf: recordDirectory(id).appendingPathComponent("record.json"))
      let value = try decoder.decode(BookCatalogRecord.self, from: data)
      guard value.id == id else { throw BookJobError.corruptState("catalog ID mismatch") }
      try value.validate()
      return value
    } catch let error as BookJobError { throw error } catch {
      throw BookJobError.corruptState(error.localizedDescription)
    }
  }

  private func ensureRoot() throws {
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
  }
}

package enum BookFileDigest {
  package static func sha256(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hash = SHA256()
    while let data = try handle.read(upToCount: 4 << 20), !data.isEmpty { hash.update(data: data) }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }

  package static func size(_ url: URL) throws -> UInt64 {
    UInt64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
  }
}

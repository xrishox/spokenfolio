import CryptoKit
import Darwin
import Foundation
import LibraryKit
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
      revision < UInt64(Int64.max),
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

  /// One folder per book under `root`, named by the book, holding
  /// self-identifying files: `<Base>.epub`, `<Base> - TTS Audiobook.m4b`,
  /// `<Base> - TTS ReadAloud.epub`. `directory` IS the per-book folder.
  package init(directory root: URL, title: String, author: String?, collisionHash: String? = nil) {
    let suffix = author.flatMap { value -> String? in
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : " - \(trimmed)"
    } ?? ""
    var base = Self.sanitize("\(title)\(suffix)")
    if let collisionHash { base += " [\(collisionHash.prefix(8))]" }
    self.init(directory: root.appendingPathComponent(base, isDirectory: true), baseName: base)
  }

  package var sourceEPUB: URL { directory.appendingPathComponent("\(baseName).epub") }
  package var audiobook: URL {
    directory.appendingPathComponent("\(baseName) - TTS Audiobook.m4b")
  }
  package var readAloud: URL {
    directory.appendingPathComponent("\(baseName) - TTS ReadAloud.epub")
  }
  /// Human-narrated downloads keep the server file's own extension (m4b,
  /// m4a, mp3, zip…) because Storyteller serves whatever was uploaded.
  package func humanAudiobook(extension ext: String) -> URL {
    directory.appendingPathComponent("\(baseName) - Human Audiobook.\(ext)")
  }
  package var humanReadAloud: URL {
    directory.appendingPathComponent("\(baseName) - Human ReadAloud.epub")
  }

  package static func sanitize(_ value: String) -> String {
    let forbidden = CharacterSet(charactersIn: "/:\\?%*|\"<>")
    var result = String(value.unicodeScalars.map { forbidden.contains($0) ? "-" : Character($0) })
    result = result.trimmingCharacters(in: .whitespacesAndNewlines)
    if result.utf8.count > 120 {
      var bounded = ""
      for character in result {
        guard bounded.utf8.count + String(character).utf8.count <= 120 else { break }
        bounded.append(character)
      }
      result = bounded.trimmingCharacters(in: .whitespacesAndNewlines)
    }
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
  package let databaseURL: URL
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder
  private var libraryStore: LibraryStore?

  package init(root: URL, databaseURL: URL? = nil) {
    self.root = root.standardizedFileURL
    self.databaseURL = (databaseURL
      ?? root.deletingLastPathComponent().appendingPathComponent("library.sqlite"))
      .standardizedFileURL
    encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .deferredToDate
    decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .deferredToDate
  }

  package func scan() throws -> ScanResult {
    do {
      let result = try store().scanEditions()
      return ScanResult(
        records: try result.editions.map(Self.catalogRecord), issues: result.issues)
    } catch { throw Self.bookError(error) }
  }

  package func load(_ id: UUID) throws -> BookCatalogRecord {
    do { return try Self.catalogRecord(store().edition(id)) }
    catch { throw Self.bookError(error) }
  }

  package func find(sourceSHA256: String) throws -> BookCatalogRecord? {
    do { return try store().findEdition(sourceSHA256: sourceSHA256).map(Self.catalogRecord) }
    catch { throw Self.bookError(error) }
  }

  package func create(_ record: BookCatalogRecord) throws {
    try record.validate()
    do {
      let value = try Self.libraryEdition(record, encoder: encoder)
      try ensurePlaceholderConnections(for: value.remoteLinks)
      try store().createEdition(value)
    } catch { throw Self.bookError(error) }
  }

  package func update(_ record: BookCatalogRecord, expectedRevision: UInt64? = nil) throws {
    try record.validate()
    let current = try load(record.id)
    if let expectedRevision, current.revision != expectedRevision {
      throw BookJobError.invalidRequest("catalog record changed concurrently")
    }
    var changed: [String] = []
    if record.revision != current.revision + 1 { changed.append("revision") }
    if abs(record.createdAt.timeIntervalSince(current.createdAt)) > 0.000_001 {
      changed.append("createdAt")
    }
    if record.source != current.source { changed.append("source") }
    if record.metadata != current.metadata { changed.append("metadata") }
    if record.outputDirectory != current.outputDirectory { changed.append("outputDirectory") }
    if record.outputBaseName != current.outputBaseName { changed.append("outputBaseName") }
    if !Self.sameProducts(record.products, current.products) { changed.append("products") }
    guard changed.isEmpty else {
      throw BookJobError.invalidRequest(
        "catalog updates may change only remote links by one revision; changed: \(changed.joined(separator: ", "))")
    }
    do {
      let links = try Self.libraryLinks(record.remoteLinks)
      try ensurePlaceholderConnections(for: links)
      _ = try store().replaceRemoteLinks(
        editionID: record.id, links: links, expectedRevision: current.revision)
    } catch { throw Self.bookError(error) }
  }

  package func reconcile(
    catalogID: UUID, product: BookCatalogProduct,
    sourceSHA256: String? = nil, alignmentAudioSHA256: String? = nil
  ) throws -> BookCatalogRecord {
    do {
      let value = try Self.libraryProduct(product, encoder: encoder)
      var dependencies: [LibraryProductDependency] = []
      if let sourceSHA256 {
        dependencies.append(
          .init(productID: value.id, role: .source, inputSHA256: sourceSHA256))
      }
      if let alignmentAudioSHA256 {
        dependencies.append(
          .init(
            productID: value.id, role: .alignmentAudio,
            inputSHA256: alignmentAudioSHA256))
      }
      let edition = try store().reconcileProduct(
        editionID: catalogID, product: value, dependencies: dependencies)
      return try Self.catalogRecord(edition)
    } catch { throw Self.bookError(error) }
  }

  package func replace(
    catalogID: UUID, product: BookCatalogProduct, expectedCurrentSHA256: String,
    sourceSHA256: String? = nil, alignmentAudioSHA256: String? = nil
  ) throws -> BookCatalogRecord {
    do {
      let value = try Self.libraryProduct(product, encoder: encoder)
      var dependencies: [LibraryProductDependency] = []
      if let sourceSHA256 {
        dependencies.append(.init(productID: value.id, role: .source, inputSHA256: sourceSHA256))
      }
      if let alignmentAudioSHA256 {
        dependencies.append(
          .init(productID: value.id, role: .alignmentAudio, inputSHA256: alignmentAudioSHA256))
      }
      return try Self.catalogRecord(
        store().replaceProduct(
          editionID: catalogID, product: value,
          expectedCurrentSHA256: expectedCurrentSHA256, dependencies: dependencies))
    } catch { throw Self.bookError(error) }
  }

  package func recordDirectory(_ id: UUID) -> URL {
    root.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
  }

  private func store() throws -> LibraryStore {
    if let libraryStore { return libraryStore }
    if !FileManager.default.fileExists(atPath: databaseURL.path) {
      try migrateLegacyCatalogIfNeeded()
    }
    do {
      let value = try LibraryStore(databaseURL: databaseURL)
      libraryStore = value
      return value
    } catch { throw Self.bookError(error) }
  }

  /// Creates and validates a complete temporary database before publishing it.
  /// Legacy JSON is retained as a read-only recovery input and is never written again.
  private func migrateLegacyCatalogIfNeeded() throws {
    let parent = databaseURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: parent, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let lock = try BookFileLock(
      url: parent.appendingPathComponent("library-migration.lock"))
    defer { _fixLifetime(lock) }
    if FileManager.default.fileExists(atPath: databaseURL.path) { return }
    let records = try legacyRecords()
    let temporary = parent.appendingPathComponent(
      ".\(databaseURL.lastPathComponent).migrating-\(UUID().uuidString)")
    defer {
      try? FileManager.default.removeItem(at: temporary)
      try? FileManager.default.removeItem(atPath: temporary.path + "-wal")
      try? FileManager.default.removeItem(atPath: temporary.path + "-shm")
    }
    do {
      let target = try LibraryStore(databaseURL: temporary)
      let links = try records.flatMap { try Self.libraryLinks($0.remoteLinks) }
      for connectionID in Set(links.map(\.connectionID)) {
        try target.saveConnection(Self.placeholderConnection(connectionID))
      }
      for record in records {
        try target.createEdition(
          try Self.libraryEdition(record, encoder: encoder), auditKind: "edition.migrated")
      }
      try target.validate()
      try target.checkpointForMigration()
      try target.database.pool.close()
      guard !FileManager.default.fileExists(atPath: databaseURL.path) else {
        throw BookJobError.invalidRequest("library database appeared during migration")
      }
      if rename(temporary.path, databaseURL.path) != 0 {
        throw BookJobError.io(String(cString: strerror(errno)))
      }
    } catch let error as BookJobError { throw error } catch {
      throw BookJobError.corruptState("library migration failed: \(error.localizedDescription)")
    }
  }

  private func legacyRecords() throws -> [BookCatalogRecord] {
    guard FileManager.default.fileExists(atPath: root.path) else { return [] }
    var records: [BookCatalogRecord] = []
    var issues: [String] = []
    for url in try FileManager.default.contentsOfDirectory(
      at: root, includingPropertiesForKeys: [.isDirectoryKey])
    where (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
      guard let id = UUID(uuidString: url.lastPathComponent) else { continue }
      do {
        let recordURL = url.appendingPathComponent("record.json")
        let values = try recordURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size <= 8 << 20 else {
          throw BookJobError.corruptState("legacy catalog record is not bounded")
        }
        let value = try decoder.decode(
          BookCatalogRecord.self,
          from: Data(contentsOf: recordURL, options: [.mappedIfSafe]))
        guard value.id == id else { throw BookJobError.corruptState("catalog ID mismatch") }
        try value.validate()
        records.append(value)
      } catch { issues.append("\(url.lastPathComponent): \(error.localizedDescription)") }
    }
    guard issues.isEmpty else {
      throw BookJobError.corruptState(
        "legacy catalog migration stopped; repair or remove corrupt records: \(issues.joined(separator: "; "))")
    }
    return records
  }

  private func ensurePlaceholderConnections(for links: [LibraryRemoteLink]) throws {
    let existing = Set(try store().connections().map(\.id))
    for id in Set(links.map(\.connectionID)).subtracting(existing) {
      try store().saveConnection(Self.placeholderConnection(id))
    }
  }

  private static func placeholderConnection(_ id: UUID) -> LibraryConnection {
    let now = Date()
    return LibraryConnection(
      id: id, origin: URL(string: "http://legacy.invalid")!,
      displayName: "Migrated Storyteller connection", username: nil,
      connectedAt: now, disconnectedAt: now)
  }

  private static func libraryEdition(
    _ record: BookCatalogRecord, encoder: JSONEncoder
  ) throws -> LibraryEdition {
    let sourceProduct = record.product(.sourceEPUB)
    return LibraryEdition(
      id: record.id, workID: record.id, revision: record.revision,
      createdAt: record.createdAt, updatedAt: record.updatedAt,
      metadata: .init(
        title: record.metadata.title, author: record.metadata.author,
        language: record.metadata.language, publisher: record.metadata.publisher,
        publicationDate: record.metadata.publicationDate,
        identifiers: record.metadata.identifiers),
      outputDirectory: record.outputDirectory, outputBaseName: record.outputBaseName,
      source: .init(
        format: record.source.format,
        path: sourceProduct?.path ?? record.layout.sourceEPUB.path,
        importerVersion: record.source.importerVersion, sha256: record.source.sha256,
        size: record.source.size, verifiedAt: sourceProduct?.verifiedAt ?? record.updatedAt),
      products: try record.products.map { try libraryProduct($0, encoder: encoder) },
      remoteLinks: try libraryLinks(record.remoteLinks))
  }

  private static func libraryProduct(
    _ product: BookCatalogProduct, encoder: JSONEncoder
  ) throws -> LibraryLocalProduct {
    LibraryLocalProduct(
      kind: LibraryProductKind(rawValue: product.kind.rawValue)!, path: product.path,
      size: product.size, sha256: product.sha256, verifiedAt: product.verifiedAt,
      producerJobID: product.producerJobID,
      narrationData: try product.narration.map(encoder.encode),
      readAloudData: try product.readAloud.map(encoder.encode))
  }

  private static func libraryLinks(_ links: [BookCatalogRemoteLink]) throws
    -> [LibraryRemoteLink]
  {
    try links.map { link in
      guard let remoteID = UUID(uuidString: link.remoteBookID),
        let evidence = LibraryLinkEvidence(rawValue: link.evidence.rawValue)
      else { throw BookJobError.corruptState("invalid remote catalog link") }
      return LibraryRemoteLink(
        providerID: link.providerID, connectionID: link.connectionID,
        remoteBookID: remoteID, evidence: evidence, linkedAt: link.linkedAt,
        lastObservedAt: link.lastObservedAt, remoteTitle: link.remoteTitle,
        remoteAuthors: link.remoteAuthors,
        receipts: try link.receipts.map { receipt in
          guard let format = LibraryRemoteFormat(rawValue: receipt.format) else {
            throw BookJobError.corruptState("invalid remote receipt format")
          }
          return LibraryRemoteReceipt(
            format: format, localSHA256: receipt.localSHA256,
            remoteAssetID: receipt.remoteAssetID.flatMap(UUID.init(uuidString:)),
            remoteSize: receipt.remoteSize, remoteFingerprint: receipt.remoteFingerprint,
            remoteSHA256: receipt.remoteSHA256, observedAt: receipt.observedAt)
        },
        excludedRemoteBookIDs: link.excludedRemoteBookIDs.compactMap(UUID.init(uuidString:)))
    }
  }

  private static func catalogRecord(_ edition: LibraryEdition) throws -> BookCatalogRecord {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .deferredToDate
    var value = BookCatalogRecord(
      id: edition.id, createdAt: edition.createdAt,
      source: .init(
        format: edition.source.format, importerVersion: edition.source.importerVersion,
        sha256: edition.source.sha256, size: edition.source.size),
      metadata: .init(
        title: edition.metadata.title, author: edition.metadata.author,
        language: edition.metadata.language, publisher: edition.metadata.publisher,
        publicationDate: edition.metadata.publicationDate,
        identifiers: edition.metadata.identifiers),
      outputDirectory: edition.outputDirectory, outputBaseName: edition.outputBaseName,
      products: try edition.products.map { product in
        BookCatalogProduct(
          kind: BookProductKind(rawValue: product.kind.rawValue)!, path: product.path,
          size: product.size, sha256: product.sha256, verifiedAt: product.verifiedAt,
          producerJobID: product.producerJobID,
          narration: try product.narrationData.map {
            try decoder.decode(BookJobRequest.Narration.self, from: $0)
          },
          readAloud: try product.readAloudData.map {
            try decoder.decode(BookJobRequest.ReadAloud.self, from: $0)
          })
      },
      remoteLinks: edition.remoteLinks.map { link in
        BookCatalogRemoteLink(
          providerID: link.providerID, connectionID: link.connectionID,
          remoteBookID: link.remoteBookID.uuidString.lowercased(),
          evidence: .init(rawValue: link.evidence.rawValue)!, linkedAt: link.linkedAt,
          lastObservedAt: link.lastObservedAt, remoteTitle: link.remoteTitle,
          remoteAuthors: link.remoteAuthors,
          receipts: link.receipts.map {
            BookCatalogRemoteReceipt(
              format: $0.format.rawValue, localSHA256: $0.localSHA256,
              remoteAssetID: $0.remoteAssetID?.uuidString.lowercased(),
              remoteSize: $0.remoteSize, remoteFingerprint: $0.remoteFingerprint,
              remoteSHA256: $0.remoteSHA256, observedAt: $0.observedAt)
          },
          excludedRemoteBookIDs: link.excludedRemoteBookIDs.map { $0.uuidString.lowercased() })
      })
    value.revision = edition.revision
    value.updatedAt = edition.updatedAt
    try value.validate()
    return value
  }

  private static func bookError(_ error: Error) -> BookJobError {
    if let error = error as? BookJobError { return error }
    if let error = error as? LibraryStoreError {
      switch error {
      case .conflict, .notFound: return .invalidRequest(error.localizedDescription)
      case .corruptDatabase, .invalidRecord, .migrationFailed:
        return .corruptState(error.localizedDescription)
      }
    }
    return .io(error.localizedDescription)
  }

  private static func sameProducts(
    _ left: [BookCatalogProduct], _ right: [BookCatalogProduct]
  ) -> Bool {
    guard left.count == right.count else { return false }
    let leftByKind = Dictionary(uniqueKeysWithValues: left.map { ($0.kind.rawValue, $0) })
    let rightByKind = Dictionary(uniqueKeysWithValues: right.map { ($0.kind.rawValue, $0) })
    guard Set(leftByKind.keys) == Set(rightByKind.keys) else { return false }
    return leftByKind.allSatisfy { key, value in
      guard let other = rightByKind[key] else { return false }
      return value.kind == other.kind && value.path == other.path && value.size == other.size
        && value.sha256 == other.sha256 && value.producerJobID == other.producerJobID
        && value.narration == other.narration && value.readAloud == other.readAloud
        && abs(value.verifiedAt.timeIntervalSince(other.verifiedAt)) < 0.000_001
    }
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

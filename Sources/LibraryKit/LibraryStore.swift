import Foundation
import GRDB
import PublicationKit

/// The durable authority for the local publication inventory and observed remote state.
/// All multi-row mutations are transactions; callers never have to assemble partially
/// consistent editions, products, links, or synchronization generations.
package final class LibraryStore: @unchecked Sendable {
  package struct ScanResult: Sendable {
    package var editions: [LibraryEdition]
    package var issues: [String]

    package init(editions: [LibraryEdition], issues: [String] = []) {
      self.editions = editions
      self.issues = issues
    }
  }

  package let database: LibraryDatabase
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  package init(databaseURL: URL) throws {
    database = try LibraryDatabase(url: databaseURL)
    encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .deferredToDate
    decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .deferredToDate
  }

  package func validate() throws { try database.validate() }

  /// Rewrites only application-owned absolute path columns during a product
  /// support-directory move. Remote file paths and opaque evidence remain
  /// untouched because they belong to their respective providers.
  package func rewriteOwnedPathPrefix(from oldPrefix: String, to newPrefix: String) throws {
    guard !oldPrefix.isEmpty, !newPrefix.isEmpty, oldPrefix != newPrefix,
      (oldPrefix as NSString).isAbsolutePath, (newPrefix as NSString).isAbsolutePath
    else { throw LibraryStoreError.invalidRecord("invalid path migration prefix") }
    let columns = [
      ("library_edition", "output_directory"),
      ("source_artifact", "path"),
      ("local_product", "path"),
      ("readaloud_audit_run", "standalone_path"),
    ]
    try database.pool.write { db in
      for (table, column) in columns {
        try db.execute(
          sql: """
            UPDATE \(table)
            SET \(column) = ? || substr(\(column), ?)
            WHERE \(column) = ?
               OR (substr(\(column), 1, ?) = ? AND substr(\(column), ?, 1) = '/')
            """,
          arguments: [
            newPrefix, oldPrefix.count + 1, oldPrefix,
            oldPrefix.count, oldPrefix, oldPrefix.count + 1,
          ])
      }
    }
  }

  package func scanEditions() throws -> ScanResult {
    try database.pool.read { db in
      let ids = try String.fetchAll(
        db, sql: "SELECT id FROM library_edition ORDER BY updated_at DESC")
      var values: [LibraryEdition] = []
      var issues: [String] = []
      for value in ids {
        do {
          guard let id = UUID(uuidString: value) else {
            throw LibraryStoreError.invalidRecord("invalid edition ID \(value)")
          }
          values.append(try loadEdition(id, db: db))
        } catch {
          issues.append("\(value): \(error.localizedDescription)")
        }
      }
      return ScanResult(editions: values, issues: issues)
    }
  }

  package func edition(_ id: UUID) throws -> LibraryEdition {
    try database.pool.read { try loadEdition(id, db: $0) }
  }

  package func findEdition(sourceSHA256: String) throws -> LibraryEdition? {
    try database.pool.read { db in
      let values = try String.fetchAll(
        db, sql: "SELECT edition_id FROM source_artifact WHERE sha256 = ?",
        arguments: [sourceSHA256])
      guard values.count <= 1 else {
        throw LibraryStoreError.corruptDatabase("duplicate source EPUB identity")
      }
      guard let value = values.first, let id = UUID(uuidString: value) else { return nil }
      return try loadEdition(id, db: db)
    }
  }

  package func createEdition(_ edition: LibraryEdition, auditKind: String = "edition.created")
    throws
  {
    try validateEdition(edition)
    try database.pool.write { db in
      guard
        try Int.fetchOne(
          db, sql: "SELECT COUNT(*) FROM library_edition WHERE id = ?", arguments: [key(edition.id)]
        ) == 0
      else { throw LibraryStoreError.conflict("edition already exists") }
      guard
        try Int.fetchOne(
          db, sql: "SELECT COUNT(*) FROM source_artifact WHERE sha256 = ?",
          arguments: [edition.source.sha256]) == 0
      else { throw LibraryStoreError.conflict("source EPUB is already cataloged") }
      try insertEdition(edition, db: db)
      try insertAudit(
        .init(kind: auditKind, editionID: edition.id), db: db)
    }
  }

  /// Adds a primary local product. Replaying the same path and digest is idempotent;
  /// replacement requires the separate digest-guarded operation below.
  package func reconcileProduct(
    editionID: UUID, product: LibraryLocalProduct,
    dependencies: [LibraryProductDependency] = []
  ) throws -> LibraryEdition {
    try validateProduct(product)
    let dependencyKeys = dependencies.map { "\($0.productID.uuidString):\($0.role.rawValue)" }
    guard Set(dependencyKeys).count == dependencyKeys.count,
      dependencies.allSatisfy({
        $0.productID == product.id && validHash($0.inputSHA256)
      })
    else { throw LibraryStoreError.invalidRecord("invalid product dependencies") }
    return try database.pool.write { db in
      let current = try loadEdition(editionID, db: db)
      if let existing = current.products.first(where: { $0.kind == product.kind }) {
        guard existing.path == product.path, existing.sha256 == product.sha256 else {
          throw LibraryStoreError.conflict(
            "edition already has a different \(product.kind.rawValue) product")
        }
        return current
      }
      try insertProduct(product, editionID: editionID, db: db)
      for dependency in dependencies where dependency.productID == product.id {
        try db.execute(
          sql: "INSERT INTO product_dependency(product_id, role, input_sha256) VALUES (?, ?, ?)",
          arguments: [key(product.id), dependency.role.rawValue, dependency.inputSHA256])
      }
      try db.execute(
        sql: "INSERT INTO primary_product(edition_id, kind, product_id) VALUES (?, ?, ?)",
        arguments: [key(editionID), product.kind.rawValue, key(product.id)])
      try touchEdition(editionID, expectedRevision: current.revision, db: db)
      try insertAudit(
        .init(
          kind: "product.reconciled", editionID: editionID,
          detailData: try json(["kind": product.kind.rawValue, "sha256": product.sha256])), db: db)
      return try loadEdition(editionID, db: db)
    }
  }

  /// Explicitly supersedes one primary product after checking the digest that
  /// the production request observed. The digest guard prevents a long-running
  /// reprocess job from replacing a newer product published concurrently.
  package func replaceProduct(
    editionID: UUID, product: LibraryLocalProduct, expectedCurrentSHA256: String,
    dependencies: [LibraryProductDependency] = []
  ) throws -> LibraryEdition {
    try validateProduct(product)
    guard validHash(expectedCurrentSHA256),
      dependencies.allSatisfy({
        $0.productID == product.id && validHash($0.inputSHA256)
      }), Set(dependencies.map(\.role)).count == dependencies.count
    else { throw LibraryStoreError.invalidRecord("invalid product replacement") }
    return try database.pool.write { db in
      let current = try loadEdition(editionID, db: db)
      guard let existing = current.products.first(where: { $0.kind == product.kind }) else {
        throw LibraryStoreError.conflict("replacement product no longer exists")
      }
      guard existing.sha256 == expectedCurrentSHA256 else {
        throw LibraryStoreError.conflict("replacement product changed concurrently")
      }

      let storedID: UUID
      if existing.sha256 == product.sha256 {
        storedID = existing.id
        try db.execute(
          sql: """
            UPDATE local_product SET path = ?, size = ?, verified_at = ?, state = ?,
              producer_job_id = ?, narration_json = ?, readaloud_json = ?
            WHERE id = ?
            """,
          arguments: [
            product.path, signed(product.size), time(product.verifiedAt), product.state.rawValue,
            product.producerJobID.map(key), product.narrationData, product.readAloudData,
            key(existing.id),
          ])
        try db.execute(
          sql: "DELETE FROM product_dependency WHERE product_id = ?",
          arguments: [key(existing.id)])
      } else {
        storedID = product.id
        try insertProduct(product, editionID: editionID, db: db)
        try db.execute(
          sql: "UPDATE primary_product SET product_id = ? WHERE edition_id = ? AND kind = ?",
          arguments: [key(product.id), key(editionID), product.kind.rawValue])
        try db.execute(sql: "DELETE FROM local_product WHERE id = ?", arguments: [key(existing.id)])
      }
      for dependency in dependencies {
        try db.execute(
          sql: "INSERT INTO product_dependency(product_id, role, input_sha256) VALUES (?, ?, ?)",
          arguments: [key(storedID), dependency.role.rawValue, dependency.inputSHA256])
      }
      let remoteFormat: String? = switch product.kind {
      case .sourceEPUB: nil
      case .m4b: LibraryRemoteFormat.audiobook.rawValue
      case .readAloudEPUB: LibraryRemoteFormat.readaloud.rawValue
      }
      if let remoteFormat, existing.sha256 != product.sha256 {
        try db.execute(
          sql: """
            DELETE FROM delivery_receipt
            WHERE format = ? AND local_sha256 = ? AND link_id IN (
              SELECT id FROM edition_remote_link WHERE edition_id = ?
            )
            """,
          arguments: [remoteFormat, existing.sha256, key(editionID)])
      }
      try touchEdition(editionID, expectedRevision: current.revision, db: db)
      try insertAudit(
        .init(
          kind: "product.replaced", editionID: editionID,
          detailData: try json([
            "kind": product.kind.rawValue, "oldSHA256": existing.sha256,
            "newSHA256": product.sha256,
          ])), db: db)
      return try loadEdition(editionID, db: db)
    }
  }

  /// Replaces the link set using optimistic edition revision checking and enforces
  /// one active local edition per remote book in the selected connection.
  package func replaceRemoteLinks(
    editionID: UUID, links: [LibraryRemoteLink], expectedRevision: UInt64
  ) throws -> LibraryEdition {
    try validateLinks(links)
    return try database.pool.write { db in
      let current = try loadEdition(editionID, db: db)
      guard current.revision == expectedRevision else {
        throw LibraryStoreError.conflict("edition changed concurrently")
      }
      try db.execute(
        sql: "DELETE FROM edition_remote_link WHERE edition_id = ?", arguments: [key(editionID)])
      for link in links { try insertLink(link, editionID: editionID, db: db) }
      try touchEdition(editionID, expectedRevision: expectedRevision, db: db)
      try insertAudit(.init(kind: "links.replaced", editionID: editionID), db: db)
      return try loadEdition(editionID, db: db)
    }
  }

  package func saveConnection(_ connection: LibraryConnection) throws {
    try validateConnection(connection)
    try database.pool.write { db in
      try db.execute(
        sql: """
          INSERT INTO remote_connection(
            id, provider_id, origin, display_name, username, remote_user_id,
            permissions_json, connected_at, disconnected_at
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(id) DO UPDATE SET
            provider_id=excluded.provider_id, origin=excluded.origin,
            display_name=excluded.display_name, username=excluded.username,
            remote_user_id=excluded.remote_user_id, permissions_json=excluded.permissions_json,
            connected_at=excluded.connected_at, disconnected_at=excluded.disconnected_at
          """,
        arguments: [
          key(connection.id), connection.providerID, connection.origin.absoluteString,
          connection.displayName, connection.username, connection.remoteUserID.map(key),
          connection.permissionsData, time(connection.connectedAt),
          connection.disconnectedAt.map(time),
        ])
      try insertAudit(.init(kind: "connection.saved", connectionID: connection.id), db: db)
    }
  }

  package func connections(includeDisconnected: Bool = false) throws -> [LibraryConnection] {
    try database.pool.read { db in
      let condition = includeDisconnected ? "" : " WHERE disconnected_at IS NULL"
      return try Row.fetchAll(
        db, sql: "SELECT * FROM remote_connection\(condition) ORDER BY connected_at DESC"
      )
      .map(decodeConnection)
    }
  }

  package func disconnectConnection(_ id: UUID, at date: Date = Date()) throws {
    try database.pool.write { db in
      try db.execute(
        sql:
          "UPDATE remote_connection SET disconnected_at = ? WHERE id = ? AND disconnected_at IS NULL",
        arguments: [time(date), key(id)])
      guard db.changesCount == 1 else {
        throw LibraryStoreError.notFound("active remote connection")
      }
      try insertAudit(.init(kind: "connection.disconnected", connectionID: id), db: db)
    }
  }

  /// Records the obligation to audit a remotely processed ReadAloud. Repeated
  /// starts for the same book reuse the active intent instead of creating
  /// duplicate polling and audit work.
  package func beginRemoteReadAloudAutoAudit(
    connectionID: UUID, bookID: UUID, at date: Date = Date()
  ) throws -> LibraryRemoteReadAloudAutoAudit {
    try database.pool.write { db in
      guard
        try Int.fetchOne(
          db, sql: "SELECT COUNT(*) FROM remote_connection WHERE id = ?",
          arguments: [key(connectionID)]) == 1
      else { throw LibraryStoreError.notFound("remote connection") }
      if let row = try Row.fetchOne(
        db,
        sql: """
          SELECT * FROM remote_operation
          WHERE connection_id = ? AND remote_book_id = ?
            AND kind = 'readaloud-quality-after-processing'
            AND status IN ('starting', 'waiting')
          ORDER BY started_at DESC LIMIT 1
          """,
        arguments: [key(connectionID), key(bookID)])
      {
        return try decodeRemoteReadAloudAutoAudit(row)
      }
      let value = LibraryRemoteReadAloudAutoAudit(
        connectionID: connectionID, bookID: bookID, startedAt: date, updatedAt: date)
      try db.execute(
        sql: """
          INSERT INTO remote_operation(
            id, connection_id, remote_book_id, kind, status,
            started_at, updated_at
          ) VALUES (?, ?, ?, 'readaloud-quality-after-processing', ?, ?, ?)
          """,
        arguments: [
          key(value.id), key(connectionID), key(bookID), value.status.rawValue,
          time(date), time(date),
        ])
      try insertAudit(
        .init(
          kind: "readaloud.auto-audit.started", connectionID: connectionID,
          remoteBookID: bookID), db: db)
      guard let stored = try Row.fetchOne(
        db, sql: "SELECT * FROM remote_operation WHERE id = ?", arguments: [key(value.id)])
      else { throw LibraryStoreError.corruptDatabase("remote quality intent was not stored") }
      return try decodeRemoteReadAloudAutoAudit(stored)
    }
  }

  package func pendingRemoteReadAloudAutoAudits() throws
    -> [LibraryRemoteReadAloudAutoAudit]
  {
    try database.pool.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT * FROM remote_operation
          WHERE kind = 'readaloud-quality-after-processing'
            AND status IN ('starting', 'waiting')
          ORDER BY started_at, id
          """
      ).map(decodeRemoteReadAloudAutoAudit)
    }
  }

  package func markRemoteReadAloudAutoAuditWaiting(
    _ id: UUID, at date: Date = Date()
  ) throws {
    try updateRemoteReadAloudAutoAudit(id, status: .waiting, error: nil, at: date)
  }

  package func completeRemoteReadAloudAutoAudit(_ id: UUID, at date: Date = Date()) throws {
    try updateRemoteReadAloudAutoAudit(id, status: .completed, error: nil, at: date)
  }

  package func failRemoteReadAloudAutoAudit(
    _ id: UUID, message: String, at date: Date = Date()
  ) throws {
    try updateRemoteReadAloudAutoAudit(
      id, status: .failed, error: String(message.prefix(4_096)), at: date)
  }

  private func updateRemoteReadAloudAutoAudit(
    _ id: UUID, status: LibraryRemoteReadAloudAutoAuditStatus, error: String?, at date: Date
  ) throws {
    try database.pool.write { db in
      try db.execute(
        sql: """
          UPDATE remote_operation SET status = ?, updated_at = ?, error = ?
          WHERE id = ? AND kind = 'readaloud-quality-after-processing'
            AND status IN ('starting', 'waiting')
          """,
        arguments: [status.rawValue, time(date), error, key(id)])
      guard db.changesCount == 1 else {
        throw LibraryStoreError.notFound("active remote ReadAloud quality intent")
      }
    }
  }

  private func decodeRemoteReadAloudAutoAudit(_ row: Row) throws
    -> LibraryRemoteReadAloudAutoAudit
  {
    guard let id = uuid(row["id"] as String),
      let connectionID = uuid(row["connection_id"] as String),
      let bookID = uuid(row["remote_book_id"] as String),
      let status = LibraryRemoteReadAloudAutoAuditStatus(rawValue: row["status"] as String)
    else { throw LibraryStoreError.invalidRecord("invalid remote ReadAloud quality intent") }
    return .init(
      id: id, connectionID: connectionID, bookID: bookID, status: status,
      startedAt: date(row["started_at"]), updatedAt: date(row["updated_at"]),
      error: row["error"])
  }

  /// Publishes a complete remote inventory generation atomically. A failed fetch must
  /// never call this method, so absence is meaningful only after a successful full list.
  package func replaceRemoteInventory(
    connectionID: UUID, books: [LibraryRemoteBookSnapshot], observedAt: Date = Date()
  ) throws -> LibrarySyncResult {
    try database.pool.write { db in
      guard
        try Int.fetchOne(
          db, sql: "SELECT COUNT(*) FROM remote_connection WHERE id = ?",
          arguments: [key(connectionID)]) == 1
      else { throw LibraryStoreError.notFound("remote connection") }
      let prior =
        try UInt64.fetchOne(
          db,
          sql:
            "SELECT MAX(generation) FROM sync_run WHERE connection_id = ? AND status = 'completed'",
          arguments: [key(connectionID)]) ?? 0
      let (generation, overflow) = prior.addingReportingOverflow(1)
      guard !overflow, generation <= UInt64(Int64.max) else {
        throw LibraryStoreError.corruptDatabase("sync generation exhausted")
      }
      let runID = UUID()
      try db.execute(
        sql:
          "INSERT INTO sync_run(id, connection_id, generation, started_at, status) VALUES (?, ?, ?, ?, 'running')",
        arguments: [key(runID), key(connectionID), generation, time(observedAt)])
      var seen = Set<UUID>()
      for var book in books {
        guard book.connectionID == connectionID, seen.insert(book.remoteBookID).inserted else {
          throw LibraryStoreError.invalidRecord(
            "remote inventory has a wrong or duplicate book identity")
        }
        try validateRemoteBook(book)
        book.generation = generation
        book.observedAt = observedAt
        book.missingAt = nil
        try upsertRemoteBook(book, db: db)
      }
      if seen.isEmpty {
        try db.execute(
          sql:
            "UPDATE remote_book SET missing_at = ?, generation = ? WHERE connection_id = ? AND missing_at IS NULL",
          arguments: [time(observedAt), generation, key(connectionID)])
      } else {
        let placeholders = Array(repeating: "?", count: seen.count).joined(separator: ",")
        var arguments: StatementArguments = [time(observedAt), generation, key(connectionID)]
        for id in seen { arguments += [key(id)] }
        try db.execute(
          sql:
            "UPDATE remote_book SET missing_at = ?, generation = ? WHERE connection_id = ? AND remote_book_id NOT IN (\(placeholders)) AND missing_at IS NULL",
          arguments: arguments)
      }
      try db.execute(
        sql: "UPDATE sync_run SET completed_at = ?, status = 'completed' WHERE id = ?",
        arguments: [time(observedAt), key(runID)])
      try insertAudit(
        .init(
          kind: "remote.sync.completed", connectionID: connectionID,
          detailData: try json(["generation": String(generation), "books": String(books.count)])),
        db: db)
      return LibrarySyncResult(
        generation: generation, observedAt: observedAt, bookCount: books.count)
    }
  }

  package func remoteBooks(connectionID: UUID, includeMissing: Bool = true) throws
    -> [LibraryRemoteBookSnapshot]
  {
    try database.pool.read { db in
      let clause = includeMissing ? "" : " AND missing_at IS NULL"
      return try Row.fetchAll(
        db,
        sql:
          "SELECT * FROM remote_book WHERE connection_id = ?\(clause) ORDER BY title COLLATE NOCASE",
        arguments: [key(connectionID)]
      ).map { try decodeRemoteBook($0, db: db) }
    }
  }

  package func auditEvents(limit: Int = 500) throws -> [LibraryAuditEvent] {
    let bounded = max(1, min(limit, 5_000))
    return try database.pool.read { db in
      try Row.fetchAll(
        db, sql: "SELECT * FROM library_audit_event ORDER BY occurred_at DESC LIMIT ?",
        arguments: [bounded]
      ).map(decodeAudit)
    }
  }

  /// Inserts or updates one durable quality run and replaces its bounded
  /// finding set atomically. Callers may persist queued/running progress and
  /// later complete or fail the same identity without exposing partial rows.
  package func saveReadAloudAudit(_ run: LibraryReadAloudAuditRun) throws {
    try saveReadAloudAudits([run])
  }

  /// Persists a batch of queued quality checks atomically. This is used by
  /// multi-selection so either every selected target enters the FIFO or none do.
  package func saveReadAloudAudits(_ runs: [LibraryReadAloudAuditRun]) throws {
    guard !runs.isEmpty else {
      throw LibraryStoreError.invalidRecord("ReadAloud audit batch is empty")
    }
    guard Set(runs.map(\.id)).count == runs.count else {
      throw LibraryStoreError.invalidRecord("duplicate ReadAloud audit run ID")
    }
    try runs.forEach(validateReadAloudAudit)
    try database.pool.write { db in
      for run in runs { try upsertReadAloudAudit(run, db: db) }
    }
  }

  private func upsertReadAloudAudit(_ run: LibraryReadAloudAuditRun, db: Database) throws {
    let target = auditTargetColumns(run.target)
    try db.execute(
        sql: """
          INSERT INTO readaloud_audit_run(
            id, subject_kind, local_product_id, connection_id, remote_book_id,
            remote_asset_id, standalone_path, artifact_sha256, reference_sha256,
            analyzer_identity, policy_version, mode, lifecycle, progress,
            progress_message, verdict, evidence_adequacy, model_identity,
            tool_identity, metrics_json, report_json, started_at, updated_at,
            completed_at, error
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(id) DO UPDATE SET
            artifact_sha256=excluded.artifact_sha256,
            reference_sha256=excluded.reference_sha256,
            analyzer_identity=excluded.analyzer_identity,
            policy_version=excluded.policy_version,
            mode=excluded.mode,
            lifecycle=excluded.lifecycle,
            progress=excluded.progress,
            progress_message=excluded.progress_message,
            verdict=excluded.verdict,
            evidence_adequacy=excluded.evidence_adequacy,
            model_identity=excluded.model_identity,
            tool_identity=excluded.tool_identity,
            metrics_json=excluded.metrics_json,
            report_json=excluded.report_json,
            updated_at=excluded.updated_at,
            completed_at=excluded.completed_at,
            error=excluded.error
          """,
        arguments: [
          key(run.id), target.kind, target.localProductID.map(key),
          target.connectionID.map(key), target.remoteBookID.map(key),
          target.remoteAssetID.map(key), target.path, run.artifactSHA256,
          run.referenceSHA256, run.analyzerIdentity, run.policyVersion, run.mode,
          run.lifecycle.rawValue, run.progress, run.progressMessage, run.verdict,
          run.evidenceAdequacy, run.modelIdentity, run.toolIdentity,
          run.metricsData, run.reportData, time(run.startedAt), time(run.updatedAt),
          run.completedAt.map(time), run.error,
        ])
    try db.execute(
      sql: "DELETE FROM readaloud_audit_finding WHERE run_id = ?",
      arguments: [key(run.id)])
    for (ordinal, finding) in run.findings.enumerated() {
      try db.execute(
        sql: """
          INSERT INTO readaloud_audit_finding(
            id, run_id, ordinal, dimension, code, verdict, confidence,
            summary, evidence_json
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          key(finding.id), key(run.id), ordinal, finding.dimension,
          finding.code, finding.verdict, finding.confidence, finding.summary,
          finding.evidenceData,
        ])
    }
  }

  package func readAloudAudits(limit: Int = 500) throws -> [LibraryReadAloudAuditRun] {
    let bounded = max(1, min(limit, 5_000))
    return try database.pool.read { db in
      try Row.fetchAll(
        db, sql: "SELECT * FROM readaloud_audit_run ORDER BY started_at DESC LIMIT ?",
        arguments: [bounded]
      ).map { try decodeReadAloudAudit($0, db: db) }
    }
  }

  package func latestReadAloudAudit(
    for target: LibraryReadAloudAuditTarget
  ) throws -> LibraryReadAloudAuditRun? {
    let value = auditTargetColumns(target)
    return try database.pool.read { db in
      let row: Row?
      switch target {
      case .localProduct:
        row = try Row.fetchOne(
          db,
          sql:
            "SELECT * FROM readaloud_audit_run WHERE subject_kind = ? AND local_product_id = ? ORDER BY started_at DESC LIMIT 1",
          arguments: [value.kind, value.localProductID.map(key)])
      case .remote:
        row = try Row.fetchOne(
          db,
          sql:
            "SELECT * FROM readaloud_audit_run WHERE subject_kind = ? AND connection_id = ? AND remote_book_id = ? AND remote_asset_id = ? ORDER BY started_at DESC LIMIT 1",
          arguments: [
            value.kind, value.connectionID.map(key), value.remoteBookID.map(key),
            value.remoteAssetID.map(key),
          ])
      case .standalone:
        row = try Row.fetchOne(
          db,
          sql:
            "SELECT * FROM readaloud_audit_run WHERE subject_kind = ? AND standalone_path = ? ORDER BY started_at DESC LIMIT 1",
          arguments: [value.kind, value.path])
      }
      return try row.map { try decodeReadAloudAudit($0, db: db) }
    }
  }

  /// One applicability lookup for a batch query; see
  /// `latestApplicableReadAloudAudit(for:...)` for the semantics of the key.
  package struct ReadAloudAuditApplicabilityRequest: Sendable {
    package let target: LibraryReadAloudAuditTarget
    package let artifactSHA256: String
    package let referenceSHA256: String?

    package init(
      target: LibraryReadAloudAuditTarget, artifactSHA256: String,
      referenceSHA256: String?
    ) {
      self.target = target
      self.artifactSHA256 = artifactSHA256
      self.referenceSHA256 = referenceSHA256
    }
  }

  /// Returns only terminal semantic evidence that applies to the exact bytes
  /// and current analyzer policy. Newer running or failed attempts cannot
  /// shadow a valid completed report.
  package func latestApplicableReadAloudAudit(
    for target: LibraryReadAloudAuditTarget,
    artifactSHA256: String,
    referenceSHA256: String?,
    analyzerIdentity: String,
    policyVersion: Int
  ) throws -> LibraryReadAloudAuditRun? {
    try validateApplicabilityKey(
      artifactSHA256: artifactSHA256, referenceSHA256: referenceSHA256,
      analyzerIdentity: analyzerIdentity, policyVersion: policyVersion)
    return try database.pool.read { db in
      try latestApplicableReadAloudAudit(
        for: target, artifactSHA256: artifactSHA256, referenceSHA256: referenceSHA256,
        analyzerIdentity: analyzerIdentity, policyVersion: policyVersion, db: db)
    }
  }

  /// Batch form of `latestApplicableReadAloudAudit(for:...)`: identical
  /// per-target semantics, one database read for the whole set so callers
  /// building large views avoid a query per row.
  package func latestApplicableReadAloudAudits(
    _ requests: [ReadAloudAuditApplicabilityRequest],
    analyzerIdentity: String, policyVersion: Int
  ) throws -> [LibraryReadAloudAuditTarget: LibraryReadAloudAuditRun] {
    for request in requests {
      try validateApplicabilityKey(
        artifactSHA256: request.artifactSHA256, referenceSHA256: request.referenceSHA256,
        analyzerIdentity: analyzerIdentity, policyVersion: policyVersion)
    }
    return try database.pool.read { db in
      var result: [LibraryReadAloudAuditTarget: LibraryReadAloudAuditRun] = [:]
      for request in requests {
        result[request.target] = try latestApplicableReadAloudAudit(
          for: request.target, artifactSHA256: request.artifactSHA256,
          referenceSHA256: request.referenceSHA256,
          analyzerIdentity: analyzerIdentity, policyVersion: policyVersion, db: db)
      }
      return result
    }
  }

  private func validateApplicabilityKey(
    artifactSHA256: String, referenceSHA256: String?,
    analyzerIdentity: String, policyVersion: Int
  ) throws {
    guard validHash(artifactSHA256), referenceSHA256.map(validHash) ?? true,
      !analyzerIdentity.isEmpty, policyVersion > 0
    else { throw LibraryStoreError.invalidRecord("invalid ReadAloud audit applicability key") }
  }

  private func latestApplicableReadAloudAudit(
    for target: LibraryReadAloudAuditTarget,
    artifactSHA256: String,
    referenceSHA256: String?,
    analyzerIdentity: String,
    policyVersion: Int,
    db: Database
  ) throws -> LibraryReadAloudAuditRun? {
    let value = auditTargetColumns(target)
    var clauses = [
      "subject_kind = ?", "lifecycle = 'completed'", "artifact_sha256 = ?",
      "reference_sha256 IS ?", "analyzer_identity = ?", "policy_version = ?",
    ]
    var arguments: StatementArguments = [
      value.kind, artifactSHA256, referenceSHA256, analyzerIdentity, policyVersion,
    ]
    switch target {
    case .localProduct:
      clauses.append("local_product_id = ?")
      arguments += [value.localProductID.map(key)]
    case .remote:
      clauses += ["connection_id = ?", "remote_book_id = ?", "remote_asset_id = ?"]
      arguments += [
        value.connectionID.map(key), value.remoteBookID.map(key),
        value.remoteAssetID.map(key),
      ]
    case .standalone:
      clauses.append("standalone_path = ?")
      arguments += [value.path]
    }
    guard let row = try Row.fetchOne(
      db,
      sql: "SELECT * FROM readaloud_audit_run WHERE \(clauses.joined(separator: " AND ")) ORDER BY completed_at DESC, started_at DESC LIMIT 1",
      arguments: arguments)
    else { return nil }
    return try decodeReadAloudAudit(row, db: db)
  }

  package func recordRemoteAssetHash(
    connectionID: UUID, bookID: UUID, assetID: UUID,
    format: LibraryRemoteFormat, sha256: String
  ) throws {
    guard validHash(sha256) else {
      throw LibraryStoreError.invalidRecord("invalid remote asset hash")
    }
    try database.pool.write { db in
      try db.execute(
        sql: "UPDATE remote_asset SET sha256 = ? WHERE connection_id = ? AND remote_book_id = ? AND format = ? AND asset_id = ?",
        arguments: [
          sha256, key(connectionID), key(bookID), format.rawValue, key(assetID),
        ])
      guard db.changesCount == 1 else {
        throw LibraryStoreError.invalidRecord("remote asset changed before its hash was recorded")
      }
    }
  }

  package func deleteReadAloudAudit(_ id: UUID) throws {
    try database.pool.write { db in
      try db.execute(
        sql: "DELETE FROM readaloud_audit_run WHERE id = ?", arguments: [key(id)])
    }
  }

  package func reconcileInterruptedReadAloudAudits() throws {
    let now = Date()
    try database.pool.write { db in
      try db.execute(
        sql: """
          UPDATE readaloud_audit_run
          SET lifecycle = 'failed', progress_message = 'Interrupted by application exit',
              completed_at = ?, updated_at = ?, error = 'The previous application session ended before this audit completed.'
          WHERE lifecycle = 'running'
          """,
        arguments: [time(now), time(now)])
    }
  }

  package func assertProvenance(_ assertion: LibraryProvenanceAssertion) throws {
    try assertProvenance([assertion])
  }

  /// Appends a set of user-reviewed narration assertions as one durable decision.
  /// The transaction prevents a bulk Library action from applying only a prefix.
  package func assertProvenance(_ assertions: [LibraryProvenanceAssertion]) throws {
    guard !assertions.isEmpty else {
      throw LibraryStoreError.invalidRecord("provenance assertion set is empty")
    }
    guard Set(assertions.map(\.id)).count == assertions.count else {
      throw LibraryStoreError.invalidRecord("duplicate provenance assertion ID")
    }
    try database.pool.write { db in
      for assertion in assertions {
        try db.execute(
          sql: """
            INSERT INTO provenance_assertion(
              id, connection_id, remote_book_id, remote_asset_id, remote_sha256,
              provenance, coherence, aligned_audio_asset_id, aligned_audio_sha256,
              source, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
          arguments: [
            key(assertion.id), key(assertion.connectionID), key(assertion.remoteBookID),
            key(assertion.remoteAssetID), assertion.remoteSHA256, assertion.provenance.rawValue,
            assertion.coherence.rawValue, assertion.alignedAudioAssetID.map(key),
            assertion.alignedAudioSHA256, assertion.source, time(assertion.createdAt),
          ])
        try insertAudit(
          .init(
            kind: "remote.provenance.asserted", connectionID: assertion.connectionID,
            remoteBookID: assertion.remoteBookID), db: db)
      }
    }
  }

  /// Stores an edition-scoped correction without rewriting imported source
  /// metadata. The newest assertion for a normalized identifier kind wins.
  package func setEditionIdentifier(
    editionID: UUID, kind: String?, value: String, note: String? = nil
  ) throws {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw LibraryStoreError.invalidRecord("identifier is empty") }
    let assertion = LibraryIdentifierAssertion(
      editionID: editionID, kind: kind, value: trimmed, source: "user", note: note)
    try database.pool.write { db in
      guard
        try Int.fetchOne(
          db, sql: "SELECT COUNT(*) FROM library_edition WHERE id = ?", arguments: [key(editionID)])
          == 1
      else { throw LibraryStoreError.notFound("edition") }
      try db.execute(
        sql: """
          INSERT INTO identifier_assertion(
            id, edition_id, connection_id, remote_book_id, scope, kind, value,
            disposition, source, note, created_at
          ) VALUES (?, ?, NULL, NULL, ?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          key(assertion.id), key(editionID), assertion.scope.rawValue, assertion.kind,
          assertion.value, assertion.disposition.rawValue, assertion.source,
          assertion.note, time(assertion.createdAt),
        ])
      try touchEdition(
        editionID,
        expectedRevision: try UInt64.fetchOne(
          db, sql: "SELECT revision FROM library_edition WHERE id = ?", arguments: [key(editionID)])!,
        db: db)
      try insertAudit(
        .init(kind: "identifier.corrected", editionID: editionID), db: db)
    }
  }

  package func provenance(
    connectionID: UUID, remoteBookID: UUID, remoteAssetID: UUID
  ) throws -> LibraryProvenanceAssertion? {
    try database.pool.read { db in
      guard
        let row = try Row.fetchOne(
          db,
          sql: """
            SELECT * FROM provenance_assertion
            WHERE connection_id = ? AND remote_book_id = ? AND remote_asset_id = ?
            ORDER BY created_at DESC, id DESC LIMIT 1
            """,
          arguments: [key(connectionID), key(remoteBookID), key(remoteAssetID)])
      else { return nil }
      guard let id = uuid(row["id"] as String),
        let provenance = NarrationProvenance(rawValue: row["provenance"] as String),
        let coherence = PackageCoherence(rawValue: row["coherence"] as String)
      else { throw LibraryStoreError.invalidRecord("invalid provenance assertion") }
      let alignedID: String? = row["aligned_audio_asset_id"]
      return .init(
        id: id, connectionID: connectionID, remoteBookID: remoteBookID,
        remoteAssetID: remoteAssetID, remoteSHA256: row["remote_sha256"],
        provenance: provenance, coherence: coherence,
        alignedAudioAssetID: alignedID.flatMap(uuid),
        alignedAudioSHA256: row["aligned_audio_sha256"], source: row["source"],
        createdAt: date(row["created_at"]))
    }
  }

  /// The newest provenance assertion for every (book, asset) pair of one
  /// connection in a single read, for callers rendering whole libraries.
  package func latestProvenances(
    connectionID: UUID
  ) throws -> [LibraryProvenanceAssertion] {
    try database.pool.read { db in
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT * FROM provenance_assertion
          WHERE connection_id = ?
          ORDER BY created_at DESC, id DESC
          """,
        arguments: [key(connectionID)])
      var seen = Set<String>()
      var result: [LibraryProvenanceAssertion] = []
      for row in rows {
        guard let id = uuid(row["id"] as String),
          let remoteBookID = uuid(row["remote_book_id"] as String),
          let remoteAssetID = uuid(row["remote_asset_id"] as String),
          let provenance = NarrationProvenance(rawValue: row["provenance"] as String),
          let coherence = PackageCoherence(rawValue: row["coherence"] as String)
        else { throw LibraryStoreError.invalidRecord("invalid provenance assertion") }
        // Newest-first ordering: the first row per key is the latest assertion.
        guard seen.insert("\(remoteBookID.uuidString):\(remoteAssetID.uuidString)").inserted
        else { continue }
        let alignedID: String? = row["aligned_audio_asset_id"]
        result.append(
          .init(
            id: id, connectionID: connectionID, remoteBookID: remoteBookID,
            remoteAssetID: remoteAssetID, remoteSHA256: row["remote_sha256"],
            provenance: provenance, coherence: coherence,
            alignedAudioAssetID: alignedID.flatMap(uuid),
            alignedAudioSHA256: row["aligned_audio_sha256"], source: row["source"],
            createdAt: date(row["created_at"])))
      }
      return result
    }
  }

  package func checkpointForMigration() throws {
    _ = try database.pool.writeWithoutTransaction { db in
      try db.checkpoint(.truncate)
    }
  }

  // MARK: - Edition persistence

  private func insertEdition(_ edition: LibraryEdition, db: Database) throws {
    try db.execute(
      sql: "INSERT INTO library_work(id, created_at) VALUES (?, ?) ON CONFLICT(id) DO NOTHING",
      arguments: [key(edition.workID), time(edition.createdAt)])
    try db.execute(
      sql: """
        INSERT INTO library_edition(
          id, work_id, revision, created_at, updated_at, title, author, language,
          publisher, publication_date, identifiers_json, output_directory, output_base_name
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
      arguments: [
        key(edition.id), key(edition.workID), edition.revision, time(edition.createdAt),
        time(edition.updatedAt), edition.metadata.title, edition.metadata.author,
        edition.metadata.language, edition.metadata.publisher, edition.metadata.publicationDate,
        try json(edition.metadata.identifiers), edition.outputDirectory, edition.outputBaseName,
      ])
    try db.execute(
      sql: """
        INSERT INTO source_artifact(
          id, edition_id, format, path, importer_version, sha256, size, verified_at, state
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
      arguments: [
        key(edition.source.id), key(edition.id), edition.source.format, edition.source.path,
        edition.source.importerVersion, edition.source.sha256, signed(edition.source.size),
        time(edition.source.verifiedAt), edition.source.state.rawValue,
      ])
    for product in edition.products {
      try validateProduct(product)
      try insertProduct(product, editionID: edition.id, db: db)
      try db.execute(
        sql: "INSERT INTO primary_product(edition_id, kind, product_id) VALUES (?, ?, ?)",
        arguments: [key(edition.id), product.kind.rawValue, key(product.id)])
    }
    for dependency in edition.dependencies {
      try db.execute(
        sql: "INSERT INTO product_dependency(product_id, role, input_sha256) VALUES (?, ?, ?)",
        arguments: [key(dependency.productID), dependency.role.rawValue, dependency.inputSHA256])
    }
    for link in edition.remoteLinks { try insertLink(link, editionID: edition.id, db: db) }
  }

  private func insertProduct(_ product: LibraryLocalProduct, editionID: UUID, db: Database) throws {
    try db.execute(
      sql: """
        INSERT INTO local_product(
          id, edition_id, kind, path, size, sha256, verified_at, state,
          producer_job_id, narration_json, readaloud_json
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
      arguments: [
        key(product.id), key(editionID), product.kind.rawValue, product.path,
        signed(product.size), product.sha256, time(product.verifiedAt), product.state.rawValue,
        product.producerJobID.map(key), product.narrationData, product.readAloudData,
      ])
  }

  private func insertLink(_ link: LibraryRemoteLink, editionID: UUID, db: Database) throws {
    let linkID = UUID()
    try db.execute(
      sql: """
        INSERT INTO edition_remote_link(
          id, edition_id, provider_id, connection_id, remote_book_id, state, evidence,
          revision, linked_at, last_observed_at, remote_title, remote_authors_json
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
      arguments: [
        key(linkID), key(editionID), link.providerID, key(link.connectionID),
        key(link.remoteBookID), link.state.rawValue, link.evidence.rawValue, link.revision,
        time(link.linkedAt), link.lastObservedAt.map(time), link.remoteTitle,
        try json(link.remoteAuthors),
      ])
    for receipt in link.receipts {
      try db.execute(
        sql: """
          INSERT INTO delivery_receipt(
            id, link_id, format, local_sha256, remote_asset_id, remote_size,
            remote_fingerprint, remote_sha256, observed_at
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          key(UUID()), key(linkID), receipt.format.rawValue, receipt.localSHA256,
          receipt.remoteAssetID.map(key), receipt.remoteSize.map(signed),
          receipt.remoteFingerprint, receipt.remoteSHA256, time(receipt.observedAt),
        ])
    }
    for excluded in link.excludedRemoteBookIDs {
      try db.execute(
        sql: """
          INSERT OR IGNORE INTO remote_match_decision(
            id, edition_id, connection_id, remote_book_id, decision, created_at
          ) VALUES (?, ?, ?, ?, 'excluded', ?)
          """,
        arguments: [
          key(UUID()), key(editionID), key(link.connectionID), key(excluded), time(link.linkedAt),
        ])
    }
  }

  private func loadEdition(_ id: UUID, db: Database) throws -> LibraryEdition {
    guard
      let row = try Row.fetchOne(
        db, sql: "SELECT * FROM library_edition WHERE id = ?", arguments: [key(id)])
    else { throw LibraryStoreError.notFound("edition \(id.uuidString)") }
    guard let workID = uuid(row["work_id"] as String),
      let sourceRow = try Row.fetchOne(
        db, sql: "SELECT * FROM source_artifact WHERE edition_id = ?", arguments: [key(id)])
    else { throw LibraryStoreError.invalidRecord("edition is missing its source") }
    var identifiers: [PublicationIdentifier] = try decodeJSON(row["identifiers_json"] as Data)
    let assertions = try Row.fetchAll(
      db,
      sql: """
        SELECT kind, value, disposition FROM identifier_assertion
        WHERE edition_id = ? AND scope = 'edition' ORDER BY created_at
        """, arguments: [key(id)])
    for assertion in assertions {
      let kind: String? = assertion["kind"]
      let normalizedKind = kind?.lowercased()
      if let normalizedKind {
        identifiers.removeAll { $0.kind?.lowercased() == normalizedKind }
      }
      if (assertion["disposition"] as String) == LibraryIdentifierDisposition.asserted.rawValue {
        identifiers.append(.init(kind: kind, value: assertion["value"]))
      }
    }
    let metadata = LibraryCatalogMetadata(
      title: row["title"], author: row["author"], language: row["language"],
      publisher: row["publisher"], publicationDate: row["publication_date"],
      identifiers: identifiers)
    let source = try decodeSource(sourceRow)
    let productRows = try Row.fetchAll(
      db,
      sql: """
        SELECT p.* FROM local_product p
        JOIN primary_product x ON x.product_id = p.id
        WHERE x.edition_id = ? ORDER BY p.kind
        """, arguments: [key(id)])
    let products = try productRows.map(decodeProduct)
    let productIDs = products.map { key($0.id) }
    var dependencies: [LibraryProductDependency] = []
    if !productIDs.isEmpty {
      let placeholders = Array(repeating: "?", count: productIDs.count).joined(separator: ",")
      dependencies = try Row.fetchAll(
        db, sql: "SELECT * FROM product_dependency WHERE product_id IN (\(placeholders))",
        arguments: StatementArguments(productIDs)
      ).map { row in
        guard let id = uuid(row["product_id"] as String),
          let role = LibraryProductDependency.Role(rawValue: row["role"] as String)
        else { throw LibraryStoreError.invalidRecord("invalid product dependency") }
        return .init(productID: id, role: role, inputSHA256: row["input_sha256"])
      }
    }
    let links = try Row.fetchAll(
      db, sql: "SELECT * FROM edition_remote_link WHERE edition_id = ? ORDER BY linked_at",
      arguments: [key(id)]
    ).map { try decodeLink($0, editionID: id, db: db) }
    let edition = LibraryEdition(
      id: id, workID: workID, revision: row["revision"],
      createdAt: date(row["created_at"]), updatedAt: date(row["updated_at"]),
      metadata: metadata, outputDirectory: row["output_directory"],
      outputBaseName: row["output_base_name"], source: source, products: products,
      dependencies: dependencies, remoteLinks: links)
    try validateEdition(edition)
    return edition
  }

  private func decodeSource(_ row: Row) throws -> LibrarySourceArtifact {
    guard let id = uuid(row["id"] as String),
      let state = LibraryArtifactState(rawValue: row["state"] as String)
    else { throw LibraryStoreError.invalidRecord("invalid source artifact") }
    return .init(
      id: id, format: row["format"], path: row["path"],
      importerVersion: row["importer_version"], sha256: row["sha256"],
      size: unsigned(row["size"] as Int64), verifiedAt: date(row["verified_at"]), state: state)
  }

  private func decodeProduct(_ row: Row) throws -> LibraryLocalProduct {
    guard let id = uuid(row["id"] as String),
      let kind = LibraryProductKind(rawValue: row["kind"] as String),
      let state = LibraryArtifactState(rawValue: row["state"] as String)
    else { throw LibraryStoreError.invalidRecord("invalid local product") }
    let producer: String? = row["producer_job_id"]
    return .init(
      id: id, kind: kind, path: row["path"], size: unsigned(row["size"] as Int64),
      sha256: row["sha256"], verifiedAt: date(row["verified_at"]), state: state,
      producerJobID: producer.flatMap(uuid), narrationData: row["narration_json"],
      readAloudData: row["readaloud_json"])
  }

  private func decodeLink(_ row: Row, editionID: UUID, db: Database) throws -> LibraryRemoteLink {
    guard let linkID = uuid(row["id"] as String),
      let connectionID = uuid(row["connection_id"] as String),
      let remoteBookID = uuid(row["remote_book_id"] as String),
      let state = LibraryLinkState(rawValue: row["state"] as String),
      let evidence = LibraryLinkEvidence(rawValue: row["evidence"] as String)
    else { throw LibraryStoreError.invalidRecord("invalid remote link") }
    let receipts = try Row.fetchAll(
      db, sql: "SELECT * FROM delivery_receipt WHERE link_id = ? ORDER BY format",
      arguments: [key(linkID)]
    ).map { receipt -> LibraryRemoteReceipt in
      guard let format = LibraryRemoteFormat(rawValue: receipt["format"] as String) else {
        throw LibraryStoreError.invalidRecord("invalid delivery receipt")
      }
      let asset: String? = receipt["remote_asset_id"]
      let size: Int64? = receipt["remote_size"]
      return .init(
        format: format, localSHA256: receipt["local_sha256"],
        remoteAssetID: asset.flatMap(uuid), remoteSize: size.map(unsigned),
        remoteFingerprint: receipt["remote_fingerprint"], remoteSHA256: receipt["remote_sha256"],
        observedAt: date(receipt["observed_at"]))
    }
    let excludedValues = try String.fetchAll(
      db,
      sql:
        "SELECT remote_book_id FROM remote_match_decision WHERE edition_id = ? AND connection_id = ? AND decision = 'excluded'",
      arguments: [key(editionID), key(connectionID)])
    let excluded = excludedValues.compactMap(uuid)
    guard excluded.count == excludedValues.count else {
      throw LibraryStoreError.invalidRecord("invalid excluded remote book identity")
    }
    let observed: Double? = row["last_observed_at"]
    return .init(
      providerID: row["provider_id"], connectionID: connectionID,
      remoteBookID: remoteBookID, state: state, evidence: evidence,
      revision: row["revision"], linkedAt: date(row["linked_at"]),
      lastObservedAt: observed.map(date), remoteTitle: row["remote_title"],
      remoteAuthors: try decodeJSON(row["remote_authors_json"] as Data),
      receipts: receipts, excludedRemoteBookIDs: excluded)
  }

  // MARK: - Remote inventory persistence

  private func upsertRemoteBook(_ book: LibraryRemoteBookSnapshot, db: Database) throws {
    let previousAssets = try Row.fetchAll(
      db,
      sql: "SELECT format, asset_id, fingerprint, file_size, sha256 FROM remote_asset WHERE connection_id = ? AND remote_book_id = ?",
      arguments: [key(book.connectionID), key(book.remoteBookID)])
    var reusableHashes: [LibraryRemoteFormat: String] = [:]
    for row in previousAssets {
      guard let format = LibraryRemoteFormat(rawValue: row["format"] as String),
        let hash: String = row["sha256"],
        let current = book.asset(format),
        (row["asset_id"] as String) == key(current.assetID),
        (row["fingerprint"] as String?) == current.fingerprint,
        (row["file_size"] as Int64?).map(UInt64.init) == current.fileSize
      else { continue }
      reusableHashes[format] = hash
    }
    try db.execute(
      sql: """
        INSERT INTO remote_book(
          connection_id, remote_book_id, title, subtitle, authors_json, narrators_json,
          identifiers_json, observed_at, generation, missing_at, updated_at, snapshot_json
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, ?)
        ON CONFLICT(connection_id, remote_book_id) DO UPDATE SET
          title=excluded.title, subtitle=excluded.subtitle, authors_json=excluded.authors_json,
          narrators_json=excluded.narrators_json, identifiers_json=excluded.identifiers_json,
          observed_at=excluded.observed_at, generation=excluded.generation, missing_at=NULL,
          updated_at=excluded.updated_at, snapshot_json=excluded.snapshot_json
        """,
      arguments: [
        key(book.connectionID), key(book.remoteBookID), book.title, book.subtitle,
        try json(book.authors), try json(book.narrators), try json(book.identifiers),
        time(book.observedAt), book.generation, book.updatedAt, try json(book),
      ])
    try db.execute(
      sql: "DELETE FROM remote_asset WHERE connection_id = ? AND remote_book_id = ?",
      arguments: [key(book.connectionID), key(book.remoteBookID)])
    for asset in book.assets {
      try db.execute(
        sql: """
          INSERT INTO remote_asset(
            connection_id, remote_book_id, format, asset_id, filepath, fingerprint,
            file_size, sha256, updated_at, state, status, current_stage, stage_progress,
            identifiers_json
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          key(book.connectionID), key(book.remoteBookID), asset.format.rawValue,
          key(asset.assetID), asset.filepath, asset.fingerprint, asset.fileSize.map(signed),
          asset.sha256 ?? reusableHashes[asset.format],
          asset.updatedAt, asset.state.rawValue, asset.status,
          asset.currentStage, asset.stageProgress, try json(asset.identifiers),
        ])
    }
  }

  private func decodeRemoteBook(_ row: Row, db: Database) throws -> LibraryRemoteBookSnapshot {
    guard let connectionID = uuid(row["connection_id"] as String),
      let bookID = uuid(row["remote_book_id"] as String)
    else { throw LibraryStoreError.invalidRecord("invalid remote book identity") }
    let assets = try Row.fetchAll(
      db,
      sql:
        "SELECT * FROM remote_asset WHERE connection_id = ? AND remote_book_id = ? ORDER BY format",
      arguments: [key(connectionID), key(bookID)]
    ).map(decodeRemoteAsset)
    let missing: Double? = row["missing_at"]
    return .init(
      connectionID: connectionID, remoteBookID: bookID, title: row["title"],
      subtitle: row["subtitle"], authors: try decodeJSON(row["authors_json"] as Data),
      narrators: try decodeJSON(row["narrators_json"] as Data),
      identifiers: try decodeJSON(row["identifiers_json"] as Data), assets: assets,
      observedAt: date(row["observed_at"]), generation: row["generation"],
      missingAt: missing.map(date), updatedAt: row["updated_at"])
  }

  private func decodeRemoteAsset(_ row: Row) throws -> LibraryRemoteAssetSnapshot {
    guard let id = uuid(row["asset_id"] as String),
      let format = LibraryRemoteFormat(rawValue: row["format"] as String),
      let state = LibraryRemoteAssetState(rawValue: row["state"] as String)
    else { throw LibraryStoreError.invalidRecord("invalid remote asset") }
    let size: Int64? = row["file_size"]
    return .init(
      format: format, assetID: id, filepath: row["filepath"], fingerprint: row["fingerprint"],
      fileSize: size.map(unsigned), sha256: row["sha256"], updatedAt: row["updated_at"],
      state: state, status: row["status"], currentStage: row["current_stage"],
      stageProgress: row["stage_progress"],
      identifiers: try decodeJSON(row["identifiers_json"] as Data))
  }

  // MARK: - Validation and utilities

  private func validateEdition(_ edition: LibraryEdition) throws {
    let productIDs = Set(edition.products.map(\.id))
    let dependencyKeys = edition.dependencies.map {
      "\($0.productID.uuidString):\($0.role.rawValue)"
    }
    guard edition.revision < UInt64(Int64.max),
      edition.source.format == "epub", edition.source.size > 0,
      edition.source.size <= UInt64(Int64.max),
      validHash(edition.source.sha256), (edition.source.path as NSString).isAbsolutePath,
      (edition.outputDirectory as NSString).isAbsolutePath,
      !edition.outputBaseName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      Set(edition.products.map(\.kind)).count == edition.products.count,
      productIDs.count == edition.products.count,
      Set(dependencyKeys).count == dependencyKeys.count,
      edition.dependencies.allSatisfy({
        productIDs.contains($0.productID) && validHash($0.inputSHA256)
      })
    else { throw LibraryStoreError.invalidRecord("invalid edition identity or layout") }
    try edition.products.forEach(validateProduct)
    try validateLinks(edition.remoteLinks)
  }

  private func validateProduct(_ product: LibraryLocalProduct) throws {
    guard product.size > 0, product.size <= UInt64(Int64.max), validHash(product.sha256),
      (product.path as NSString).isAbsolutePath
    else { throw LibraryStoreError.invalidRecord("invalid local product") }
  }

  private func validateLinks(_ links: [LibraryRemoteLink]) throws {
    let keys = links.map { "\($0.providerID):\($0.connectionID.uuidString)" }
    guard Set(keys).count == keys.count,
      links.allSatisfy({
        !$0.providerID.isEmpty && $0.revision < UInt64(Int64.max)
          && Set($0.receipts.map(\.format)).count == $0.receipts.count
          && Set($0.excludedRemoteBookIDs).count == $0.excludedRemoteBookIDs.count
      }),
      links.flatMap(\.receipts).allSatisfy({
        validHash($0.localSHA256) && ($0.remoteSHA256.map(validHash) ?? true)
          && ($0.remoteSize.map { $0 > 0 && $0 <= UInt64(Int64.max) } ?? true)
      })
    else { throw LibraryStoreError.invalidRecord("invalid remote links") }
  }

  private func validateConnection(_ connection: LibraryConnection) throws {
    guard !connection.providerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !connection.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      let scheme = connection.origin.scheme?.lowercased(), ["http", "https"].contains(scheme),
      connection.origin.host != nil, connection.origin.user == nil,
      connection.origin.password == nil,
      connection.origin.query == nil, connection.origin.fragment == nil,
      connection.origin.path.isEmpty || connection.origin.path == "/",
      connection.permissionsData.map({ $0.count <= 1 << 20 }) ?? true
    else { throw LibraryStoreError.invalidRecord("invalid remote connection") }
  }

  private func validateRemoteBook(_ book: LibraryRemoteBookSnapshot) throws {
    guard !book.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      Set(book.assets.map(\.format)).count == book.assets.count,
      Set(book.assets.map(\.assetID)).count == book.assets.count,
      book.identifiers.allSatisfy({
        !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      }),
      book.assets.allSatisfy({ asset in
        (asset.fileSize.map { $0 > 0 && $0 <= UInt64(Int64.max) } ?? true)
          && (asset.sha256.map(validHash) ?? true)
          && (asset.stageProgress.map { $0.isFinite && (0...1).contains($0) } ?? true)
          && asset.identifiers.allSatisfy {
            !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          }
      })
    else { throw LibraryStoreError.invalidRecord("invalid remote book snapshot") }
  }

  private func touchEdition(_ id: UUID, expectedRevision: UInt64, db: Database) throws {
    guard expectedRevision < UInt64(Int64.max) - 1 else {
      throw LibraryStoreError.invalidRecord("edition revision is exhausted")
    }
    try db.execute(
      sql:
        "UPDATE library_edition SET revision = revision + 1, updated_at = ? WHERE id = ? AND revision = ?",
      arguments: [time(Date()), key(id), expectedRevision])
    guard db.changesCount == 1 else {
      throw LibraryStoreError.conflict("edition changed concurrently")
    }
  }

  private func insertAudit(_ event: LibraryAuditEvent, db: Database) throws {
    try db.execute(
      sql: """
        INSERT INTO library_audit_event(
          id, occurred_at, kind, edition_id, connection_id, remote_book_id, detail_json
        ) VALUES (?, ?, ?, ?, ?, ?, ?)
        """,
      arguments: [
        key(event.id), time(event.occurredAt), event.kind, event.editionID.map(key),
        event.connectionID.map(key), event.remoteBookID.map(key), event.detailData,
      ])
  }

  private func decodeConnection(_ row: Row) throws -> LibraryConnection {
    guard let id = uuid(row["id"] as String),
      let origin = URL(string: row["origin"] as String)
    else { throw LibraryStoreError.invalidRecord("invalid remote connection") }
    let remoteUser: String? = row["remote_user_id"]
    let disconnected: Double? = row["disconnected_at"]
    return .init(
      id: id, providerID: row["provider_id"], origin: origin,
      displayName: row["display_name"], username: row["username"],
      remoteUserID: remoteUser.flatMap(uuid), permissionsData: row["permissions_json"],
      connectedAt: date(row["connected_at"]), disconnectedAt: disconnected.map(date))
  }

  private func decodeAudit(_ row: Row) throws -> LibraryAuditEvent {
    let edition: String? = row["edition_id"]
    let connection: String? = row["connection_id"]
    let remote: String? = row["remote_book_id"]
    guard let id = uuid(row["id"] as String) else {
      throw LibraryStoreError.invalidRecord("invalid audit event")
    }
    return .init(
      id: id, occurredAt: date(row["occurred_at"]), kind: row["kind"],
      editionID: edition.flatMap(uuid), connectionID: connection.flatMap(uuid),
      remoteBookID: remote.flatMap(uuid), detailData: row["detail_json"])
  }

  private struct AuditTargetColumns {
    var kind: String
    var localProductID: UUID?
    var connectionID: UUID?
    var remoteBookID: UUID?
    var remoteAssetID: UUID?
    var path: String?
  }

  private func auditTargetColumns(_ target: LibraryReadAloudAuditTarget) -> AuditTargetColumns {
    switch target {
    case .localProduct(let id):
      .init(
        kind: "local", localProductID: id, connectionID: nil,
        remoteBookID: nil, remoteAssetID: nil, path: nil)
    case .remote(let connectionID, let bookID, let assetID):
      .init(
        kind: "remote", localProductID: nil, connectionID: connectionID,
        remoteBookID: bookID, remoteAssetID: assetID, path: nil)
    case .standalone(let path):
      .init(
        kind: "standalone", localProductID: nil, connectionID: nil,
        remoteBookID: nil, remoteAssetID: nil, path: path)
    }
  }

  private func validateReadAloudAudit(_ run: LibraryReadAloudAuditRun) throws {
    let terminal =
      run.lifecycle == .completed || run.lifecycle == .cancelled
      || run.lifecycle == .failed
    let targetValid: Bool
    switch run.target {
    case .localProduct: targetValid = true
    case .remote: targetValid = true
    case .standalone(let path): targetValid = (path as NSString).isAbsolutePath
    }
    let completedValid = run.lifecycle != .completed
      || (run.artifactSHA256 != nil && run.verdict != nil
        && run.evidenceAdequacy != nil && run.reportData != nil
        && run.progress == 1)
    guard targetValid, completedValid, run.policyVersion > 0,
      !run.analyzerIdentity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !run.mode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      run.progress.isFinite, (0...1).contains(run.progress),
      run.artifactSHA256.map(validHash) ?? true,
      run.referenceSHA256.map(validHash) ?? true,
      run.findings.count <= 1_000,
      run.findings.allSatisfy({
        !$0.dimension.isEmpty && !$0.code.isEmpty && !$0.verdict.isEmpty
          && !$0.confidence.isEmpty && !$0.summary.isEmpty
          && $0.summary.utf8.count <= 4_096
          && ($0.evidenceData?.count ?? 0) <= 1 << 20
      }),
      (run.metricsData?.count ?? 0) <= 1 << 20,
      (run.reportData?.count ?? 0) <= 4 << 20,
      run.updatedAt >= run.startedAt,
      !terminal || run.completedAt != nil
    else { throw LibraryStoreError.invalidRecord("invalid ReadAloud audit run") }
  }

  private func decodeReadAloudAudit(_ row: Row, db: Database) throws
    -> LibraryReadAloudAuditRun
  {
    guard let id = uuid(row["id"] as String),
      let lifecycle = LibraryReadAloudAuditLifecycle(rawValue: row["lifecycle"] as String)
    else { throw LibraryStoreError.invalidRecord("invalid ReadAloud audit identity") }
    let kind: String = row["subject_kind"]
    let local: String? = row["local_product_id"]
    let connection: String? = row["connection_id"]
    let remoteBook: String? = row["remote_book_id"]
    let remoteAsset: String? = row["remote_asset_id"]
    let path: String? = row["standalone_path"]
    let target: LibraryReadAloudAuditTarget
    switch kind {
    case "local":
      guard let local, let value = uuid(local) else {
        throw LibraryStoreError.invalidRecord("invalid local ReadAloud audit target")
      }
      target = .localProduct(value)
    case "remote":
      guard let connection, let remoteBook, let remoteAsset,
        let connectionID = uuid(connection), let bookID = uuid(remoteBook),
        let assetID = uuid(remoteAsset)
      else { throw LibraryStoreError.invalidRecord("invalid remote ReadAloud audit target") }
      target = .remote(connectionID: connectionID, bookID: bookID, assetID: assetID)
    case "standalone":
      guard let path else {
        throw LibraryStoreError.invalidRecord("invalid standalone ReadAloud audit target")
      }
      target = .standalone(path: path)
    default: throw LibraryStoreError.invalidRecord("unknown ReadAloud audit target")
    }
    let findings = try Row.fetchAll(
      db,
      sql: "SELECT * FROM readaloud_audit_finding WHERE run_id = ? ORDER BY ordinal",
      arguments: [key(id)]
    ).map { value -> LibraryReadAloudAuditFinding in
      guard let findingID = uuid(value["id"] as String) else {
        throw LibraryStoreError.invalidRecord("invalid ReadAloud finding identity")
      }
      return .init(
        id: findingID, dimension: value["dimension"], code: value["code"],
        verdict: value["verdict"], confidence: value["confidence"],
        summary: value["summary"], evidenceData: value["evidence_json"])
    }
    let completed: Double? = row["completed_at"]
    let run = LibraryReadAloudAuditRun(
      id: id, target: target, artifactSHA256: row["artifact_sha256"],
      referenceSHA256: row["reference_sha256"], analyzerIdentity: row["analyzer_identity"],
      policyVersion: row["policy_version"], mode: row["mode"], lifecycle: lifecycle,
      progress: row["progress"], progressMessage: row["progress_message"],
      verdict: row["verdict"], evidenceAdequacy: row["evidence_adequacy"],
      modelIdentity: row["model_identity"], toolIdentity: row["tool_identity"],
      metricsData: row["metrics_json"], reportData: row["report_json"],
      startedAt: date(row["started_at"]), updatedAt: date(row["updated_at"]),
      completedAt: completed.map(date), error: row["error"], findings: findings)
    try validateReadAloudAudit(run)
    return run
  }

  private func json<T: Encodable>(_ value: T) throws -> Data { try encoder.encode(value) }
  private func decodeJSON<T: Decodable>(_ data: Data) throws -> T {
    try decoder.decode(T.self, from: data)
  }
  private func key(_ value: UUID) -> String { value.uuidString.lowercased() }
  private func uuid(_ value: String) -> UUID? { UUID(uuidString: value) }
  private func time(_ value: Date) -> Double { value.timeIntervalSince1970 }
  private func date(_ value: Double) -> Date { Date(timeIntervalSince1970: value) }
  private func signed(_ value: UInt64) -> Int64 { Int64(clamping: value) }
  private func unsigned(_ value: Int64) -> UInt64 { UInt64(max(0, value)) }
  private func validHash(_ value: String) -> Bool {
    value.count == 64 && value == value.lowercased() && value.allSatisfy(\.isHexDigit)
  }
}

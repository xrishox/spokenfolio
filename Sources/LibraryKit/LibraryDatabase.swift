import Foundation
import GRDB

package final class LibraryDatabase: @unchecked Sendable {
  package static let currentSchemaVersion = 2
  package let url: URL
  package let pool: DatabasePool

  package init(url: URL) throws {
    self.url = url.standardizedFileURL
    try FileManager.default.createDirectory(
      at: self.url.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    var configuration = Configuration()
    configuration.busyMode = .timeout(5)
    configuration.prepareDatabase { database in
      try database.execute(sql: "PRAGMA foreign_keys = ON")
      try database.execute(sql: "PRAGMA synchronous = FULL")
      try database.execute(sql: "PRAGMA journal_size_limit = 16777216")
    }
    pool = try DatabasePool(path: self.url.path, configuration: configuration)
    try Self.migrator.migrate(pool)
    try pool.writeWithoutTransaction { database in
      _ = try String.fetchOne(database, sql: "PRAGMA journal_mode = WAL")
    }
    guard chmod(self.url.path, 0o600) == 0 else {
      throw LibraryStoreError.corruptDatabase("could not secure library database permissions")
    }
  }

  package func validate() throws {
    try pool.read { database in
      let quick = try String.fetchAll(database, sql: "PRAGMA quick_check")
      guard quick == ["ok"] else {
        throw LibraryStoreError.corruptDatabase(quick.joined(separator: "; "))
      }
      let foreign = try Row.fetchAll(database, sql: "PRAGMA foreign_key_check")
      guard foreign.isEmpty else {
        throw LibraryStoreError.corruptDatabase("foreign-key check failed")
      }
    }
  }

  private static var migrator: DatabaseMigrator {
    var migrator = DatabaseMigrator()
    migrator.registerMigration("library-v1") { database in
      try database.execute(
        sql: """
            CREATE TABLE library_work (
              id TEXT PRIMARY KEY NOT NULL,
              created_at REAL NOT NULL
            );

            CREATE TABLE library_edition (
              id TEXT PRIMARY KEY NOT NULL,
              work_id TEXT NOT NULL REFERENCES library_work(id) ON DELETE RESTRICT,
              revision INTEGER NOT NULL,
              created_at REAL NOT NULL,
              updated_at REAL NOT NULL,
              title TEXT NOT NULL,
              author TEXT,
              language TEXT,
              publisher TEXT,
              publication_date TEXT,
              identifiers_json BLOB NOT NULL,
              output_directory TEXT NOT NULL,
              output_base_name TEXT NOT NULL
            );

            CREATE TABLE source_artifact (
              id TEXT PRIMARY KEY NOT NULL,
              edition_id TEXT NOT NULL UNIQUE REFERENCES library_edition(id) ON DELETE CASCADE,
              format TEXT NOT NULL,
              path TEXT NOT NULL,
              importer_version INTEGER NOT NULL,
              sha256 TEXT NOT NULL,
              size INTEGER NOT NULL,
              verified_at REAL NOT NULL,
              state TEXT NOT NULL,
              UNIQUE(format, sha256)
            );

            CREATE TABLE local_product (
              id TEXT PRIMARY KEY NOT NULL,
              edition_id TEXT NOT NULL REFERENCES library_edition(id) ON DELETE CASCADE,
              kind TEXT NOT NULL,
              path TEXT NOT NULL,
              size INTEGER NOT NULL,
              sha256 TEXT NOT NULL,
              verified_at REAL NOT NULL,
              state TEXT NOT NULL,
              producer_job_id TEXT,
              narration_json BLOB,
              readaloud_json BLOB,
              UNIQUE(edition_id, kind, sha256)
            );

            CREATE TABLE primary_product (
              edition_id TEXT NOT NULL REFERENCES library_edition(id) ON DELETE CASCADE,
              kind TEXT NOT NULL,
              product_id TEXT NOT NULL UNIQUE REFERENCES local_product(id) ON DELETE CASCADE,
              PRIMARY KEY(edition_id, kind)
            );

            CREATE TABLE product_dependency (
              product_id TEXT NOT NULL REFERENCES local_product(id) ON DELETE CASCADE,
              role TEXT NOT NULL,
              input_sha256 TEXT NOT NULL,
              PRIMARY KEY(product_id, role)
            );

            CREATE TABLE remote_connection (
              id TEXT PRIMARY KEY NOT NULL,
              provider_id TEXT NOT NULL,
              origin TEXT NOT NULL,
              display_name TEXT NOT NULL,
              username TEXT,
              remote_user_id TEXT,
              permissions_json BLOB,
              connected_at REAL NOT NULL,
              disconnected_at REAL
            );

            CREATE TABLE sync_run (
              id TEXT PRIMARY KEY NOT NULL,
              connection_id TEXT NOT NULL REFERENCES remote_connection(id) ON DELETE RESTRICT,
              generation INTEGER NOT NULL,
              started_at REAL NOT NULL,
              completed_at REAL,
              status TEXT NOT NULL,
              error TEXT
            );

            CREATE TABLE remote_book (
              connection_id TEXT NOT NULL REFERENCES remote_connection(id) ON DELETE RESTRICT,
              remote_book_id TEXT NOT NULL,
              title TEXT NOT NULL,
              subtitle TEXT,
              authors_json BLOB NOT NULL,
              narrators_json BLOB NOT NULL,
              identifiers_json BLOB NOT NULL,
              observed_at REAL NOT NULL,
              generation INTEGER NOT NULL,
              missing_at REAL,
              updated_at TEXT,
              snapshot_json BLOB NOT NULL,
              PRIMARY KEY(connection_id, remote_book_id)
            );

            CREATE TABLE remote_asset (
              connection_id TEXT NOT NULL,
              remote_book_id TEXT NOT NULL,
              format TEXT NOT NULL,
              asset_id TEXT NOT NULL,
              filepath TEXT,
              fingerprint TEXT,
              file_size INTEGER,
              sha256 TEXT,
              updated_at TEXT,
              state TEXT NOT NULL,
              status TEXT,
              current_stage TEXT,
              stage_progress REAL,
              identifiers_json BLOB NOT NULL,
              PRIMARY KEY(connection_id, remote_book_id, format),
              FOREIGN KEY(connection_id, remote_book_id)
                REFERENCES remote_book(connection_id, remote_book_id) ON DELETE CASCADE
            );

            CREATE TABLE edition_remote_link (
              id TEXT PRIMARY KEY NOT NULL,
              edition_id TEXT NOT NULL REFERENCES library_edition(id) ON DELETE CASCADE,
              provider_id TEXT NOT NULL,
              connection_id TEXT NOT NULL REFERENCES remote_connection(id) ON DELETE RESTRICT,
              remote_book_id TEXT NOT NULL,
              state TEXT NOT NULL,
              evidence TEXT NOT NULL,
              revision INTEGER NOT NULL,
              linked_at REAL NOT NULL,
              last_observed_at REAL,
              remote_title TEXT,
              remote_authors_json BLOB NOT NULL
            );

            CREATE UNIQUE INDEX unique_active_edition_connection
              ON edition_remote_link(edition_id, connection_id)
              WHERE state != 'unlinked';
            CREATE UNIQUE INDEX unique_active_remote_connection
              ON edition_remote_link(connection_id, remote_book_id)
              WHERE state != 'unlinked';

            CREATE TABLE remote_match_decision (
              id TEXT PRIMARY KEY NOT NULL,
              edition_id TEXT NOT NULL REFERENCES library_edition(id) ON DELETE CASCADE,
              connection_id TEXT NOT NULL REFERENCES remote_connection(id) ON DELETE RESTRICT,
              remote_book_id TEXT NOT NULL,
              decision TEXT NOT NULL,
              created_at REAL NOT NULL,
              UNIQUE(edition_id, connection_id, remote_book_id, decision)
            );

            CREATE TABLE delivery_receipt (
              id TEXT PRIMARY KEY NOT NULL,
              link_id TEXT NOT NULL REFERENCES edition_remote_link(id) ON DELETE CASCADE,
              format TEXT NOT NULL,
              local_sha256 TEXT NOT NULL,
              remote_asset_id TEXT,
              remote_size INTEGER,
              remote_fingerprint TEXT,
              remote_sha256 TEXT,
              observed_at REAL NOT NULL,
              UNIQUE(link_id, format)
            );

            CREATE TABLE identifier_assertion (
              id TEXT PRIMARY KEY NOT NULL,
              edition_id TEXT REFERENCES library_edition(id) ON DELETE CASCADE,
              connection_id TEXT,
              remote_book_id TEXT,
              scope TEXT NOT NULL,
              kind TEXT,
              value TEXT NOT NULL,
              disposition TEXT NOT NULL,
              source TEXT NOT NULL,
              note TEXT,
              created_at REAL NOT NULL
            );

            CREATE TABLE provenance_assertion (
              id TEXT PRIMARY KEY NOT NULL,
              connection_id TEXT NOT NULL REFERENCES remote_connection(id) ON DELETE RESTRICT,
              remote_book_id TEXT NOT NULL,
              remote_asset_id TEXT NOT NULL,
              remote_sha256 TEXT,
              provenance TEXT NOT NULL,
              coherence TEXT NOT NULL,
              aligned_audio_asset_id TEXT,
              aligned_audio_sha256 TEXT,
              source TEXT NOT NULL,
              created_at REAL NOT NULL
            );

            CREATE TABLE remote_operation (
              id TEXT PRIMARY KEY NOT NULL,
              connection_id TEXT NOT NULL REFERENCES remote_connection(id) ON DELETE RESTRICT,
              remote_book_id TEXT NOT NULL,
              kind TEXT NOT NULL,
              status TEXT NOT NULL,
              expected_snapshot_json BLOB,
              started_at REAL NOT NULL,
              updated_at REAL NOT NULL,
              error TEXT
            );

            CREATE TABLE library_audit_event (
              id TEXT PRIMARY KEY NOT NULL,
              occurred_at REAL NOT NULL,
              kind TEXT NOT NULL,
              edition_id TEXT,
              connection_id TEXT,
              remote_book_id TEXT,
              detail_json BLOB
            );

            CREATE INDEX remote_book_generation
              ON remote_book(connection_id, generation);
            CREATE INDEX remote_asset_identity
              ON remote_asset(connection_id, asset_id);
            CREATE INDEX local_product_digest ON local_product(sha256);
            CREATE INDEX audit_edition_time ON library_audit_event(edition_id, occurred_at);
          """)
    }
    migrator.registerMigration("library-v2-readaloud-quality") { database in
      try database.execute(
        sql: """
            CREATE TABLE readaloud_audit_run (
              id TEXT PRIMARY KEY NOT NULL,
              subject_kind TEXT NOT NULL,
              local_product_id TEXT REFERENCES local_product(id) ON DELETE CASCADE,
              connection_id TEXT REFERENCES remote_connection(id) ON DELETE RESTRICT,
              remote_book_id TEXT,
              remote_asset_id TEXT,
              standalone_path TEXT,
              artifact_sha256 TEXT,
              reference_sha256 TEXT,
              analyzer_identity TEXT NOT NULL,
              policy_version INTEGER NOT NULL,
              mode TEXT NOT NULL,
              lifecycle TEXT NOT NULL,
              progress REAL NOT NULL,
              progress_message TEXT,
              verdict TEXT,
              evidence_adequacy TEXT,
              model_identity TEXT,
              tool_identity TEXT,
              metrics_json BLOB,
              report_json BLOB,
              started_at REAL NOT NULL,
              updated_at REAL NOT NULL,
              completed_at REAL,
              error TEXT,
              CHECK(progress >= 0 AND progress <= 1),
              CHECK(
                (subject_kind = 'local' AND local_product_id IS NOT NULL
                  AND connection_id IS NULL AND remote_book_id IS NULL
                  AND remote_asset_id IS NULL AND standalone_path IS NULL)
                OR
                (subject_kind = 'remote' AND local_product_id IS NULL
                  AND connection_id IS NOT NULL AND remote_book_id IS NOT NULL
                  AND remote_asset_id IS NOT NULL AND standalone_path IS NULL)
                OR
                (subject_kind = 'standalone' AND local_product_id IS NULL
                  AND connection_id IS NULL AND remote_book_id IS NULL
                  AND remote_asset_id IS NULL AND standalone_path IS NOT NULL)
              )
            );

            CREATE TABLE readaloud_audit_finding (
              id TEXT PRIMARY KEY NOT NULL,
              run_id TEXT NOT NULL REFERENCES readaloud_audit_run(id) ON DELETE CASCADE,
              ordinal INTEGER NOT NULL,
              dimension TEXT NOT NULL,
              code TEXT NOT NULL,
              verdict TEXT NOT NULL,
              confidence TEXT NOT NULL,
              summary TEXT NOT NULL,
              evidence_json BLOB,
              UNIQUE(run_id, ordinal)
            );

            CREATE INDEX readaloud_audit_local_time
              ON readaloud_audit_run(local_product_id, started_at DESC);
            CREATE INDEX readaloud_audit_remote_time
              ON readaloud_audit_run(connection_id, remote_book_id, remote_asset_id, started_at DESC);
            CREATE INDEX readaloud_audit_verdict_time
              ON readaloud_audit_run(verdict, started_at DESC);
          """)
    }
    // A download may be served a representation Storyteller generates for the
    // request (a multi-file audiobook is zipped on demand), so what was
    // delivered is recorded apart from the source asset it came from, and an
    // asset that offers no comparable source hash is remembered so the
    // expensive probe is not repeated.
    migrator.registerMigration("library-v3-receipt-representation") { database in
      for column in [
        "served_size INTEGER", "served_sha256 TEXT", "served_content_type TEXT",
        "source_hash_unavailable INTEGER",
      ] {
        try database.execute(sql: "ALTER TABLE delivery_receipt ADD COLUMN \(column)")
      }
    }
    return migrator
  }
}

package enum LibraryStoreError: Error, LocalizedError, Equatable {
  case corruptDatabase(String)
  case invalidRecord(String)
  case conflict(String)
  case notFound(String)
  case migrationFailed(String)

  package var errorDescription: String? {
    switch self {
    case .corruptDatabase(let value): "Library database is corrupt: \(value)"
    case .invalidRecord(let value): "Invalid library record: \(value)"
    case .conflict(let value): "Library conflict: \(value)"
    case .notFound(let value): "Library item not found: \(value)"
    case .migrationFailed(let value): "Library migration failed: \(value)"
    }
  }
}

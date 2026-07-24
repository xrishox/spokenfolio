import AudiobookKit
import BookJobKit
import EPUBKit
import Foundation
import LibraryKit

/// Imports a local EPUB into the managed catalog — the one authority behind
/// the web "Import Books…" upload and the desktop open-panel import, so both
/// surfaces stage, digest, and catalog identically.
enum LibraryImportService {
  struct Imported: Sendable {
    let catalogID: UUID
    let title: String
  }

  /// Digest-verifies, parses, and catalogs one EPUB. The file at `url` is
  /// staged into the managed layout; the caller keeps ownership of the
  /// original (temporary uploads are cleaned up by the caller).
  @discardableResult
  static func importEPUB(at url: URL) async throws -> Imported {
    let imported = try await Task.detached {
      let sha256 = try BookFileDigest.sha256(url)
      let size = try BookFileDigest.size(url)
      let publication = try EPUBImporter().load(url: url)
      let plan = try AudiobookPlanner.plan(publication: publication)
      return (sha256, size, plan.metadata)
    }.value
    let settingsStore = StudioSettingsStore(url: AppPaths.studioSettingsURL)
    let processedDirectory = (try await settingsStore.load())
      .resolvedProcessedDirectory(home: FileManager.default.homeDirectoryForCurrentUser)
    let catalogStore = BookCatalogStore(root: AppPaths.bookCatalogRoot)
    let record = try await BookProcessRequestBuilder.resolveCatalog(
      store: catalogStore, sourceURL: url,
      sourceSHA256: imported.0, sourceSize: imported.1,
      title: imported.2.title, author: imported.2.author,
      language: imported.2.language, publisher: imported.2.publisher,
      publicationDate: imported.2.date, identifiers: imported.2.identifiers,
      outputDirectory: processedDirectory)
    return Imported(catalogID: record.id, title: record.metadata.title)
  }
}

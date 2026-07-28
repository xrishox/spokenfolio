import BookJobKit
import Foundation

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
    let settingsStore = StudioSettingsStore(url: AppPaths.studioSettingsURL)
    let processedDirectory = (try await settingsStore.load())
      .resolvedProcessedDirectory(home: FileManager.default.homeDirectoryForCurrentUser)
    let catalogStore = BookCatalogStore(root: AppPaths.bookCatalogRoot)
    let record = try await BookProcessRequestBuilder.resolveCatalog(
      store: catalogStore, sourceURL: url, outputDirectory: processedDirectory)
    return Imported(catalogID: record.id, title: record.metadata.title)
  }
}

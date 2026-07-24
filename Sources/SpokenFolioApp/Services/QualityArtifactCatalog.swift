import Foundation
import LibraryKit
import ReadAloudKit
import StorytellerKit

/// Stateless assembly of quality artifacts (one per concrete ReadAloud:
/// local product, Storyteller asset, or standalone file) with their audit
/// histories — the GUI model's reload logic, shared with the web API.
enum QualityArtifactCatalog {
  struct Artifact: Sendable {
    let id: String
    let target: LibraryReadAloudAuditTarget
    let title: String
    let author: String?
    let source: String
    let artifactSHA256: String?
    let referenceSHA256: String?
    let history: [LibraryReadAloudAuditRun]

    var activeRun: LibraryReadAloudAuditRun? {
      history.first { [.running, .queued].contains($0.lifecycle) }
    }

    var latestResult: LibraryReadAloudAuditRun? {
      history.first { run in
        guard run.lifecycle == .completed,
          run.analyzerIdentity == "readaloud-quality-v1",
          run.policyVersion == ReadAloudQualityAuditor.policyVersion
        else { return false }
        if let artifactSHA256, run.artifactSHA256 != artifactSHA256 { return false }
        if let referenceSHA256, run.referenceSHA256 != referenceSHA256 { return false }
        return true
      } ?? history.first { [.failed, .cancelled].contains($0.lifecycle) }
    }

    var presentedRun: LibraryReadAloudAuditRun? { activeRun ?? latestResult }
  }

  static func assemble(
    store: LibraryStore, connections: [StorytellerConnection]
  ) throws -> [Artifact] {
    let loaded = try store.readAloudAudits()
    let editions = try store.scanEditions().editions
    var titles: [LibraryReadAloudAuditTarget: String] = [:]
    var metadata: [LibraryReadAloudAuditTarget: (String, String?, String, String?, String?)] = [:]
    for edition in editions {
      for product in edition.products where product.kind == .readAloudEPUB {
        let target = LibraryReadAloudAuditTarget.localProduct(product.id)
        titles[target] = edition.metadata.title
        metadata[target] = (
          edition.metadata.title, edition.metadata.author, "Local", product.sha256,
          edition.source.sha256)
      }
    }
    let connectionIDs = Set(connections.map(\.id)).union(loaded.compactMap { run -> UUID? in
      if case .remote(let connectionID, _, _) = run.target { return connectionID }
      return nil
    })
    for connectionID in connectionIDs {
      let books = try store.remoteBooks(connectionID: connectionID)
      let connectionName = connections.first(where: { $0.id == connectionID })?.displayName
        ?? "Storyteller"
      for book in books {
        guard let asset = book.asset(.readaloud), asset.state != .missing else { continue }
        let target = LibraryReadAloudAuditTarget.remote(
          connectionID: connectionID, bookID: book.remoteBookID, assetID: asset.assetID)
        titles[target] = book.title
        metadata[target] = (
          book.title, book.authors.joined(separator: ", "), connectionName, asset.sha256, nil)
      }
      let bookTitles = Dictionary(uniqueKeysWithValues: books.map { ($0.remoteBookID, $0.title) })
      for run in loaded {
        guard case .remote(let id, let bookID, _) = run.target, id == connectionID,
          let bookTitle = bookTitles[bookID]
        else { continue }
        titles[run.target] = bookTitle
      }
    }
    for run in loaded {
      if case .standalone(let path) = run.target {
        let title = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        titles[run.target] = title
        metadata[run.target] = (title, nil, "Local file", nil, nil)
      } else if metadata[run.target] == nil {
        let fallback: String
        switch run.target {
        case .localProduct(let id): fallback = "Local ReadAloud \(id.uuidString.prefix(8))"
        case .remote(_, let bookID, _): fallback = "Storyteller book \(bookID.uuidString.prefix(8))"
        case .standalone(let path):
          fallback = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        }
        let source: String
        switch run.target {
        case .localProduct: source = "Local"
        case .standalone: source = "Local file"
        case .remote(let connectionID, _, _):
          source = connections.first(where: { $0.id == connectionID })?.displayName
            ?? "Storyteller"
        }
        metadata[run.target] = (titles[run.target] ?? fallback, nil, source, nil, nil)
      }
    }
    let histories = Dictionary(grouping: loaded, by: \.target).mapValues { values in
      values.sorted {
        if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
        return $0.id.uuidString < $1.id.uuidString
      }
    }
    return metadata.map { target, value in
      Artifact(
        id: artifactID(target), target: target, title: value.0,
        author: value.1?.isEmpty == true ? nil : value.1, source: value.2,
        artifactSHA256: value.3, referenceSHA256: value.4,
        history: histories[target] ?? [])
    }.sorted {
      let result = $0.title.localizedStandardCompare($1.title)
      if result != .orderedSame { return result == .orderedAscending }
      return $0.source.localizedStandardCompare($1.source) == .orderedAscending
    }
  }

  static func artifactID(_ target: LibraryReadAloudAuditTarget) -> String {
    switch target {
    case .localProduct(let id): return "local:\(id.uuidString.lowercased())"
    case .remote(let connectionID, let bookID, let assetID):
      return "remote:\(connectionID.uuidString.lowercased()):\(bookID.uuidString.lowercased()):\(assetID.uuidString.lowercased())"
    case .standalone(let path): return "file:\(path)"
    }
  }
}

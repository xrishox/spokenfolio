import Foundation

package struct StorytellerRemoteSnapshot: Codable, Sendable, Equatable {
  package var bookID: UUID
  package var assets: [StorytellerFormat: StorytellerAsset]
  package init(book: StorytellerBook) {
    bookID = book.uuid
    assets = Dictionary(
      uniqueKeysWithValues: StorytellerFormat.allCases.compactMap { format in
        book.asset(format).map { (format, $0) }
      })
  }
}

package enum StorytellerSyncDecision: Sendable, Equatable {
  case create(UUID)
  case fillMissing(UUID, Set<StorytellerFormat>)
  case alreadyComplete(UUID)
  case conflict([UUID], String)
}

package enum StorytellerConflictPlanner {
  package static func decide(
    targetID: UUID, requested: Set<StorytellerFormat>, books: [StorytellerBook],
    expectedSnapshot: StorytellerRemoteSnapshot?, normalizedIdentifiers: Set<String>,
    normalizedTitle: String, normalizedAuthor: String?
  ) -> StorytellerSyncDecision {
    if let target = books.first(where: { $0.uuid == targetID }) {
      let current = StorytellerRemoteSnapshot(book: target)
      if let expectedSnapshot, expectedSnapshot != current {
        return .conflict(
          [target.uuid], "the mapped remote book changed since the last successful delivery")
      }
      let missing = requested.filter { target.asset($0) == nil }
      return missing.isEmpty ? .alreadyComplete(target.uuid) : .fillMissing(target.uuid, missing)
    }
    let usableIdentifiers = normalizedIdentifiers.filter { !$0.isEmpty }
    let identifierMatches = books.filter { book in
      !usableIdentifiers.isEmpty
        && !usableIdentifiers.isDisjoint(
          with: Set(book.identifiers.compactMap { $0.effectiveValue.map(normalize) }))
    }
    if !identifierMatches.isEmpty {
      return .conflict(identifierMatches.map(\.uuid), "an existing book has a matching identifier")
    }
    let titleMatches = books.filter { book in
      normalize(book.title) == normalizedTitle
        && (normalizedAuthor == nil
          || book.authors.contains { normalize($0.name) == normalizedAuthor })
    }
    if !titleMatches.isEmpty {
      return .conflict(titleMatches.map(\.uuid), "an existing book has the same title and author")
    }
    return .create(targetID)
  }

  package static func normalize(_ value: String) -> String {
    value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      .components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
      .lowercased()
  }
}

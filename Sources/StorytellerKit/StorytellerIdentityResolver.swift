import Foundation
import PublicationKit

package struct StorytellerLocalProductIdentity: Sendable, Equatable {
  package var format: StorytellerFormat
  package var size: UInt64
  package var sha256: String
  package init(format: StorytellerFormat, size: UInt64, sha256: String) {
    self.format = format
    self.size = size
    self.sha256 = sha256
  }
}

package struct StorytellerLocalPublicationIdentity: Sendable, Equatable {
  package var title: String
  package var author: String?
  package var identifiers: [PublicationIdentifier]
  package var products: [StorytellerLocalProductIdentity]
  package var excludedBookIDs: Set<UUID>

  package init(
    title: String, author: String?, identifiers: [PublicationIdentifier],
    products: [StorytellerLocalProductIdentity], excludedBookIDs: Set<UUID> = []
  ) {
    self.title = title
    self.author = author
    self.identifiers = identifiers
    self.products = products
    self.excludedBookIDs = excludedBookIDs
  }
}

package struct StorytellerMatchCandidate: Sendable, Equatable, Identifiable {
  package enum Reason: String, Sendable { case exactHash, identifier, exactMetadata, similarMetadata }
  package var book: StorytellerBook
  package var reasons: Set<Reason>
  package var id: UUID { book.uuid }

  package init(book: StorytellerBook, reasons: Set<Reason>) {
    self.book = book
    self.reasons = reasons
  }
}

package enum StorytellerIdentityResolution: Sendable, Equatable {
  package enum Evidence: String, Sendable { case exactAssetHash, validatedIdentifier }
  case linked(UUID)
  case automatic(UUID, Evidence)
  case review([StorytellerMatchCandidate])
  case create
}

package actor StorytellerIdentityResolver {
  private let client: StorytellerClient

  package init(client: StorytellerClient) { self.client = client }

  package func resolve(
    local: StorytellerLocalPublicationIdentity, linkedBookID: UUID? = nil
  ) async throws -> StorytellerIdentityResolution {
    let books = try await client.books()
    if let linkedBookID, books.contains(where: { $0.uuid == linkedBookID }) {
      return .linked(linkedBookID)
    }
    let eligible = books.filter { !local.excludedBookIDs.contains($0.uuid) }
    var reasons: [UUID: Set<StorytellerMatchCandidate.Reason>] = [:]

    hashProbe: for product in local.products {
      for book in eligible where book.asset(product.format)?.fileSize == product.size {
        do {
          if try await client.assetHash(
            bookID: book.uuid, format: product.format, expectedSize: product.size)
            == product.sha256
          {
            reasons[book.uuid, default: []].insert(.exactHash)
          }
        } catch StorytellerAPIError.invalidResponse {
          // Exact-hash discovery is an optional optimization available on
          // newer Storyteller servers. Continue with validated identifiers
          // and reviewable metadata on older versions instead of making the
          // whole connection unusable.
          break hashProbe
        }
      }
    }

    let localIdentifiers = CanonicalPublicationIdentifier.local(local.identifiers)
    if !localIdentifiers.isEmpty {
      for book in eligible
      where !localIdentifiers.isDisjoint(
        with: CanonicalPublicationIdentifier.remote(book.identifiers))
      {
        reasons[book.uuid, default: []].insert(.identifier)
      }
    }

    let normalizedTitle = StorytellerConflictPlanner.normalize(local.title)
    let normalizedAuthor = local.author.map(StorytellerConflictPlanner.normalize)
    for book in eligible {
      let title = StorytellerConflictPlanner.normalize(book.title)
      let authorMatches = normalizedAuthor.map { author in
        book.authors.contains { StorytellerConflictPlanner.normalize($0.name) == author }
      } ?? true
      if title == normalizedTitle, authorMatches {
        reasons[book.uuid, default: []].insert(.exactMetadata)
      } else if authorMatches, Self.titleSimilarity(local.title, book.title) >= 0.80 {
        reasons[book.uuid, default: []].insert(.similarMetadata)
      }
    }

    let hashIDs = Set(reasons.compactMap { $0.value.contains(.exactHash) ? $0.key : nil })
    let identifierIDs = Set(reasons.compactMap { $0.value.contains(.identifier) ? $0.key : nil })
    if hashIDs.count == 1, let id = hashIDs.first,
      identifierIDs.isEmpty || identifierIDs == [id]
    {
      return .automatic(id, .exactAssetHash)
    }
    // A strong identifier is excellent review evidence, but not sufficient for
    // an automatic edition merge: the same work-level ISBN is routinely copied
    // across materially different ebook and audiobook editions.

    let candidates = eligible.compactMap { book -> StorytellerMatchCandidate? in
      guard let values = reasons[book.uuid], !values.isEmpty else { return nil }
      return StorytellerMatchCandidate(book: book, reasons: values)
    }.sorted { left, right in
      Self.rank(left.reasons) > Self.rank(right.reasons)
    }
    return candidates.isEmpty ? .create : .review(candidates)
  }

  private static func rank(_ reasons: Set<StorytellerMatchCandidate.Reason>) -> Int {
    if reasons.contains(.exactHash) { return 4 }
    if reasons.contains(.identifier) { return 3 }
    if reasons.contains(.exactMetadata) { return 2 }
    return 1
  }

  private static func titleSimilarity(_ left: String, _ right: String) -> Double {
    func tokens(_ value: String) -> Set<String> {
      Set(
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
          .lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
    }
    let a = tokens(left)
    let b = tokens(right)
    guard !a.isEmpty, !b.isEmpty else { return 0 }
    return 2 * Double(a.intersection(b).count) / Double(a.count + b.count)
  }
}

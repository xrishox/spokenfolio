import Foundation

/// Bounded lookups against Audible's public catalog API — the online
/// repository for ASIN discovery: search by title/author to find a book's
/// ASIN, and resolve an ASIN to the title it identifies so the UI can show
/// both side by side. HTTPS-only, 15-second deadline, 1 MiB response cap,
/// and nothing is persisted here — saving an ASIN stays an explicit user
/// action through the identifier endpoint.
enum AsinCatalog {
  struct Candidate: Sendable {
    let asin: String
    let title: String
    let authors: [String]
    let narrators: [String]
  }

  private static let host = "api.audible.com"
  private static let maximumResponseBytes = 1 << 20

  static func search(title: String, author: String?) async throws -> [Candidate] {
    var components = URLComponents()
    components.scheme = "https"
    components.host = host
    components.path = "/1.0/catalog/products"
    var query = [
      URLQueryItem(name: "title", value: title),
      URLQueryItem(name: "num_results", value: "10"),
      URLQueryItem(name: "products_sort_by", value: "Relevance"),
      URLQueryItem(name: "response_groups", value: "contributors,product_desc,product_attrs"),
    ]
    if let author, !author.isEmpty {
      query.append(URLQueryItem(name: "author", value: author))
    }
    components.queryItems = query
    guard let url = components.url else { return [] }
    let payload = try await fetch(url)
    let decoded = try JSONDecoder().decode(SearchResponse.self, from: payload)
    return decoded.products.compactMap(Candidate.init)
  }

  static func resolve(asin: String) async throws -> Candidate? {
    let normalized = asin.uppercased().filter { $0.isLetter || $0.isNumber }
    guard normalized.count == 10 else { return nil }
    var components = URLComponents()
    components.scheme = "https"
    components.host = host
    components.path = "/1.0/catalog/products/\(normalized)"
    components.queryItems = [
      URLQueryItem(name: "response_groups", value: "contributors,product_desc,product_attrs")
    ]
    guard let url = components.url else { return nil }
    let payload = try await fetch(url)
    let decoded = try JSONDecoder().decode(ResolveResponse.self, from: payload)
    return decoded.product.flatMap(Candidate.init)
  }

  private static func fetch(_ url: URL) async throws -> Data {
    var request = URLRequest(url: url)
    request.timeoutInterval = 15
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
    else {
      throw URLError(.badServerResponse)
    }
    guard data.count <= maximumResponseBytes else {
      throw URLError(.dataLengthExceedsMaximum)
    }
    return data
  }

  fileprivate struct SearchResponse: Decodable {
    let products: [Product]
  }

  fileprivate struct ResolveResponse: Decodable {
    let product: Product?
  }

  fileprivate struct Product: Decodable {
    struct Person: Decodable {
      let name: String
    }
    let asin: String
    let title: String?
    let authors: [Person]?
    let narrators: [Person]?
  }
}

extension AsinCatalog.Candidate {
  fileprivate init?(_ product: AsinCatalog.Product) {
    guard let title = product.title, !title.isEmpty else { return nil }
    asin = product.asin
    self.title = title
    authors = product.authors?.map(\.name) ?? []
    narrators = product.narrators?.map(\.name) ?? []
  }
}

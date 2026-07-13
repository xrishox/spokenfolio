import Foundation

package enum StorytellerHTTP {
  package static func makeSession() -> URLSession {
    URLSession(configuration: .ephemeral, delegate: NoRedirectDelegate(), delegateQueue: nil)
  }

  private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
      _ session: URLSession, task: URLSessionTask,
      willPerformHTTPRedirection response: HTTPURLResponse,
      newRequest request: URLRequest,
      completionHandler: @escaping (URLRequest?) -> Void
    ) {
      // Authorization is deliberately never forwarded through redirects.
      completionHandler(nil)
    }
  }
}

package actor StorytellerClient {
  package typealias TokenProvider = @Sendable () async throws -> String

  package let origin: URL
  private let session: URLSession
  private let tokenProvider: TokenProvider
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  package init(origin: URL, session: URLSession? = nil, tokenProvider: @escaping TokenProvider)
    throws
  {
    guard let scheme = origin.scheme?.lowercased(), ["http", "https"].contains(scheme),
      origin.host != nil, origin.user == nil, origin.password == nil,
      origin.path.isEmpty || origin.path == "/"
    else { throw StorytellerAPIError.invalidServerURL }
    var components = URLComponents(url: origin, resolvingAgainstBaseURL: false)!
    components.path = ""
    components.query = nil
    components.fragment = nil
    self.origin = components.url!
    self.session = session ?? StorytellerHTTP.makeSession()
    self.tokenProvider = tokenProvider
  }

  package func currentUser() async throws -> StorytellerUser {
    try await get("/api/v2/user")
  }

  package func books() async throws -> [StorytellerBook] {
    try await get("/api/v2/books")
  }

  package func book(_ id: UUID) async throws -> StorytellerBook? {
    do {
      return try await get("/api/v2/books/\(id.uuidString.lowercased())")
    } catch StorytellerAPIError.rejected(let status, _) where status == 404 { return nil }
  }

  /// Storyteller computes the complete asset SHA-256 before returning a
  /// ranged response. Requiring a one-byte 206 prevents an older or proxying
  /// server from turning identity discovery into a full audiobook download.
  package func assetHash(
    bookID: UUID, format: StorytellerFormat, expectedSize: UInt64
  ) async throws -> String? {
    guard let candidate = URL(
      string: "/api/v2/books/\(bookID.uuidString.lowercased())/files?format=\(format.rawValue)",
      relativeTo: origin)
    else { throw StorytellerAPIError.invalidResponse("invalid asset URL") }
    let requestURL = try validateSameOrigin(candidate)
    let token = try await tokenProvider()
    guard !token.isEmpty else { throw StorytellerAPIError.authenticationRequired }
    var request = URLRequest(url: requestURL)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
    let (bytes, response) = try await session.bytes(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw StorytellerAPIError.invalidResponse("non-HTTP response")
    }
    if http.statusCode == 401 { throw StorytellerAPIError.authenticationRequired }
    if [403, 404].contains(http.statusCode) { return nil }
    guard http.statusCode == 206,
      http.value(forHTTPHeaderField: "Content-Length") == "1",
      http.value(forHTTPHeaderField: "Content-Range")?.hasSuffix("/\(expectedSize)") == true
    else {
      throw StorytellerAPIError.invalidResponse(
        "Storyteller did not honor the one-byte identity probe")
    }
    var received = 0
    for try await _ in bytes {
      received += 1
      if received == 1 { break }
    }
    guard received == 1,
      let hash = http.value(forHTTPHeaderField: "X-Storyteller-Hash")?.lowercased(),
      hash.count == 64, hash.allSatisfy(\.isHexDigit)
    else { return nil }
    return hash
  }

  package func deleteBooks(_ ids: [UUID], preventReImport: Bool = true) async throws {
    let body = try encoder.encode(
      DeleteBooksRequest(
        books: ids.map { $0.uuidString.lowercased() }, preventReImport: preventReImport))
    _ = try await authenticatedRequest(
      path: "/api/v2/books", method: "DELETE", body: body,
      headers: ["Content-Type": "application/json"])
  }

  package func requirePermissions(create: Bool, update: Bool) async throws -> StorytellerUser {
    let user = try await currentUser()
    guard user.permissions.bookList else { throw StorytellerAPIError.missingPermission("bookList") }
    if create, !user.permissions.bookCreate {
      throw StorytellerAPIError.missingPermission("bookCreate")
    }
    if update, !user.permissions.bookUpdate {
      throw StorytellerAPIError.missingPermission("bookUpdate")
    }
    return user
  }

  package func maxUploadChunkSize() async throws -> Int? {
    struct Response: Decodable { let maxUploadChunkSize: Int? }
    do {
      return try await get("/api/v2/settings/maxUploadChunkSize", as: Response.self)
        .maxUploadChunkSize
    } catch StorytellerAPIError.rejected(let status, _) where status == 403 {
      // Storyteller protects this setting with bookCreate even though an update-only account can
      // legitimately upload a missing asset. The normal 8 MiB client default remains valid.
      return nil
    }
  }

  package func authenticatedRequest(
    path: String, method: String = "GET", body: Data? = nil,
    headers: [String: String] = [:]
  ) async throws -> (Data, HTTPURLResponse) {
    guard let candidate = URL(string: path, relativeTo: origin) else {
      throw StorytellerAPIError.invalidResponse("invalid request path")
    }
    let requestURL = try validateSameOrigin(candidate)
    let token = try await tokenProvider()
    guard !token.isEmpty else { throw StorytellerAPIError.authenticationRequired }
    var request = URLRequest(url: requestURL)
    request.httpMethod = method
    request.httpBody = body
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw StorytellerAPIError.invalidResponse("non-HTTP response")
    }
    if http.statusCode == 401 { throw StorytellerAPIError.authenticationRequired }
    guard (200..<300).contains(http.statusCode) else {
      throw StorytellerAPIError.rejected(
        status: http.statusCode,
        message: Self.errorMessage(data)
          ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
    }
    return (data, http)
  }

  package func token() async throws -> String {
    let value = try await tokenProvider()
    guard !value.isEmpty else { throw StorytellerAPIError.authenticationRequired }
    return value
  }

  private func get<T: Decodable>(_ path: String, as: T.Type = T.self) async throws -> T {
    let (data, _) = try await authenticatedRequest(path: path)
    do { return try decoder.decode(T.self, from: data) } catch {
      throw StorytellerAPIError.invalidResponse(error.localizedDescription)
    }
  }

  private struct DeleteBooksRequest: Encodable {
    let books: [String]
    let preventReImport: Bool
  }

  package func url(_ path: String) -> URL {
    URL(string: path, relativeTo: origin)!.absoluteURL
  }

  package func validateSameOrigin(_ value: URL) throws -> URL {
    let absolute = value.absoluteURL
    guard absolute.scheme?.lowercased() == origin.scheme?.lowercased(),
      absolute.host?.lowercased() == origin.host?.lowercased(),
      (absolute.port ?? Self.defaultPort(absolute.scheme))
        == (origin.port ?? Self.defaultPort(origin.scheme))
    else { throw StorytellerAPIError.crossOriginLocation(absolute) }
    return absolute
  }

  private static func defaultPort(_ scheme: String?) -> Int? {
    scheme == "https" ? 443 : scheme == "http" ? 80 : nil
  }

  package static func errorMessage(_ data: Data) -> String? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return String(data: data.prefix(500), encoding: .utf8)
    }
    return object["error_description"] as? String
      ?? object["message"] as? String
      ?? object["error"] as? String
  }
}

package enum StorytellerDeviceAuth {
  package static func start(origin: URL, session: URLSession? = nil) async throws
    -> StorytellerDeviceAuthorization
  {
    let session = session ?? StorytellerHTTP.makeSession()
    let client = try StorytellerClient(origin: origin, session: session, tokenProvider: { "" })
    var request = URLRequest(url: await client.url("/api/v2/device/start"))
    request.httpMethod = "POST"
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
      throw StorytellerAPIError.invalidResponse("device authorization could not start")
    }
    do {
      let authorization = try JSONDecoder().decode(StorytellerDeviceAuthorization.self, from: data)
      return try authorization.rebased(to: client.origin)
    } catch let error as StorytellerAPIError {
      throw error
    } catch {
      throw StorytellerAPIError.invalidResponse(error.localizedDescription)
    }
  }

  package static func pollToken(
    origin: URL, deviceCode: String, session: URLSession? = nil
  ) async throws -> StorytellerToken? {
    let session = session ?? StorytellerHTTP.makeSession()
    let client = try StorytellerClient(origin: origin, session: session, tokenProvider: { "" })
    var request = URLRequest(url: await client.url("/api/v2/device/token"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: ["device_code": deviceCode])
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw StorytellerAPIError.invalidResponse("non-HTTP device response")
    }
    if http.statusCode == 200 {
      do { return try JSONDecoder().decode(StorytellerToken.self, from: data) } catch {
        throw StorytellerAPIError.invalidResponse(error.localizedDescription)
      }
    }
    let code = StorytellerClient.errorMessage(data)
    if let code, ["authorization_pending", "slow_down"].contains(code) { return nil }
    throw StorytellerAPIError.rejected(
      status: http.statusCode, message: code ?? "device authorization failed")
  }
}

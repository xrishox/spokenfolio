import CryptoKit
import Foundation

package enum StorytellerHTTP {
  /// The default bounds tolerate slow TUS chunk transfers (the request
  /// timeout is an idle timer, reset while bytes flow) while still failing
  /// within a session instead of URLSession's seven-day resource default.
  package static func makeSession(
    requestTimeout: TimeInterval = 30, resourceTimeout: TimeInterval = 3600
  ) -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = requestTimeout
    configuration.timeoutIntervalForResource = resourceTimeout
    return URLSession(
      configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
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

  package static func boundedData(
    session: URLSession, request: URLRequest, maximumBytes: Int = 16 << 20
  ) async throws -> (Data, URLResponse) {
    guard maximumBytes > 0 else {
      throw StorytellerAPIError.invalidResponse("response limit must be positive")
    }
    let (data, response) = try await session.data(for: request)
    if response.expectedContentLength > Int64(maximumBytes) {
      throw StorytellerAPIError.invalidResponse("Storyteller response exceeds the allowed size")
    }
    guard data.count <= maximumBytes else {
      throw StorytellerAPIError.invalidResponse("Storyteller response exceeds the allowed size")
    }
    return (data, response)
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
    guard var components = URLComponents(url: origin, resolvingAgainstBaseURL: false) else {
      throw StorytellerAPIError.invalidServerURL
    }
    components.path = ""
    components.query = nil
    components.fragment = nil
    guard let normalizedOrigin = components.url else {
      throw StorytellerAPIError.invalidServerURL
    }
    self.origin = normalizedOrigin
    self.session = session ?? StorytellerHTTP.makeSession()
    self.tokenProvider = tokenProvider
  }

  package func currentUser() async throws -> StorytellerUser {
    try await get("/api/v2/user")
  }

  package func books() async throws -> [StorytellerBook] {
    try await get("/api/v2/books")
  }

  package func identifierTypes() async throws -> [StorytellerIdentifierType] {
    try await get("/api/v2/identifiers")
  }

  package func bookIdentifiers(_ id: UUID) async throws -> [StorytellerBookIdentifier] {
    let (data, _) = try await authenticatedRequest(
      path: "/api/v2/books/\(id.uuidString.lowercased())/identifiers")
    do {
      return try decoder.decode([StorytellerBookIdentifier].self, from: data)
    } catch { throw StorytellerAPIError.invalidResponse(error.localizedDescription) }
  }

  package func replaceBookIdentifiers(
    _ id: UUID, identifiers: [StorytellerBookIdentifier]
  ) async throws {
    struct Relation: Encodable {
      var identifierTypeUuid: UUID
      var value: String
      var ebookUuid: UUID?
      var audiobookUuid: UUID?
      var readaloudUuid: UUID?
    }
    struct Body: Encodable { var identifiers: [Relation] }
    let body = try encoder.encode(
      Body(
        identifiers: identifiers.map {
          Relation(
            identifierTypeUuid: $0.identifierTypeUuid, value: $0.value,
            ebookUuid: $0.ebookUuid, audiobookUuid: $0.audiobookUuid,
            readaloudUuid: $0.readaloudUuid)
        }))
    // Stock Storyteller's identifier PUT is last-write-wins (204, no
    // preconditions); callers read-compare-write as a best effort.
    _ = try await authenticatedRequest(
      path: "/api/v2/books/\(id.uuidString.lowercased())/identifiers",
      method: "PUT", body: body,
      headers: ["Content-Type": "application/json"])
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
    guard
      let candidate = URL(
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

  /// Convenience wrapper for the readable EPUB source used by local backfill.
  package func downloadEbook(
    bookID: UUID, to destination: URL, maximumBytes: UInt64 = 1 << 30
  ) async throws {
    _ = try await downloadAsset(
      bookID: bookID, format: .ebook, to: destination, maximumBytes: maximumBytes)
  }

  /// Downloads one asset file. All three formats are downloadable: the Book
  /// Library holds everything for a book, including human-narrated
  /// audiobooks and readalouds, as explicit user-initiated mirrors.
  package func downloadAsset(
    bookID: UUID, format: StorytellerFormat, to destination: URL,
    maximumBytes: UInt64 = 4 << 30
  ) async throws -> StorytellerDownloadedAsset {
    let path = "/api/v2/books/\(bookID.uuidString.lowercased())/files?format=\(format.rawValue)"
    guard let candidate = URL(string: path, relativeTo: origin) else {
      throw StorytellerAPIError.invalidResponse("invalid asset download URL")
    }
    let requestURL = try validateSameOrigin(candidate)
    let token = try await token()
    var request = URLRequest(url: requestURL)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    // The download task consults the session-level NoRedirectDelegate, so
    // redirects stay blocked; never pass a per-task delegate here, which
    // would shadow the session delegate.
    let (downloadedFile, response) = try await session.download(for: request)
    let fileManager = FileManager.default
    defer { try? fileManager.removeItem(at: downloadedFile) }
    guard let http = response as? HTTPURLResponse else {
      throw StorytellerAPIError.invalidResponse("non-HTTP asset response")
    }
    if http.statusCode == 401 { throw StorytellerAPIError.authenticationRequired }
    guard http.statusCode == 200 else {
      throw StorytellerAPIError.rejected(
        status: http.statusCode,
        message: HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
    }
    if let length = http.value(forHTTPHeaderField: "Content-Length").flatMap(UInt64.init),
      length == 0 || length > maximumBytes
    {
      throw StorytellerAPIError.invalidResponse("asset download size is outside the allowed range")
    }
    guard
      let received = (try fileManager.attributesOfItem(atPath: downloadedFile.path)[.size]
        as? NSNumber)?.uint64Value
    else {
      throw StorytellerAPIError.invalidResponse("could not measure the asset download")
    }
    guard received > 0 else {
      throw StorytellerAPIError.invalidResponse("asset download was empty")
    }
    guard received <= maximumBytes else {
      throw StorytellerAPIError.invalidResponse("asset download exceeded the allowed size")
    }
    // When the server advertises the full-asset hash, verify the bytes on
    // disk before committing them: a connection dropped mid-stream (which
    // URLSession.download can surface as success when Content-Length is
    // absent) must never be cataloged as a verified asset.
    let serverHash = http.value(forHTTPHeaderField: "X-Storyteller-Hash")?.lowercased()
    let validServerHash =
      serverHash.flatMap { $0.count == 64 && $0.allSatisfy(\.isHexDigit) ? $0 : nil }
    if let validServerHash {
      let actual = try Self.fileSHA256(downloadedFile)
      guard actual == validServerHash else {
        throw StorytellerAPIError.invalidResponse(
          "the downloaded asset did not match the server hash (truncated or altered)")
      }
    }
    try fileManager.createDirectory(
      at: destination.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let temporary = destination.deletingLastPathComponent().appendingPathComponent(
      ".\(destination.lastPathComponent).\(UUID().uuidString).download")
    defer { try? fileManager.removeItem(at: temporary) }
    try fileManager.moveItem(at: downloadedFile, to: temporary)
    if fileManager.fileExists(atPath: destination.path) {
      _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
    } else {
      try fileManager.moveItem(at: temporary, to: destination)
    }
    return StorytellerDownloadedAsset(
      byteCount: received,
      serverSHA256: validServerHash,
      etag: http.value(forHTTPHeaderField: "ETag"))
  }

  /// Streaming SHA-256 of a file, bounded in memory (64 KiB reads).
  private static func fileSHA256(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while true {
      let chunk = try handle.read(upToCount: 64 << 10) ?? Data()
      if chunk.isEmpty { break }
      hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  /// Storyteller's processing report is useful evidence but is not trusted as
  /// proof of identity until its retained transcriptions are bound to members
  /// in the downloaded ReadAloud package.
  package func alignmentReport(bookID: UUID, maximumBytes: Int = 16 << 20) async throws -> Data? {
    do {
      let (data, _) = try await authenticatedRequest(
        path: "/api/v2/reports/\(bookID.uuidString.lowercased())",
        maximumBytes: maximumBytes)
      if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        object.count == 1, object["message"] != nil
      {
        return nil
      }
      return data
    } catch StorytellerAPIError.rejected(let status, _) where status == 404 { return nil }
  }

  package func retainedTranscription(
    bookID: UUID, filename: String, maximumBytes: Int = 16 << 20
  ) async throws -> Data? {
    guard !filename.isEmpty, filename.utf8.count <= 1_024,
      filename != ".", filename != "..", !filename.contains("/"), !filename.contains("\\")
    else { throw StorytellerAPIError.invalidResponse("invalid transcription filename") }
    let encoded = filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
    guard !encoded.isEmpty else {
      throw StorytellerAPIError.invalidResponse("invalid transcription filename")
    }
    do {
      let (data, _) = try await authenticatedRequest(
        path: "/api/v2/reports/\(bookID.uuidString.lowercased())/transcriptions/\(encoded)",
        maximumBytes: maximumBytes)
      return data
    } catch StorytellerAPIError.rejected(let status, _) where status == 404 { return nil }
  }

  package func deleteBooks(_ ids: [UUID], preventReImport: Bool = true) async throws {
    let body = try encoder.encode(
      DeleteBooksRequest(
        books: ids.map { $0.uuidString.lowercased() }, preventReImport: preventReImport))
    _ = try await authenticatedRequest(
      path: "/api/v2/books", method: "DELETE", body: body,
      headers: ["Content-Type": "application/json"])
  }

  package func startReadAloudProcessing(bookID: UUID) async throws {
    _ = try await authenticatedRequest(
      path: "/api/v2/books/\(bookID.uuidString.lowercased())/process",
      method: "POST")
  }

  package func requirePermissions(
    create: Bool, update: Bool, delete: Bool = false
  ) async throws -> StorytellerUser {
    let user = try await currentUser()
    guard user.permissions.bookList else { throw StorytellerAPIError.missingPermission("bookList") }
    if create, !user.permissions.bookCreate {
      throw StorytellerAPIError.missingPermission("bookCreate")
    }
    if update, !user.permissions.bookUpdate {
      throw StorytellerAPIError.missingPermission("bookUpdate")
    }
    if delete, !user.permissions.bookDelete {
      throw StorytellerAPIError.missingPermission("bookDelete")
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
    headers: [String: String] = [:], maximumBytes: Int = 16 << 20
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
    let (data, response) = try await StorytellerHTTP.boundedData(
      session: session, request: request, maximumBytes: maximumBytes)
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
    let (data, response) = try await StorytellerHTTP.boundedData(
      session: session, request: request, maximumBytes: 1 << 20)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
      throw StorytellerAPIError.invalidResponse(
        "the server at \(origin.absoluteString) did not offer Storyteller device authorization")
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
    let (data, response) = try await StorytellerHTTP.boundedData(
      session: session, request: request, maximumBytes: 1 << 20)
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

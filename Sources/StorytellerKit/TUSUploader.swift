import Foundation

package struct TUSUploadState: Codable, Sendable, Equatable {
  package var uploadURL: URL?
  package var offset: UInt64
  package var length: UInt64
  package var sourceSize: UInt64
  package var sourceModificationDate: Date?
  package init(
    uploadURL: URL? = nil, offset: UInt64 = 0, length: UInt64, sourceSize: UInt64,
    sourceModificationDate: Date?
  ) {
    self.uploadURL = uploadURL
    self.offset = offset
    self.length = length
    self.sourceSize = sourceSize
    self.sourceModificationDate = sourceModificationDate
  }
}

package actor StorytellerTUSUploader {
  private let client: StorytellerClient
  private let session: URLSession

  package init(client: StorytellerClient, session: URLSession? = nil) {
    self.client = client
    self.session = session ?? StorytellerHTTP.makeSession()
  }

  package func upload(
    file: URL, endpoint: String, metadata: [String: String],
    state initial: TUSUploadState? = nil, chunkSize: Int = 8 << 20,
    onState: @escaping @Sendable (TUSUploadState) async throws -> Void,
    onProgress: @escaping @Sendable (Double) -> Void = { _ in }
  ) async throws -> TUSUploadState {
    guard chunkSize > 0 else {
      throw StorytellerAPIError.invalidResponse("TUS chunk size must be positive")
    }
    let values = try file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
    let size = UInt64(values.fileSize ?? 0)
    guard size > 0 else { throw StorytellerAPIError.invalidResponse("upload source is empty") }
    var state =
      initial
      ?? TUSUploadState(
        length: size, sourceSize: size, sourceModificationDate: values.contentModificationDate)
    guard state.length == size, state.sourceSize == size, state.offset <= size,
      state.sourceModificationDate == values.contentModificationDate
    else {
      throw StorytellerAPIError.fileChanged
    }
    if let uploadURL = state.uploadURL {
      let safeUploadURL = try await client.validateSameOrigin(uploadURL)
      state.uploadURL = safeUploadURL
      if let remote = try await head(safeUploadURL) {
        guard remote <= size else {
          throw StorytellerAPIError.invalidResponse("TUS server offset exceeds upload length")
        }
        state.offset = remote
      } else {
        state.uploadURL = nil
        state.offset = 0
      }
    }
    if state.uploadURL == nil {
      state.uploadURL = try await create(endpoint: endpoint, length: size, metadata: metadata)
      state.offset = 0
      try await onState(state)
    }
    guard let uploadURL = state.uploadURL else {
      throw StorytellerAPIError.invalidResponse("missing upload URL")
    }

    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    try handle.seek(toOffset: state.offset)
    while state.offset < size {
      try Task.checkCancellation()
      let remaining = size - state.offset
      guard let data = try handle.read(upToCount: min(chunkSize, Int(remaining))), !data.isEmpty
      else {
        throw StorytellerAPIError.fileChanged
      }
      var request = URLRequest(url: uploadURL)
      request.httpMethod = "PATCH"
      request.httpBody = data
      request.setValue("1.0.0", forHTTPHeaderField: "Tus-Resumable")
      request.setValue("application/offset+octet-stream", forHTTPHeaderField: "Content-Type")
      request.setValue(String(state.offset), forHTTPHeaderField: "Upload-Offset")
      let token = try await bearerToken()
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
      let (responseData, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse else {
        throw StorytellerAPIError.invalidResponse("non-HTTP TUS response")
      }
      if http.statusCode == 409 {
        throw StorytellerAPIError.uploadOffsetConflict(
          expected: state.offset,
          actual: http.value(forHTTPHeaderField: "Upload-Offset").flatMap(UInt64.init))
      }
      guard (200..<300).contains(http.statusCode),
        let next = http.value(forHTTPHeaderField: "Upload-Offset").flatMap(UInt64.init),
        next == state.offset + UInt64(data.count)
      else {
        throw StorytellerAPIError.rejected(
          status: http.statusCode,
          message: StorytellerClient.errorMessage(responseData) ?? "TUS PATCH failed")
      }
      state.offset = next
      try await onState(state)
      onProgress(Double(next) / Double(size))
    }
    return state
  }

  private func create(endpoint: String, length: UInt64, metadata: [String: String]) async throws
    -> URL
  {
    let value = metadata.sorted(by: { $0.key < $1.key }).map { key, value in
      "\(key) \(Data(value.utf8).base64EncodedString())"
    }.joined(separator: ",")
    let (_, response) = try await client.authenticatedRequest(
      path: endpoint, method: "POST",
      headers: [
        "Tus-Resumable": "1.0.0", "Upload-Length": String(length),
        "Upload-Metadata": value, "Content-Length": "0",
      ])
    guard response.statusCode == 201, let location = response.value(forHTTPHeaderField: "Location"),
      let candidate = URL(string: location, relativeTo: response.url)
    else { throw StorytellerAPIError.invalidResponse("TUS create omitted Location") }
    return try await client.validateSameOrigin(candidate)
  }

  private func head(_ uploadURL: URL) async throws -> UInt64? {
    var request = URLRequest(url: uploadURL)
    request.httpMethod = "HEAD"
    request.setValue("1.0.0", forHTTPHeaderField: "Tus-Resumable")
    request.setValue("Bearer \(try await bearerToken())", forHTTPHeaderField: "Authorization")
    let (_, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else { return nil }
    if http.statusCode == 404 || http.statusCode == 410 { return nil }
    guard (200..<300).contains(http.statusCode) else {
      throw StorytellerAPIError.rejected(status: http.statusCode, message: "TUS HEAD failed")
    }
    guard let offset = http.value(forHTTPHeaderField: "Upload-Offset").flatMap(UInt64.init) else {
      throw StorytellerAPIError.invalidResponse("TUS HEAD omitted Upload-Offset")
    }
    return offset
  }

  // The client intentionally owns token retrieval. A zero-byte authenticated
  // request is avoided because it could mutate an upload endpoint.
  private func bearerToken() async throws -> String {
    try await client.token()
  }
}

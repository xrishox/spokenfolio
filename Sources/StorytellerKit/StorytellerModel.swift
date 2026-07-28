import Foundation

package enum StorytellerFormat: String, Codable, Sendable, CaseIterable {
  case ebook, audiobook, readaloud
}

package struct StorytellerPermissions: Codable, Sendable, Equatable {
  package var bookCreate: Bool
  package var bookDelete: Bool
  package var bookDownload: Bool
  package var bookList: Bool
  package var bookProcess: Bool
  package var bookRead: Bool
  package var bookUpdate: Bool
}

package struct StorytellerUser: Codable, Sendable, Equatable {
  package var id: UUID
  package var name: String?
  package var username: String?
  package var email: String?
  package var permissions: StorytellerPermissions
}

package struct StorytellerCreator: Codable, Sendable, Equatable {
  package var name: String
}

package struct StorytellerIdentifier: Codable, Sendable, Equatable {
  package var uuid: UUID?
  package var name: String?
  package var kind: String?
  package var value: String?
  package var identifier: String?

  package var effectiveValue: String? { value ?? identifier }
}

package struct StorytellerIdentifierType: Codable, Sendable, Equatable, Identifiable {
  package var uuid: UUID
  package var kind: String?
  package var name: String
  package var id: UUID { uuid }
}

package struct StorytellerBookIdentifier: Codable, Sendable, Equatable {
  package var uuid: UUID?
  package var identifierTypeUuid: UUID
  package var value: String
  package var ebookUuid: UUID?
  package var audiobookUuid: UUID?
  package var readaloudUuid: UUID?
  package var identifierTypeName: String?

  package init(
    uuid: UUID? = nil, identifierTypeUuid: UUID, value: String,
    ebookUuid: UUID? = nil, audiobookUuid: UUID? = nil,
    readaloudUuid: UUID? = nil, identifierTypeName: String? = nil
  ) {
    self.uuid = uuid
    self.identifierTypeUuid = identifierTypeUuid
    self.value = value
    self.ebookUuid = ebookUuid
    self.audiobookUuid = audiobookUuid
    self.readaloudUuid = readaloudUuid
    self.identifierTypeName = identifierTypeName
  }
}

package struct StorytellerAsset: Codable, Sendable, Equatable {
  package var uuid: UUID
  package var filepath: String?
  package var fingerprint: String?
  package var fileSize: UInt64?
  package var missing: Bool?
  package var updatedAt: String?
  package var status: String?
  package var currentStage: String?
  package var stageProgress: Double?
  package var identifiers: [StorytellerIdentifier]

  package init(
    uuid: UUID, filepath: String? = nil, fingerprint: String? = nil,
    fileSize: UInt64? = nil, missing: Bool? = nil, updatedAt: String? = nil,
    status: String? = nil, currentStage: String? = nil,
    stageProgress: Double? = nil, identifiers: [StorytellerIdentifier] = []
  ) {
    self.uuid = uuid
    self.filepath = filepath
    self.fingerprint = fingerprint
    self.fileSize = fileSize
    self.missing = missing
    self.updatedAt = updatedAt
    self.status = status
    self.currentStage = currentStage
    self.stageProgress = stageProgress
    self.identifiers = identifiers
  }

  package var isAvailable: Bool {
    guard missing != true,
      let filepath = filepath?.trimmingCharacters(in: .whitespacesAndNewlines),
      !filepath.isEmpty,
      let fileSize, fileSize > 0
    else { return false }
    return true
  }

  private enum CodingKeys: String, CodingKey {
    case uuid, filepath, fingerprint, fileSize, missing, updatedAt, status, currentStage
    case stageProgress, identifiers
  }

  package init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    uuid = try values.decode(UUID.self, forKey: .uuid)
    filepath = try values.decodeIfPresent(String.self, forKey: .filepath)
    fingerprint = try values.decodeIfPresent(String.self, forKey: .fingerprint)
    fileSize = try values.decodeIfPresent(UInt64.self, forKey: .fileSize)
    missing = try values.decodeIfPresent(Bool.self, forKey: .missing)
    updatedAt = try values.decodeIfPresent(String.self, forKey: .updatedAt)
    status = try values.decodeIfPresent(String.self, forKey: .status)
    currentStage = try values.decodeIfPresent(String.self, forKey: .currentStage)
    stageProgress = try values.decodeIfPresent(Double.self, forKey: .stageProgress)
    identifiers =
      try values.decodeIfPresent([StorytellerIdentifier].self, forKey: .identifiers) ?? []
  }
}

package struct StorytellerBook: Codable, Sendable, Equatable {
  package var uuid: UUID
  package var title: String
  package var subtitle: String?
  package var authors: [StorytellerCreator]
  package var narrators: [StorytellerCreator]
  package var identifiers: [StorytellerIdentifier]
  package var ebook: StorytellerAsset?
  package var audiobook: StorytellerAsset?
  package var readaloud: StorytellerAsset?
  package var createdAt: String?
  package var updatedAt: String?

  package init(
    uuid: UUID, title: String, subtitle: String? = nil,
    authors: [StorytellerCreator] = [], narrators: [StorytellerCreator] = [],
    identifiers: [StorytellerIdentifier] = [], ebook: StorytellerAsset? = nil,
    audiobook: StorytellerAsset? = nil, readaloud: StorytellerAsset? = nil,
    createdAt: String? = nil, updatedAt: String? = nil
  ) {
    self.uuid = uuid
    self.title = title
    self.subtitle = subtitle
    self.authors = authors
    self.narrators = narrators
    self.identifiers = identifiers
    self.ebook = ebook
    self.audiobook = audiobook
    self.readaloud = readaloud
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  private enum CodingKeys: String, CodingKey {
    case uuid, title, subtitle, authors, narrators, identifiers, ebook, audiobook, readaloud
    case createdAt, updatedAt
  }

  package init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    uuid = try values.decode(UUID.self, forKey: .uuid)
    title = try values.decode(String.self, forKey: .title)
    subtitle = try values.decodeIfPresent(String.self, forKey: .subtitle)
    authors = try values.decodeIfPresent([StorytellerCreator].self, forKey: .authors) ?? []
    narrators = try values.decodeIfPresent([StorytellerCreator].self, forKey: .narrators) ?? []
    identifiers =
      try values.decodeIfPresent([StorytellerIdentifier].self, forKey: .identifiers) ?? []
    ebook = try values.decodeIfPresent(StorytellerAsset.self, forKey: .ebook)
    audiobook = try values.decodeIfPresent(StorytellerAsset.self, forKey: .audiobook)
    readaloud = try values.decodeIfPresent(StorytellerAsset.self, forKey: .readaloud)
    createdAt = try values.decodeIfPresent(String.self, forKey: .createdAt)
    updatedAt = try values.decodeIfPresent(String.self, forKey: .updatedAt)
  }

  package func asset(_ format: StorytellerFormat) -> StorytellerAsset? {
    switch format {
    case .ebook: ebook?.isAvailable == true ? ebook : nil
    case .audiobook: audiobook?.isAvailable == true ? audiobook : nil
    case .readaloud: readaloud?.isAvailable == true ? readaloud : nil
    }
  }
}

package struct StorytellerDeviceAuthorization: Codable, Sendable, Equatable {
  package var deviceCode: String
  package var userCode: String
  package var verificationURI: URL
  package var verificationURIComplete: URL
  package var expiresIn: Int
  package var interval: Int
  package var qrSVGURL: URL

  enum CodingKeys: String, CodingKey {
    case deviceCode = "device_code"
    case userCode = "user_code"
    case verificationURI = "verification_uri"
    case verificationURIComplete = "verification_uri_complete"
    case expiresIn = "expires_in"
    case interval
    case qrSVGURL = "qr_svg_url"
  }

  /// Storyteller constructs these links from its configured public URL, which
  /// is frequently an internal Docker bind address. The origin entered by the
  /// user is the authority; only server-supplied paths, queries, and fragments
  /// are retained.
  package func rebased(to origin: URL) throws -> Self {
    func rebase(_ value: URL) throws -> URL {
      guard var link = URLComponents(url: value, resolvingAgainstBaseURL: false),
        let authority = URLComponents(url: origin, resolvingAgainstBaseURL: false),
        let scheme = authority.scheme, let host = authority.host
      else {
        throw StorytellerAPIError.invalidResponse("invalid device authorization URL")
      }
      link.scheme = scheme
      link.host = host
      link.port = authority.port
      link.user = nil
      link.password = nil
      guard let result = link.url else {
        throw StorytellerAPIError.invalidResponse("invalid device authorization URL")
      }
      return result
    }

    var result = self
    result.verificationURI = try rebase(verificationURI)
    result.verificationURIComplete = try rebase(verificationURIComplete)
    result.qrSVGURL = try rebase(qrSVGURL)
    return result
  }
}

package struct StorytellerToken: Codable, Sendable, Equatable {
  package var accessToken: String
  package var tokenType: String
  package var interval: Int?

  enum CodingKeys: String, CodingKey {
    case accessToken = "access_token"
    case tokenType = "token_type"
    case interval
  }
}

package enum StorytellerAPIError: Error, LocalizedError, Equatable {
  case invalidServerURL
  case authenticationRequired
  case missingPermission(String)
  case rejected(status: Int, message: String)
  case invalidResponse(String)
  case crossOriginLocation(URL)
  case uploadOffsetConflict(expected: UInt64, actual: UInt64?)
  case fileChanged
  case conflict(String)

  package var errorDescription: String? {
    switch self {
    case .invalidServerURL: "Storyteller server URL must be an HTTP or HTTPS origin."
    case .authenticationRequired: "Storyteller authorization is required."
    case .missingPermission(let value): "Storyteller account lacks permission: \(value)."
    case .rejected(let status, let message): "Storyteller returned HTTP \(status): \(message)"
    case .invalidResponse(let value): "Invalid Storyteller response: \(value)."
    case .crossOriginLocation(let url): "Storyteller returned an unsafe upload location: \(url)."
    case .uploadOffsetConflict(let expected, let actual):
      "Storyteller upload offset conflict (expected \(expected), got \(actual.map(String.init) ?? "none"))."
    case .fileChanged: "The upload source changed while it was being transferred."
    case .conflict(let value): "Storyteller conflict: \(value)."
    }
  }
}

/// What `GET /api/v2/books/:id/files` actually served, kept separate from the
/// source asset it was derived from. Stock Storyteller answers that route
/// either with the stored file or with a representation it generates per
/// request — a multi-file audiobook is zipped on demand — so the served
/// bytes, size, and hash may describe something that does not exist on the
/// server's disk. Callers must never attribute these to the source asset.
package struct StorytellerDownloadedAsset: Sendable, Equatable {
  /// Where the bytes were committed, after any extension chosen from the
  /// representation.
  package var url: URL
  /// Bytes actually delivered.
  package var byteCount: UInt64
  /// SHA-256 of the delivered representation, always computed locally.
  package var sha256: String
  /// The server's `X-Storyteller-Hash` when present; equal to `sha256` for a
  /// directly served file, and the hash of a generated archive otherwise.
  package var serverSHA256: String?
  package var contentType: String?
  /// The filename from `Content-Disposition`, sanitized to a bare component.
  package var suggestedFilename: String?
  package var etag: String?

  package init(
    url: URL, byteCount: UInt64, sha256: String, serverSHA256: String? = nil,
    contentType: String? = nil, suggestedFilename: String? = nil, etag: String? = nil
  ) {
    self.url = url
    self.byteCount = byteCount
    self.sha256 = sha256
    self.serverSHA256 = serverSHA256
    self.contentType = contentType
    self.suggestedFilename = suggestedFilename
    self.etag = etag
  }

  /// True when Storyteller built this representation for the request rather
  /// than serving a stored file — today, a multi-file audiobook zipped on
  /// demand. Such bytes are not the source asset and must never be cataloged
  /// as one (an `.m4b` that is really a ZIP is a corrupt product).
  package var isGeneratedArchive: Bool {
    let type = (contentType ?? "").lowercased()
    if type.hasPrefix("application/zip") || type.hasPrefix("application/audiobook+zip") {
      return true
    }
    return Self.fileExtension(of: suggestedFilename) == "zip"
  }

  /// The extension to store this representation under: the served filename
  /// first, then the MIME type, then the caller's fallback. The remote source
  /// path is only a fallback because it names the source, not what was served.
  package func storedExtension(fallback: String) -> String {
    if let named = Self.fileExtension(of: suggestedFilename), !named.isEmpty { return named }
    if let mapped = Self.extensionForContentType(contentType) { return mapped }
    return fallback
  }

  static func fileExtension(of filename: String?) -> String? {
    guard let filename else { return nil }
    let component = (filename as NSString).lastPathComponent
    let ext = (component as NSString).pathExtension.lowercased()
    guard !ext.isEmpty, ext.count <= 5, ext.allSatisfy({ $0.isLetter || $0.isNumber }) else {
      return nil
    }
    return ext
  }

  static func extensionForContentType(_ contentType: String?) -> String? {
    guard let contentType else { return nil }
    let type = contentType.split(separator: ";").first.map(String.init)?
      .trimmingCharacters(in: .whitespaces).lowercased() ?? ""
    switch type {
    case "application/epub+zip": return "epub"
    case "application/zip", "application/audiobook+zip": return "zip"
    case "audio/mp4", "audio/m4b", "audio/x-m4b": return "m4b"
    case "audio/mpeg": return "mp3"
    case "audio/ogg", "audio/opus": return "opus"
    case "audio/aac": return "aac"
    case "audio/flac", "audio/x-flac": return "flac"
    case "audio/wav", "audio/x-wav": return "wav"
    default: return nil
    }
  }
}

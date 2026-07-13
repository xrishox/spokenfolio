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
  package var name: String
  package var username: String
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

package struct StorytellerAsset: Codable, Sendable, Equatable {
  package var uuid: UUID
  package var filepath: String?
  package var fingerprint: String?
  package var fileSize: UInt64?
  package var updatedAt: String?
  package var status: String?
  package var currentStage: String?
  package var stageProgress: Double?
}

package struct StorytellerBook: Codable, Sendable, Equatable {
  package var uuid: UUID
  package var title: String
  package var subtitle: String?
  package var authors: [StorytellerCreator]
  package var identifiers: [StorytellerIdentifier]
  package var ebook: StorytellerAsset?
  package var audiobook: StorytellerAsset?
  package var readaloud: StorytellerAsset?

  package func asset(_ format: StorytellerFormat) -> StorytellerAsset? {
    switch format {
    case .ebook: ebook
    case .audiobook: audiobook
    case .readaloud: readaloud
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

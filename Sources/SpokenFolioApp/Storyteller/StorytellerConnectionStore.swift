import Darwin
import Foundation
import Security
import StorytellerKit

struct StorytellerConnection: Codable, Sendable, Identifiable, Equatable {
  var id: UUID
  var origin: URL
  var displayName: String
  var username: String
  var permissions: StorytellerPermissions
  var connectedAt: Date
  var remoteUserID: UUID? = nil
}

actor StorytellerConnectionStore {
  static let shared = StorytellerConnectionStore()
  private let url = AppPaths.applicationSupportDirectory
    .appendingPathComponent("storyteller-connections.json")

  func connections() throws -> [StorytellerConnection] {
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    return try JSONDecoder().decode([StorytellerConnection].self, from: Data(contentsOf: url))
  }

  /// Saved metadata alone is not proof of a live session: Storyteller may
  /// invalidate device tokens after a server restore or restart.
  func authenticatedConnections() async -> [StorytellerConnection] {
    let saved = (try? connections()) ?? []
    var active: [StorytellerConnection] = []
    for connection in saved {
      do {
        let value = try token(connection.id)
        let client = try StorytellerClient(origin: connection.origin, tokenProvider: { value })
        _ = try await client.currentUser()
        active.append(connection)
      } catch {}
    }
    return active
  }

  func save(_ connection: StorytellerConnection, token: String) throws {
    var values = try connections()
    let previousToken = try? StorytellerCredentialStore.tokenForCurrentIdentity(
      connectionID: connection.id)
    let sameRemoteProfile: (StorytellerConnection) -> Bool = { value in
      value.id == connection.id
        || (value.origin == connection.origin && value.remoteUserID != nil
          && value.remoteUserID == connection.remoteUserID)
    }
    let replacedIDs = values.filter(sameRemoteProfile).map(\.id).filter { $0 != connection.id }
    values.removeAll(where: sameRemoteProfile)
    values.append(connection)
    do {
      try StorytellerCredentialStore.current.set(token: token, connectionID: connection.id)
      try persist(values)
    } catch {
      try? StorytellerCredentialStore.current.remove(connectionID: connection.id)
      if let previousToken {
        try? StorytellerCredentialStore.current.set(
          token: previousToken, connectionID: connection.id)
      }
      throw error
    }
    for id in replacedIDs {
      try? StorytellerCredentialStore.current.remove(connectionID: id)
      try? StorytellerCredentialStore.legacy.remove(connectionID: id)
    }
  }

  func remove(_ id: UUID) throws {
    var values = try connections()
    values.removeAll { $0.id == id }
    try persist(values)
    try StorytellerCredentialStore.current.remove(connectionID: id)
    try? StorytellerCredentialStore.legacy.remove(connectionID: id)
  }

  nonisolated func token(_ id: UUID) throws -> String {
    try StorytellerCredentialStore.tokenForCurrentIdentity(connectionID: id)
  }

  private func persist(_ values: [StorytellerConnection]) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let temporary = url.appendingPathExtension(UUID().uuidString)
    try encoder.encode(values).write(to: temporary, options: [.atomic])
    _ = chmod(temporary.path, 0o600)
    if FileManager.default.fileExists(atPath: url.path) {
      _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    } else {
      try FileManager.default.moveItem(at: temporary, to: url)
    }
  }
}

struct StorytellerCredentialStore: Sendable {
  static let current = StorytellerCredentialStore(service: AppIdentity.keychainService)
  static let legacy = StorytellerCredentialStore(service: AppIdentity.legacyKeychainService)
  let service: String

  /// The bundle rename changes the preferred Keychain service. Defer access
  /// until the normal visible app needs Storyteller, so macOS can present any
  /// access prompt. Never delete the legacy token until the new copy verifies.
  static func tokenForCurrentIdentity(connectionID: UUID) throws -> String {
    do { return try current.token(connectionID: connectionID) } catch let error as KeychainError {
      guard error.status == errSecItemNotFound else { throw error }
    }
    let token = try legacy.token(connectionID: connectionID)
    do {
      try current.set(token: token, connectionID: connectionID)
      guard try current.token(connectionID: connectionID) == token else {
        return token
      }
      try? legacy.remove(connectionID: connectionID)
    } catch {
      // The authorized legacy token remains usable. A later visible access
      // retries the copy without forcing the user to reconnect.
    }
    return token
  }

  func set(token: String, connectionID: UUID) throws {
    try remove(connectionID: connectionID)
    let status = SecItemAdd(
      [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: service,
        kSecAttrAccount: connectionID.uuidString.lowercased(),
        kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
        kSecValueData: Data(token.utf8),
      ] as CFDictionary, nil)
    guard status == errSecSuccess else { throw KeychainError(status) }
  }

  func token(connectionID: UUID) throws -> String {
    var result: CFTypeRef?
    let status = SecItemCopyMatching(
      [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: service,
        kSecAttrAccount: connectionID.uuidString.lowercased(),
        kSecReturnData: true,
        kSecMatchLimit: kSecMatchLimitOne,
      ] as CFDictionary, &result)
    guard status == errSecSuccess, let data = result as? Data,
      let value = String(data: data, encoding: .utf8)
    else { throw KeychainError(status) }
    return value
  }

  func tokenIfPresent(connectionID: UUID) throws -> String? {
    do { return try token(connectionID: connectionID) } catch let error as KeychainError {
      if error.status == errSecItemNotFound { return nil }
      throw error
    }
  }

  func remove(connectionID: UUID) throws {
    let status = SecItemDelete(
      [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: service,
        kSecAttrAccount: connectionID.uuidString.lowercased(),
      ] as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw KeychainError(status)
    }
  }

  struct KeychainError: Error, LocalizedError {
    let status: OSStatus
    init(_ status: OSStatus) { self.status = status }
    var errorDescription: String? {
      SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
    }
  }
}

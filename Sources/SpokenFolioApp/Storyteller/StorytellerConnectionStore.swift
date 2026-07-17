import Darwin
import BookJobKit
import Foundation
import LibraryKit
import Security
import StorytellerKit
import os

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
  private let legacyURL = AppPaths.applicationSupportDirectory
    .appendingPathComponent("storyteller-connections.json")
  private var libraryStore: LibraryStore?

  func connections() async throws -> [StorytellerConnection] {
    let library = try await store()
    return try library.connections().filter { $0.providerID == "storyteller" }.map { value in
      guard let permissionsData = value.permissionsData else {
        throw BookJobError.corruptState("Storyteller connection permissions are missing")
      }
      let permissions: StorytellerPermissions
      do {
        permissions = try JSONDecoder().decode(StorytellerPermissions.self, from: permissionsData)
      } catch {
        throw BookJobError.corruptState("Storyteller connection permissions are invalid")
      }
      return StorytellerConnection(
        id: value.id, origin: value.origin, displayName: value.displayName,
        username: value.username ?? "Storyteller user", permissions: permissions,
        connectedAt: value.connectedAt, remoteUserID: value.remoteUserID)
    }
  }

  /// Saved metadata alone is not proof of a live session: Storyteller may
  /// invalidate device tokens after a server restore or restart.
  func authenticatedConnections() async throws -> [StorytellerConnection] {
    let saved = try await connections()
    var active: [StorytellerConnection] = []
    for connection in saved {
      do {
        let value = try await token(connection.id)
        let client = try StorytellerClient(origin: connection.origin, tokenProvider: { value })
        _ = try await client.currentUser()
        active.append(connection)
      } catch {}
    }
    return active
  }

  func save(_ connection: StorytellerConnection, token: String) async throws {
    let library = try await store()
    let values = try await connections()
    let connectionID = connection.id
    let previousToken = try? await StorytellerCredentialStore.offPool {
      try StorytellerCredentialStore.tokenForCurrentIdentity(connectionID: connectionID)
    }
    let sameRemoteProfile: (StorytellerConnection) -> Bool = { value in
      value.id == connection.id
        || (value.origin == connection.origin && value.remoteUserID != nil
          && value.remoteUserID == connection.remoteUserID)
    }
    let replacedIDs = values.filter(sameRemoteProfile).map(\.id).filter { $0 != connection.id }
    do {
      try await StorytellerCredentialStore.offPool {
        try StorytellerCredentialStore.current.set(token: token, connectionID: connectionID)
      }
      try library.saveConnection(try Self.libraryConnection(connection))
    } catch {
      try? await StorytellerCredentialStore.offPool {
        try StorytellerCredentialStore.current.remove(connectionID: connectionID)
        if let previousToken {
          try StorytellerCredentialStore.current.set(
            token: previousToken, connectionID: connectionID)
        }
      }
      throw error
    }
    for id in replacedIDs {
      try library.disconnectConnection(id)
      try await StorytellerCredentialStore.offPool {
        try StorytellerCredentialStore.current.remove(connectionID: id)
        try? StorytellerCredentialStore.legacy.remove(connectionID: id)
      }
    }
  }

  func remove(_ id: UUID) async throws {
    let library = try await store()
    try library.disconnectConnection(id)
    try await StorytellerCredentialStore.offPool {
      try StorytellerCredentialStore.current.remove(connectionID: id)
      try? StorytellerCredentialStore.legacy.remove(connectionID: id)
    }
  }

  /// Keychain reads can block on a securityd authorization prompt; measured:
  /// a synchronous read from a Swift-concurrency thread starved the whole
  /// cooperative pool and wedged app shutdown. Always hop off-pool.
  nonisolated func token(_ id: UUID) async throws -> String {
    try await StorytellerCredentialStore.offPool {
      try StorytellerCredentialStore.tokenForCurrentIdentity(connectionID: id)
    }
  }

  private func store() async throws -> LibraryStore {
    if let libraryStore { return libraryStore }
    // BookCatalogStore owns the atomic legacy-catalog bootstrap. Trigger it
    // before opening the same database for connection metadata.
    _ = try await BookCatalogStore(
      root: AppPaths.bookCatalogRoot, databaseURL: AppPaths.libraryDatabaseURL).scan()
    let library = try LibraryStore(databaseURL: AppPaths.libraryDatabaseURL)
    try migrateLegacyConnections(into: library)
    libraryStore = library
    return library
  }

  private func migrateLegacyConnections(into library: LibraryStore) throws {
    guard FileManager.default.fileExists(atPath: legacyURL.path) else { return }
    let attributes = try legacyURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard attributes.isRegularFile == true, let size = attributes.fileSize, size <= 8 << 20 else {
      throw BookJobError.corruptState("legacy Storyteller connections file is not bounded")
    }
    let values = try JSONDecoder().decode(
      [StorytellerConnection].self, from: Data(contentsOf: legacyURL, options: [.mappedIfSafe]))
    for value in values { try library.saveConnection(try Self.libraryConnection(value)) }
    var backup = legacyURL.appendingPathExtension("migrated")
    if FileManager.default.fileExists(atPath: backup.path) {
      backup = legacyURL.appendingPathExtension("migrated-\(UUID().uuidString)")
    }
    try FileManager.default.moveItem(at: legacyURL, to: backup)
  }

  private static func libraryConnection(_ value: StorytellerConnection) throws
    -> LibraryConnection
  {
    LibraryConnection(
      id: value.id, origin: value.origin, displayName: value.displayName,
      username: value.username, remoteUserID: value.remoteUserID,
      permissionsData: try JSONEncoder().encode(value.permissions),
      connectedAt: value.connectedAt)
  }
}

struct StorytellerCredentialStore: Sendable {
  static let current = StorytellerCredentialStore(service: AppIdentity.keychainService)
  static let legacy = StorytellerCredentialStore(service: AppIdentity.legacyKeychainService)
  let service: String

  /// SecItem calls talk to securityd and block while an authorization prompt
  /// is pending. Measured failure: one such read on a cooperative-pool thread
  /// starved Swift concurrency and hung Cmd-Q indefinitely. Keychain work
  /// therefore runs on its own GCD queue, with a timeout long enough for a
  /// person to answer a real prompt but bounded so nothing waits forever.
  private static let keychainQueue = DispatchQueue(
    label: "\(AppIdentity.bundleIdentifier).keychain",
    qos: .userInitiated, attributes: .concurrent)

  static func offPool<T: Sendable>(
    timeout: Duration = .seconds(120),
    _ work: @escaping @Sendable () throws -> T
  ) async throws -> T {
    let resumed = OSAllocatedUnfairLock(
      initialState: nil as CheckedContinuation<T, Error>?)
    // Cancellation must release the awaiting task promptly (app shutdown
    // cancels these); the blocked keychain thread itself cannot be freed.
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        resumed.withLock { $0 = continuation }
        let resumeOnce: @Sendable (Result<T, Error>) -> Void = { result in
          let pending = resumed.withLock { value in
            let current = value
            value = nil
            return current
          }
          pending?.resume(with: result)
        }
        keychainQueue.async {
          resumeOnce(Result(catching: work))
        }
        let nanoseconds = timeout.components.seconds * 1_000_000_000
          + timeout.components.attoseconds / 1_000_000_000
        keychainQueue.asyncAfter(deadline: .now() + .nanoseconds(Int(nanoseconds))) {
          resumeOnce(.failure(KeychainTimeout()))
        }
      }
    } onCancel: {
      let pending = resumed.withLock { value in
        let current = value
        value = nil
        return current
      }
      pending?.resume(throwing: CancellationError())
    }
  }

  struct KeychainTimeout: Error, LocalizedError {
    var errorDescription: String? {
      "The Keychain did not respond. Approve any pending authorization prompt and try again."
    }
  }

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

import Foundation
import StorytellerKit

/// Server-driven Storyteller device-auth sessions for the web interface:
/// the browser starts a session, opens the verification URL itself, and
/// polls session state while this actor runs the token poll → currentUser →
/// save loop that the desktop connect flow performs.
actor DeviceAuthSessionStore {
  struct Session: Sendable {
    enum State: Sendable, Equatable {
      case pending
      case connected(connectionID: UUID, username: String)
      case expired
      case failed(String)
    }
    let id: UUID
    let userCode: String
    let verificationURL: String
    let expiresAt: Date
    var state: State = .pending
  }

  private var sessions: [UUID: Session] = [:]
  private var tasks: [UUID: Task<Void, Never>] = [:]

  func start(origin: String, replacingConnectionID: UUID?) async throws -> Session {
    guard let url = URL(string: origin),
      ["http", "https"].contains(url.scheme?.lowercased())
    else {
      throw StorytellerAPIError.conflict("Enter a valid HTTP or HTTPS Storyteller origin.")
    }
    // A wrong address must fail fast with a reason, not hold the connect
    // flow hostage to URLSession's default timeouts.
    let request: StorytellerDeviceAuthorization
    do {
      request = try await StorytellerDeviceAuth.start(
        origin: url,
        session: StorytellerHTTP.makeSession(requestTimeout: 10, resourceTimeout: 20))
    } catch let error as URLError {
      throw StorytellerAPIError.conflict(
        "Could not reach \(url.absoluteString): \(error.localizedDescription)")
    }
    let expiresAt = Date().addingTimeInterval(TimeInterval(request.expiresIn))
    let session = Session(
      id: UUID(), userCode: request.userCode,
      verificationURL: request.verificationURIComplete.absoluteString,
      expiresAt: expiresAt)
    sessions[session.id] = session
    tasks[session.id] = Task { [id = session.id] in
      await self.poll(
        id: id, origin: url, deviceCode: request.deviceCode,
        interval: request.interval, expiresAt: expiresAt,
        replacingConnectionID: replacingConnectionID)
    }
    return session
  }

  func session(_ id: UUID) -> Session? {
    sessions[id]
  }

  func cancel(_ id: UUID) {
    tasks[id]?.cancel()
    tasks[id] = nil
    sessions[id] = nil
  }

  private func setState(_ id: UUID, _ state: Session.State) {
    sessions[id]?.state = state
  }

  private func poll(
    id: UUID, origin: URL, deviceCode: String, interval: Int, expiresAt: Date,
    replacingConnectionID: UUID?
  ) async {
    do {
      var token: StorytellerToken?
      while Date() < expiresAt, token == nil {
        try Task.checkCancellation()
        try await Task.sleep(for: .seconds(max(1, interval)))
        token = try await StorytellerDeviceAuth.pollToken(
          origin: origin, deviceCode: deviceCode)
      }
      guard let token else {
        setState(id, .expired)
        return
      }
      let client = try StorytellerClient(
        origin: origin, tokenProvider: { token.accessToken })
      let user = try await client.currentUser()
      let username = user.username ?? user.name ?? "Storyteller user"
      let normalizedOrigin = await client.origin
      let store = StorytellerConnectionStore.shared
      let connections = try await store.connections()
      let existing = replacingConnectionID.flatMap { value in
        connections.first { $0.id == value }
      }
      if let existing, let previousUserID = existing.remoteUserID,
        previousUserID != user.id
      {
        throw StorytellerAPIError.conflict(
          "Reconnect was approved as a different Storyteller account. "
            + "Connect it separately instead.")
      }
      let reusable = existing ?? connections.first {
        $0.origin == normalizedOrigin
          && ($0.remoteUserID == user.id
            || ($0.remoteUserID == nil && $0.username == username))
      }
      let connection = StorytellerConnection(
        id: reusable?.id ?? UUID(), origin: normalizedOrigin,
        displayName: reusable?.displayName ?? origin.host ?? origin.absoluteString,
        username: username, permissions: user.permissions, connectedAt: Date(),
        remoteUserID: user.id)
      try await store.save(connection, token: token.accessToken)
      setState(id, .connected(connectionID: connection.id, username: username))
    } catch is CancellationError {
      // Session removed; nothing to record.
    } catch {
      setState(id, .failed(error.localizedDescription))
    }
  }
}

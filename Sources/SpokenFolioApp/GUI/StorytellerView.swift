import AppKit
import Observation
import StorytellerKit
import SwiftUI

@MainActor @Observable
final class StorytellerStudioModel {
  var origin = ""
  var connections: [StorytellerConnection] = []
  var books: [StorytellerBook] = []
  var selectedConnection: UUID?
  var status = ""
  var isBusy = false
  private let store = StorytellerConnectionStore.shared

  func reload() async {
    do {
      connections = try await store.connections()
      if !connections.contains(where: { $0.id == selectedConnection }) {
        selectedConnection = connections.first?.id
      }
      await loadBooks()
    } catch { status = error.localizedDescription }
  }

  func connect(replacing connectionID: UUID? = nil) async {
    guard !isBusy, let url = URL(string: origin) else { return }
    isBusy = true
    defer { isBusy = false }
    do {
      let authorization = try await StorytellerDeviceAuth.start(origin: url)
      status = "Enter code \(authorization.userCode) in Storyteller"
      NSWorkspace.shared.open(authorization.verificationURIComplete)
      let deadline = Date().addingTimeInterval(TimeInterval(authorization.expiresIn))
      var token: StorytellerToken?
      while Date() < deadline, token == nil {
        try await Task.sleep(for: .seconds(max(1, authorization.interval)))
        token = try await StorytellerDeviceAuth.pollToken(
          origin: url, deviceCode: authorization.deviceCode)
      }
      guard let token else { throw StorytellerAPIError.authenticationRequired }
      let client = try StorytellerClient(origin: url, tokenProvider: { token.accessToken })
      let user = try await client.currentUser()
      let normalizedOrigin = await client.origin
      let existing = connectionID.flatMap { id in connections.first { $0.id == id } }
      if let existing, let previousUserID = existing.remoteUserID, previousUserID != user.id {
        throw StorytellerAPIError.conflict(
          "Reconnect was approved as a different Storyteller account. Connect it separately instead.")
      }
      let reusable = existing ?? connections.first {
        $0.origin == normalizedOrigin
          && ($0.remoteUserID == user.id || ($0.remoteUserID == nil && $0.username == user.username))
      }
      let connection = StorytellerConnection(
        id: reusable?.id ?? UUID(), origin: normalizedOrigin,
        displayName: reusable?.displayName ?? url.host ?? url.absoluteString,
        username: user.username, permissions: user.permissions, connectedAt: Date(),
        remoteUserID: user.id)
      try await store.save(connection, token: token.accessToken)
      origin = ""
      status = "Connected as \(user.username)"
      await reload()
    } catch { status = error.localizedDescription }
  }

  func loadBooks() async {
    guard let connection = connections.first(where: { $0.id == selectedConnection }) else {
      books = []
      return
    }
    do {
      let token = try store.token(connection.id)
      let client = try StorytellerClient(origin: connection.origin, tokenProvider: { token })
      books = try await client.books()
      status = "\(books.count) books"
    } catch {
      books = []
      status =
        (error as? StorytellerAPIError) == .authenticationRequired
        ? "Session expired or was revoked. Reconnect this server."
        : error.localizedDescription
    }
  }

  func reconnect(_ id: UUID) async {
    guard let connection = connections.first(where: { $0.id == id }) else { return }
    origin = connection.origin.absoluteString
    await connect(replacing: id)
  }

  func remove(_ id: UUID) async {
    do {
      try await store.remove(id)
      selectedConnection = nil
      await reload()
    } catch { status = error.localizedDescription }
  }
}

struct StorytellerView: View {
  @Bindable var model: StorytellerStudioModel

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Storyteller").font(.title2.bold())
      HStack {
        TextField("https://storyteller.example", text: $model.origin)
        Button("Connect…") { Task { await model.connect() } }
          .disabled(model.isBusy || model.origin.isEmpty)
      }
      Text(
        "Authorization opens Storyteller's device approval page. Tokens are stored in the macOS Keychain."
      )
      .font(.caption).foregroundStyle(.secondary)
      Text("To send a completed book, open Library and click Send… beside it.")
        .font(.caption).foregroundStyle(.secondary)
      if !model.connections.isEmpty {
        HStack {
          Picker("Server", selection: $model.selectedConnection) {
            ForEach(model.connections) { connection in
              Text("\(connection.displayName) — \(connection.username)").tag(
                Optional(connection.id))
            }
          }.onChange(of: model.selectedConnection) { Task { await model.loadBooks() } }
          if let id = model.selectedConnection {
            Button("Reconnect…") { Task { await model.reconnect(id) } }.disabled(model.isBusy)
            Button("Disconnect") { Task { await model.remove(id) } }
          }
        }
      }
      if !model.status.isEmpty { Text(model.status).font(.callout).foregroundStyle(.secondary) }
      List(model.books, id: \.uuid) { book in
        HStack {
          VStack(alignment: .leading) {
            Text(book.title)
            Text(book.authors.map(\.name).joined(separator: ", "))
              .font(.caption).foregroundStyle(.secondary)
          }
          Spacer()
          ForEach(StorytellerFormat.allCases, id: \.self) { format in
            if book.asset(format) != nil {
              Text(format.rawValue).font(.caption).padding(4).background(.quaternary, in: Capsule())
            }
          }
        }
      }
    }.padding(20).task { await model.reload() }
  }
}

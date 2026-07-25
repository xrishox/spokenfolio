import AppKit
import Observation
import StorytellerKit
import SwiftUI

struct StorytellerAuthorizationState: Equatable {
  let userCode: String
  let approvalURL: URL
  let expiresAt: Date
}

struct StorytellerConnectionHealth: Equatable {
  enum State { case unknown, checking, connected, readOnly, authenticationRequired, unavailable }
  var state: State
  var detail: String
}

@MainActor @Observable
final class StorytellerStudioModel {
  var origin = ""
  private(set) var connections: [StorytellerConnection] = []
  var selectedConnection: UUID?
  private(set) var status = ""
  private(set) var isBusy = false
  private(set) var authorization: StorytellerAuthorizationState?
  private(set) var health: [UUID: StorytellerConnectionHealth] = [:]
  private(set) var completionSerial = 0
  private(set) var replacingConnectionID: UUID?

  @ObservationIgnored private let store = StorytellerConnectionStore.shared
  @ObservationIgnored private var authorizationTask: Task<Void, Never>?

  deinit { authorizationTask?.cancel() }

  func reload() async {
    do {
      connections = try await store.connections()
      if let selectedConnection,
        !connections.contains(where: { $0.id == selectedConnection })
      {
        self.selectedConnection = nil
      }
    } catch { status = error.localizedDescription }
  }

  func beginAdd() {
    cancelConnection(showStatus: false)
    replacingConnectionID = nil
    origin = ""
    status = ""
  }

  func beginReconnect(_ id: UUID) {
    cancelConnection(showStatus: false)
    guard let connection = connections.first(where: { $0.id == id }) else { return }
    replacingConnectionID = id
    origin = connection.origin.absoluteString
    status = ""
  }

  func startConnection() {
    guard !isBusy else { return }
    guard let url = URL(string: origin), ["http", "https"].contains(url.scheme?.lowercased()) else {
      status = "Enter a valid HTTP or HTTPS Storyteller origin."
      return
    }
    isBusy = true
    authorization = nil
    status = "Requesting authorization…"
    let replacing = replacingConnectionID
    authorizationTask = Task { [weak self] in
      await self?.connect(to: url, replacing: replacing)
    }
  }

  func cancelConnection(showStatus: Bool = true) {
    authorizationTask?.cancel()
    authorizationTask = nil
    authorization = nil
    isBusy = false
    if showStatus { status = "Connection canceled." }
  }

  func test(_ id: UUID) {
    guard let connection = connections.first(where: { $0.id == id }) else { return }
    health[id] = .init(state: .checking, detail: "Checking connection…")
    Task {
      do {
        let token = try await StorytellerConnectionStore.shared.token(id)
        let client = try StorytellerClient(origin: connection.origin, tokenProvider: { token })
        let user = try await client.currentUser()
        let name = user.username ?? user.name ?? connection.username
        let writable = user.permissions.bookCreate && user.permissions.bookUpdate
        health[id] = .init(
          state: .connected,
          detail: writable
            ? "Connected as \(name). This account can send books."
            : "Connected as \(name). This account cannot create or update books; delivery is unavailable.")
      } catch {
        health[id] = .init(
          state: (error as? StorytellerAPIError) == .authenticationRequired
            ? .authenticationRequired : .unavailable,
          detail: (error as? StorytellerAPIError) == .authenticationRequired
            ? "The saved session expired or was revoked. Reconnect this account."
            : error.localizedDescription)
      }
    }
  }

  func remove(_ id: UUID) async {
    do {
      try await store.remove(id)
      health.removeValue(forKey: id)
      if selectedConnection == id { selectedConnection = nil }
      status = "Disconnected. The saved Library snapshot and history were retained."
      await reload()
    } catch { status = error.localizedDescription }
  }

  private func connect(to url: URL, replacing connectionID: UUID?) async {
    defer {
      isBusy = false
      authorizationTask = nil
    }
    do {
      // Same fast-fail bound as the web connect flow: a wrong address
      // reports a reason within seconds instead of URLSession's defaults.
      let request: StorytellerDeviceAuthorization
      do {
        request = try await StorytellerDeviceAuth.start(
          origin: url,
          session: StorytellerHTTP.makeSession(requestTimeout: 10, resourceTimeout: 20))
      } catch let error as URLError {
        throw StorytellerAPIError.conflict(
          "Could not reach \(url.absoluteString): \(error.localizedDescription)")
      }
      try Task.checkCancellation()
      let expiresAt = Date().addingTimeInterval(TimeInterval(request.expiresIn))
      authorization = .init(
        userCode: request.userCode, approvalURL: request.verificationURIComplete,
        expiresAt: expiresAt)
      status = "Approve this device in Storyteller."
      NSWorkspace.shared.open(request.verificationURIComplete)
      var token: StorytellerToken?
      while Date() < expiresAt, token == nil {
        try Task.checkCancellation()
        try await Task.sleep(for: .seconds(max(1, request.interval)))
        token = try await StorytellerDeviceAuth.pollToken(
          origin: url, deviceCode: request.deviceCode)
      }
      try Task.checkCancellation()
      guard let token else {
        // Running out the clock is not an authentication failure; say so.
        authorization = nil
        status = "The approval code expired before this device was approved. Try connecting again."
        return
      }
      let client = try StorytellerClient(origin: url, tokenProvider: { token.accessToken })
      let user = try await client.currentUser()
      let username = user.username ?? user.name ?? "Storyteller user"
      let normalizedOrigin = await client.origin
      let existing = connectionID.flatMap { id in connections.first { $0.id == id } }
      if let existing, let previousUserID = existing.remoteUserID, previousUserID != user.id {
        throw StorytellerAPIError.conflict(
          "Reconnect was approved as a different Storyteller account. Connect it separately instead.")
      }
      let reusable = existing ?? connections.first {
        $0.origin == normalizedOrigin
          && ($0.remoteUserID == user.id || ($0.remoteUserID == nil && $0.username == username))
      }
      let connection = StorytellerConnection(
        id: reusable?.id ?? UUID(), origin: normalizedOrigin,
        displayName: reusable?.displayName ?? url.host ?? url.absoluteString,
        username: username, permissions: user.permissions, connectedAt: Date(),
        remoteUserID: user.id)
      try await store.save(connection, token: token.accessToken)
      authorization = nil
      replacingConnectionID = nil
      origin = ""
      status = "Connected as \(username)."
      selectedConnection = connection.id
      completionSerial += 1
      await reload()
      test(connection.id)
    } catch is CancellationError {
      authorization = nil
    } catch {
      authorization = nil
      // A user cancellation may race a network error from the doomed attempt;
      // "Connection canceled." must not be overwritten by that error.
      if !Task.isCancelled { status = error.localizedDescription }
    }
  }
}

struct StorytellerView: View {
  @Bindable var model: StorytellerStudioModel
  @State private var showingConnectionSheet = false
  @State private var pendingDisconnect: StorytellerConnection?

  private var selected: StorytellerConnection? {
    model.connections.first { $0.id == model.selectedConnection }
  }

  var body: some View {
    GeometryReader { geometry in
      VStack(spacing: 0) {
        HStack {
          VStack(alignment: .leading, spacing: 2) {
            Text("Storyteller Connections").font(.title2.bold())
            Text("Connect SpokenFolio to one or more Storyteller libraries.")
              .font(.caption).foregroundStyle(.secondary)
          }
          Spacer()
          Button {
            model.beginAdd()
            showingConnectionSheet = true
          } label: {
            Label("Add Connection…", systemImage: "plus")
          }
          Button {
            Task { await model.reload() }
          } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
          }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        Divider()
        if model.connections.isEmpty {
          ContentUnavailableView {
            Label("No Storyteller Connections", systemImage: "rectangle.connected.to.line.below")
          } description: {
            Text("Add a server to compare its library, create ReadAlouds, and deliver finished books.")
          } actions: {
            Button("Add Connection…") {
              model.beginAdd()
              showingConnectionSheet = true
            }
          }
        } else if geometry.size.width >= 720 {
          // Splits must be forced to the available size; see ActivityView.
          GeometryReader { split in
            HSplitView {
              connectionList
                .frame(minWidth: 250, idealWidth: 300, maxWidth: 380)
                .frame(maxHeight: .infinity)
              connectionDetail
                .frame(minWidth: 400)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
            }
            .frame(width: split.size.width, height: split.size.height)
          }
        } else {
          VStack(spacing: 0) {
            connectionList
              .frame(maxHeight: max(150, geometry.size.height * 0.34))
            Divider()
            connectionDetail
          }
        }
        if !model.status.isEmpty {
          HStack {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
            Text(model.status).font(.callout).textSelection(.enabled)
            Spacer()
          }
          .padding(.horizontal, 16).padding(.vertical, 8)
          .background(.bar)
        }
      }
    }
    .task { await model.reload() }
    .sheet(isPresented: $showingConnectionSheet) {
      StorytellerConnectionSheet(model: model)
        .onChange(of: model.completionSerial) { _, _ in showingConnectionSheet = false }
    }
    .alert(item: $pendingDisconnect) { connection in
      Alert(
        title: Text("Disconnect \(connection.displayName)?"),
        message: Text(
          "The Keychain credential will be removed. SpokenFolio keeps the cached Library snapshot, links, receipts, and quality history. You can reconnect later."),
        primaryButton: .destructive(Text("Disconnect")) {
          Task { await model.remove(connection.id) }
        },
        secondaryButton: .cancel())
    }
  }

  private var connectionList: some View {
    List(model.connections, selection: $model.selectedConnection) { connection in
      HStack(alignment: .top, spacing: 9) {
        Image(systemName: healthSymbol(model.health[connection.id]?.state ?? .unknown))
          .foregroundStyle(healthColor(model.health[connection.id]?.state ?? .unknown))
        VStack(alignment: .leading, spacing: 2) {
          Text(connection.displayName).font(.headline).lineLimit(1)
          Text(connection.username).font(.caption).foregroundStyle(.secondary).lineLimit(1)
          Text(connection.origin.absoluteString)
            .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
        }
      }
      .padding(.vertical, 3)
      .tag(connection.id)
    }
  }

  private var connectionDetail: some View {
    Group {
      if let connection = selected {
        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
              Text(connection.displayName).font(.title3.bold())
              Text(connection.origin.absoluteString).textSelection(.enabled)
              Text("Signed in as \(connection.username)").foregroundStyle(.secondary)
            }
            if let health = model.health[connection.id] {
              Label(health.detail, systemImage: healthSymbol(health.state))
                .foregroundStyle(healthColor(health.state))
                .textSelection(.enabled)
            } else {
              Text("Connection has not been tested in this session.")
                .foregroundStyle(.secondary)
            }
            Divider()
            Text("Permissions").font(.headline)
            LazyVGrid(
              columns: [GridItem(.adaptive(minimum: 145), alignment: .leading)],
              alignment: .leading, spacing: 8
            ) {
              permission("List books", connection.permissions.bookList)
              permission("Read books", connection.permissions.bookRead)
              permission("Download EPUBs", connection.permissions.bookDownload)
              permission("Create books", connection.permissions.bookCreate)
              permission("Update books", connection.permissions.bookUpdate)
              permission("Process ReadAlouds", connection.permissions.bookProcess)
            }
            Divider()
            Text("Account").font(.headline)
            LabeledContent("Connected", value: connection.connectedAt.formatted())
            LabeledContent("Account ID", value: connection.remoteUserID?.uuidString ?? "Legacy connection")
              .textSelection(.enabled)
            LazyVGrid(
              columns: [GridItem(.adaptive(minimum: 145), spacing: 8)],
              alignment: .leading, spacing: 8
            ) {
              Button("Test Connection") { model.test(connection.id) }
              Button("Reconnect…") {
                model.beginReconnect(connection.id)
                showingConnectionSheet = true
              }
              Button("Disconnect…", role: .destructive) { pendingDisconnect = connection }
            }
          }
          .padding(16)
        }
      } else {
        ContentUnavailableView(
          "Select a Connection", systemImage: "rectangle.connected.to.line.below",
          description: Text("Account, permissions, and connection health appear here."))
      }
    }
  }

  private func permission(_ label: String, _ granted: Bool) -> some View {
    Label(label, systemImage: granted ? "checkmark.circle.fill" : "xmark.circle")
      .foregroundStyle(granted ? .primary : .secondary)
      .accessibilityValue(granted ? "Allowed" : "Not allowed")
  }

  private func healthSymbol(_ state: StorytellerConnectionHealth.State) -> String {
    switch state {
    case .unknown: "circle.dashed"
    case .checking: "clock"
    case .connected: "checkmark.circle.fill"
    case .readOnly: "lock.circle"
    case .authenticationRequired: "person.crop.circle.badge.exclamationmark"
    case .unavailable: "exclamationmark.triangle.fill"
    }
  }

  private func healthColor(_ state: StorytellerConnectionHealth.State) -> Color {
    switch state {
    case .connected: .green
    case .readOnly, .authenticationRequired: .orange
    case .unavailable: .red
    default: .secondary
    }
  }
}

private struct StorytellerConnectionSheet: View {
  @Bindable var model: StorytellerStudioModel
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(model.replacingConnectionID == nil ? "Add Storyteller Connection" : "Reconnect Storyteller")
        .font(.title2.bold())
      if let authorization = model.authorization {
        Text("Approve this device in Storyteller")
          .font(.headline)
        Text(authorization.userCode)
          .font(.system(size: 34, weight: .bold, design: .monospaced))
          .textSelection(.enabled)
          .accessibilityLabel("Authorization code \(authorization.userCode)")
        TimelineView(.periodic(from: .now, by: 1)) { context in
          let remaining = max(0, Int(authorization.expiresAt.timeIntervalSince(context.date)))
          Text("Code expires in \(remaining / 60):\(String(format: "%02d", remaining % 60))")
            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        HStack {
          Button("Open Storyteller") { NSWorkspace.shared.open(authorization.approvalURL) }
          Button("Copy Code") {
            PasteboardWriter.copy(authorization.userCode)
          }
        }
        ProgressView("Waiting for approval…")
      } else {
        TextField("https://storyteller.example", text: $model.origin)
          .textFieldStyle(.roundedBorder)
          .disabled(model.isBusy)
        Text(
          "SpokenFolio opens Storyteller's device-approval page. The resulting token is stored in the macOS Keychain."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
      if !model.status.isEmpty {
        Text(model.status).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
      }
      Spacer()
      HStack {
        Button("Cancel") {
          if model.isBusy { model.cancelConnection() }
          dismiss()
        }
        Spacer()
        if model.authorization == nil {
          Button(model.replacingConnectionID == nil ? "Connect" : "Reconnect") {
            model.startConnection()
          }
          .keyboardShortcut(.defaultAction)
          .disabled(model.isBusy || model.origin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
    }
    .padding(20)
    .frame(idealWidth: 540, idealHeight: 400)
    .interactiveDismissDisabled(model.isBusy)
  }
}

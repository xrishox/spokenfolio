import BookJobKit
import Foundation
import ReadAloudKit
import StorytellerKit
import Vapor

/// `/api/storyteller`, `/api/tools`, settings mutations, and the bounded
/// filesystem browser for path pickers.
struct SettingsAPIController: RouteCollection {
  func boot(routes: any RoutesBuilder) throws {
    let api = routes.grouped("api").grouped(WebAPIErrorMiddleware())
    api.get("storyteller", "connections", use: connections)
    api.post("storyteller", "connections", ":id", "test", use: testConnection)
    api.delete("storyteller", "connections", ":id", use: removeConnection)
    api.post("storyteller", "device-auth", use: startDeviceAuth)
    api.get("storyteller", "device-auth", ":id", use: deviceAuthStatus)
    api.delete("storyteller", "device-auth", ":id", use: cancelDeviceAuth)
    api.get("tools", use: tools)
    api.post("tools", "stalign", "install", use: installStalign)
    api.put("settings", "processed-directory", use: setProcessedDirectory)
    api.get("fs", "list", use: listDirectory)
  }

  private func studio(_ req: Request) throws -> StudioServices {
    guard let services = req.application.studioServices else {
      throw WebAPIError.studioUnavailable
    }
    return services
  }

  // MARK: - Storyteller connections

  @Sendable func connections(req: Request) async throws -> [ConnectionDTO] {
    _ = try studio(req)
    let connections = try await StorytellerConnectionStore.shared.connections()
    return connections.map(ConnectionDTO.init)
  }

  @Sendable func testConnection(req: Request) async throws -> ConnectionHealthDTO {
    _ = try studio(req)
    guard let id = req.parameters.get("id", as: UUID.self) else {
      throw WebAPIError.badRequest("invalid_id", "the connection id is not a UUID")
    }
    let connections = try await StorytellerConnectionStore.shared.connections()
    guard let connection = connections.first(where: { $0.id == id }) else {
      throw WebAPIError.notFound("no connection with that id")
    }
    do {
      let token = try await StorytellerConnectionStore.shared.token(id)
      let client = try StorytellerClient(origin: connection.origin, tokenProvider: { token })
      let user = try await client.currentUser()
      let username = user.username ?? user.name ?? connection.username
      do {
        let capabilities = try await client.mutationCapabilities()
        let writable = capabilities.createIfBookMissing
          && capabilities.replaceIfAssetMissing && capabilities.identifierETag
        return ConnectionHealthDTO(
          state: writable ? "connected" : "readOnly",
          detail: writable
            ? "Connected as \(username). Safe delivery is available."
            : "Connected, but this server does not advertise every safe-mutation "
              + "contract. Browsing remains available; delivery is read-only.")
      } catch {
        return ConnectionHealthDTO(
          state: "readOnly",
          detail: "Connected as \(username). Safe delivery capability discovery is "
            + "unavailable, so mutation remains read-only.")
      }
    } catch {
      let authRequired = (error as? StorytellerAPIError) == .authenticationRequired
      return ConnectionHealthDTO(
        state: authRequired ? "authenticationRequired" : "unavailable",
        detail: authRequired
          ? "The saved session expired or was revoked. Reconnect this account."
          : error.localizedDescription)
    }
  }

  @Sendable func removeConnection(req: Request) async throws -> HTTPStatus {
    _ = try studio(req)
    guard let id = req.parameters.get("id", as: UUID.self) else {
      throw WebAPIError.badRequest("invalid_id", "the connection id is not a UUID")
    }
    try await StorytellerConnectionStore.shared.remove(id)
    return .noContent
  }

  // MARK: - Device auth

  @Sendable func startDeviceAuth(req: Request) async throws -> DeviceAuthSessionDTO {
    struct Body: Content {
      let origin: String
      let replacingConnectionID: UUID?
    }
    let services = try studio(req)
    let body = try req.content.decode(Body.self)
    let session = try await services.deviceAuth.start(
      origin: body.origin, replacingConnectionID: body.replacingConnectionID)
    return DeviceAuthSessionDTO(session)
  }

  @Sendable func deviceAuthStatus(req: Request) async throws -> DeviceAuthSessionDTO {
    let services = try studio(req)
    guard let id = req.parameters.get("id", as: UUID.self),
      let session = await services.deviceAuth.session(id)
    else {
      throw WebAPIError.notFound("no device-auth session with that id")
    }
    return DeviceAuthSessionDTO(session)
  }

  @Sendable func cancelDeviceAuth(req: Request) async throws -> HTTPStatus {
    let services = try studio(req)
    guard let id = req.parameters.get("id", as: UUID.self) else {
      throw WebAPIError.badRequest("invalid_id", "the session id is not a UUID")
    }
    await services.deviceAuth.cancel(id)
    return .noContent
  }

  // MARK: - Tools

  @Sendable func tools(req: Request) async throws -> ToolsDTO {
    _ = try studio(req)
    var stalignStatus = "missing"
    var stalignDetail = "stalign \(ReadAloudTools.pinnedStalignVersion) is not installed."
    do {
      let toolchain = try await ReadAloudTools.resolve(
        managedStalign: AppPaths.managedStalignURL)
      stalignStatus = "installed"
      stalignDetail =
        "stalign \(toolchain.stalignVersion) verified (checksum and signing team)."
    } catch {
      stalignDetail = error.localizedDescription
    }
    var mediaStatus = "missing"
    var mediaDetail = "ffmpeg/ffprobe were not found. Install with: brew install ffmpeg"
    if let pair = try? ReadAloudTools.resolveFFmpegOnly() {
      mediaStatus = "installed"
      mediaDetail = "ffmpeg at \(pair.0.path)"
    }
    return ToolsDTO(
      stalign: .init(
        status: stalignStatus, detail: stalignDetail,
        pinnedVersion: ReadAloudTools.pinnedStalignVersion),
      media: .init(status: mediaStatus, detail: mediaDetail))
  }

  @Sendable func installStalign(req: Request) async throws -> ToolsDTO {
    _ = try studio(req)
    try await ReadAloudTools.installStalign(destination: AppPaths.managedStalignURL)
    return try await tools(req: req)
  }

  // MARK: - Settings and filesystem

  @Sendable func setProcessedDirectory(req: Request) async throws -> SettingsDTO {
    struct Body: Content {
      let path: String?
    }
    _ = try studio(req)
    let body = try req.content.decode(Body.self)
    let store = StudioSettingsStore(url: AppPaths.studioSettingsURL)
    if let path = body.path {
      let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
        isDirectory.boolValue
      else {
        throw WebAPIError.badRequest("not_a_directory", "the path is not a directory")
      }
      try await store.save(StudioSettings(processedDirectory: url.path))
    } else {
      try await store.save(StudioSettings(processedDirectory: nil))
    }
    let directory = (try await store.load()).resolvedProcessedDirectory(
      home: FileManager.default.homeDirectoryForCurrentUser)
    return SettingsDTO(
      processedDirectory: directory.path,
      capabilities: .init(launchAtLogin: false, revealInFinder: false, restartServer: false))
  }

  /// Bounded directory browser for output-directory and EPUB path pickers:
  /// rooted at the user's home, symlink-escape-safe, no dotfiles.
  @Sendable func listDirectory(req: Request) async throws -> FSListDTO {
    _ = try studio(req)
    let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
    let requested = (try? req.query.get(String.self, at: "path")) ?? home.path
    let wantsEPUBs = ((try? req.query.get(String.self, at: "files")) ?? "") == "epub"
    let url = URL(
      fileURLWithPath: (requested as NSString).expandingTildeInPath, isDirectory: true
    ).standardizedFileURL
    let resolved = url.resolvingSymlinksInPath()
    guard resolved.path.hasPrefix(home.resolvingSymlinksInPath().path) else {
      throw WebAPIError.badRequest("outside_home", "browsing is bounded to the home folder")
    }
    let contents = (try? FileManager.default.contentsOfDirectory(
      at: url, includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles])) ?? []
    var entries: [FSListDTO.Entry] = []
    for item in contents.prefix(500) {
      let isDirectory =
        (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
      if isDirectory {
        entries.append(.init(name: item.lastPathComponent, path: item.path, kind: "directory"))
      } else if wantsEPUBs, item.pathExtension.lowercased() == "epub" {
        entries.append(.init(name: item.lastPathComponent, path: item.path, kind: "epub"))
      }
    }
    entries.sort {
      if $0.kind != $1.kind { return $0.kind == "directory" }
      return $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }
    return FSListDTO(
      path: url.path,
      parent: url.path == home.path ? nil : url.deletingLastPathComponent().path,
      entries: entries)
  }
}

struct ConnectionDTO: Content {
  let id: UUID
  let origin: String
  let displayName: String
  let username: String
  let connectedAt: Date
  let permissions: [String: Bool]

  init(_ connection: StorytellerConnection) {
    id = connection.id
    origin = connection.origin.absoluteString
    displayName = connection.displayName
    username = connection.username
    connectedAt = connection.connectedAt
    permissions = [
      "bookList": connection.permissions.bookList,
      "bookRead": connection.permissions.bookRead,
      "bookDownload": connection.permissions.bookDownload,
      "bookCreate": connection.permissions.bookCreate,
      "bookUpdate": connection.permissions.bookUpdate,
      "bookProcess": connection.permissions.bookProcess,
    ]
  }
}

struct ConnectionHealthDTO: Content {
  let state: String
  let detail: String
}

struct DeviceAuthSessionDTO: Content {
  let id: UUID
  let userCode: String
  let verificationURL: String
  let expiresAt: Date
  let state: String
  let connectionID: UUID?
  let username: String?
  let failure: String?

  init(_ session: DeviceAuthSessionStore.Session) {
    id = session.id
    userCode = session.userCode
    verificationURL = session.verificationURL
    expiresAt = session.expiresAt
    switch session.state {
    case .pending:
      state = "pending"
      connectionID = nil
      username = nil
      failure = nil
    case .connected(let connection, let name):
      state = "connected"
      connectionID = connection
      username = name
      failure = nil
    case .expired:
      state = "expired"
      connectionID = nil
      username = nil
      failure = nil
    case .failed(let message):
      state = "failed"
      connectionID = nil
      username = nil
      failure = message
    }
  }
}

struct ToolsDTO: Content {
  struct Tool: Content {
    let status: String
    let detail: String
    var pinnedVersion: String? = nil
  }
  let stalign: Tool
  let media: Tool
}

struct FSListDTO: Content {
  struct Entry: Content {
    let name: String
    let path: String
    let kind: String
  }
  let path: String
  let parent: String?
  let entries: [Entry]
}

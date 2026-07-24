import AppKit
import LibraryKit
import Observation
import SiriTTSCore
import Vapor
import os

enum ServerRuntimeState: Equatable {
  case stopped
  case starting
  case ready(endpoint: String, voiceCount: Int)
  case degraded(endpoint: String, message: String)
  case failed(message: String)

  var title: String {
    switch self {
    case .stopped: "Stopped"
    case .starting: "Starting…"
    case .ready(_, let count): "Ready — \(count) Siri voices"
    case .degraded(_, let message), .failed(let message): message
    }
  }

  var endpoint: String? {
    switch self {
    case .ready(let endpoint, _), .degraded(let endpoint, _): endpoint
    default: nil
    }
  }
}

enum ConnectionTestState: Equatable {
  case idle, running, passed, failed(String)
}

@MainActor @Observable
final class ApplicationRuntime {
  /// The process-wide service graph shared by the GUI adapters and the
  /// embedded web API.
  let services: StudioServices
  let coordinator: StudioJobCoordinator
  let navigation: AppNavigationModel
  let settings: AppSettingsModel
  let quality: ReadAloudQualityModel
  private(set) var serverState: ServerRuntimeState = .stopped
  private(set) var connectionTestState: ConnectionTestState = .idle
  private(set) var shutdownError: String?

  @ObservationIgnored private let serverController: EmbeddedServerController
  @ObservationIgnored private var didStart = false
  @ObservationIgnored private var qualityResumeTask: Task<Void, Never>?

  init(
    services: StudioServices = StudioServices(),
    navigation: AppNavigationModel = AppNavigationModel(),
    settings: AppSettingsModel = AppSettingsModel()
  ) {
    self.services = services
    self.coordinator = StudioJobCoordinator(service: services.jobs)
    self.navigation = navigation
    self.settings = settings
    settings.attach(services: services)
    self.quality = ReadAloudQualityModel(
      service: services.quality, databaseURL: services.libraryDatabaseURL)
    let sharedServices = services
    serverController = EmbeddedServerController {
      let config = try ServerConfig.load()
      let application = try await makeServerApplication(config: config, studio: sharedServices)
      return EmbeddedServerHandle(
        application: application,
        config: config,
        run: { try await application.execute() },
        waitUntilReady: {
          let clock = ContinuousClock()
          let deadline = clock.now.advanced(by: .seconds(15))
          while application.running == nil {
            try Task.checkCancellation()
            guard clock.now < deadline else {
              throw ConfigurationError("The HTTP listener did not become ready within 15 seconds.")
            }
            try await Task.sleep(for: .milliseconds(25))
          }
        },
        requestStop: { application.running?.stop() },
        shutdown: { try? await application.asyncShutdown() })
    }
    serverController.onEvent = { [weak self] event in self?.receive(event) }
  }

  func start() {
    guard !didStart else { return }
    didStart = true
    Self.primeHostName()
    coordinator.start()
    // Synchronous SQLite work must not stall first paint.
    Task.detached(priority: .utility) {
      try? LibraryStore(databaseURL: AppPaths.libraryDatabaseURL)
        .reconcileInterruptedReadAloudAudits()
    }
    serverController.start()
    Task { await settings.load() }
    qualityResumeTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(1))
      guard !Task.isCancelled else { return }
      self?.quality.resumeQueuedAudits()
    }
  }

  func restartServer() { Task { await serverController.restart() } }

  func runConnectionTest() {
    guard case .ready = serverState,
      let handle = serverController.activeHandle
    else { return }
    let voice = handle.application.ttsService.defaultVoice
    connectionTestState = .running
    Task {
      do {
        try await ServerConnectionTester.run(port: handle.config.port, voice: voice)
        connectionTestState = .passed
      } catch {
        connectionTestState = .failed(error.localizedDescription)
      }
    }
  }

  @discardableResult
  func copyEndpoint() -> Bool {
    guard let endpoint = serverState.endpoint else { return false }
    return PasteboardWriter.copy(endpoint)
  }

  func openFullDiskAccess() {
    guard let url = URL(
      string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
    else { return }
    NSWorkspace.shared.open(url)
  }

  func openConsole() {
    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Console.app"))
  }

  func shutdown() async throws {
    qualityResumeTask?.cancel()
    await qualityResumeTask?.value
    qualityResumeTask = nil
    await quality.cancelAndWait()
    try await coordinator.prepareForTermination()
    await serverController.stop()
  }

  func stopImmediately() { serverController.stopImmediately() }
  func presentShutdownError(_ message: String) { shutdownError = message }

  private func receive(_ event: EmbeddedServerController.Event) {
    switch event {
    case .starting:
      // The last verification result stays visible across a restart; it
      // describes the previous run until the user tests again.
      serverState = .starting
    case .ready(let handle):
      let endpoint = Self.endpoint(host: handle.config.host, port: handle.config.port)
      switch handle.application.serverHealth.state {
      case .ready:
        serverState = .ready(
          endpoint: endpoint, voiceCount: handle.application.ttsService.voiceCatalog.count)
      case .permissionRequired:
        serverState = .degraded(endpoint: endpoint, message: "Full Disk Access required")
      case .unavailable:
        serverState = .degraded(endpoint: endpoint, message: "Siri engine unavailable")
      case .starting:
        serverState = .starting
      }
    case .failed(let error):
      let message: String
      if let service = error as? ServiceError {
        switch service {
        case .permissionRequired: message = "Full Disk Access required"
        case .engineUnavailable: message = "Siri engine unavailable"
        default: message = "Server unavailable — run Doctor"
        }
      } else if let error {
        message = error.localizedDescription
      } else {
        message = "Server failed — open Console"
      }
      serverState = .failed(message: message)
    case .stopped:
      if case .failed = serverState {} else { serverState = .stopped }
    }
  }

  /// `ProcessInfo.hostName` can block on DNS; resolve it once off the main
  /// actor so wildcard-bind endpoints display without stalling event handling.
  private nonisolated static let cachedHostName = OSAllocatedUnfairLock<String?>(initialState: nil)

  nonisolated static func primeHostName() {
    Task.detached(priority: .utility) {
      let name = ProcessInfo.processInfo.hostName
      cachedHostName.withLock { $0 = name }
    }
  }

  nonisolated static func endpoint(host: String, port: Int) -> String {
    let lowered = host.lowercased()
    let resolved: String
    if ["0.0.0.0", "::", "[::]"].contains(lowered) {
      resolved = cachedHostName.withLock { $0 } ?? ProcessInfo.processInfo.hostName
    } else if ["127.0.0.1", "::1", "[::1]", "localhost"].contains(lowered) {
      resolved = "localhost"
    } else {
      resolved = host
    }
    let display = resolved.contains(":") && !resolved.hasPrefix("[") ? "[\(resolved)]" : resolved
    return "http://\(display):\(port)"
  }
}

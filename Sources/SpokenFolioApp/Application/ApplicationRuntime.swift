import AppKit
import Observation
import SiriTTSCore
import Vapor

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
  let coordinator: StudioJobCoordinator
  let navigation: AppNavigationModel
  let settings: AppSettingsModel
  private(set) var serverState: ServerRuntimeState = .stopped
  private(set) var connectionTestState: ConnectionTestState = .idle
  private(set) var shutdownError: String?

  @ObservationIgnored private let serverController: EmbeddedServerController
  @ObservationIgnored private var didStart = false

  init(
    coordinator: StudioJobCoordinator = StudioJobCoordinator(),
    navigation: AppNavigationModel = AppNavigationModel(),
    settings: AppSettingsModel = AppSettingsModel()
  ) {
    self.coordinator = coordinator
    self.navigation = navigation
    self.settings = settings
    serverController = EmbeddedServerController {
      let config = try ServerConfig.load()
      let application = try await makeServerApplication(config: config)
      return EmbeddedServerHandle(
        application: application,
        config: config,
        run: { try await application.execute() },
        requestStop: { application.running?.stop() },
        shutdown: { try? await application.asyncShutdown() })
    }
    serverController.onEvent = { [weak self] event in self?.receive(event) }
  }

  func start() {
    guard !didStart else { return }
    didStart = true
    coordinator.start()
    serverController.start()
    Task { await settings.load() }
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

  func copyEndpoint() {
    guard let endpoint = serverState.endpoint else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(endpoint, forType: .string)
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
    try await coordinator.prepareForTermination()
    await serverController.stop()
  }

  func stopImmediately() { serverController.stopImmediately() }
  func presentShutdownError(_ message: String) { shutdownError = message }

  private func receive(_ event: EmbeddedServerController.Event) {
    switch event {
    case .starting:
      serverState = .starting
      connectionTestState = .idle
    case .ready(let handle):
      let endpoint = Self.endpoint(port: handle.config.port)
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
      switch error {
      case .permissionRequired: message = "Full Disk Access required"
      case .engineUnavailable: message = "Siri engine unavailable"
      case .some: message = "Server unavailable — run Doctor"
      case nil: message = "Server failed — open Console"
      }
      serverState = .failed(message: message)
    case .stopped:
      serverState = .stopped
    }
  }

  private static func endpoint(port: Int) -> String {
    let name = Host.current().localizedName ?? "localhost"
    return "http://\(name):\(port)"
  }
}

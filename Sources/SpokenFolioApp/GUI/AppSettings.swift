import AppKit
import BookJobKit
import Observation
import ServiceManagement
import SwiftUI

enum LaunchAtLoginState: Equatable {
  case enabled, disabled, requiresApproval
}

@MainActor
protocol LaunchAtLoginServicing {
  var state: LaunchAtLoginState { get }
  func register() throws
  func unregister() throws
  func openSettings()
}

@MainActor
struct SystemLaunchAtLoginService: LaunchAtLoginServicing {
  var state: LaunchAtLoginState {
    switch SMAppService.mainApp.status {
    case .enabled: .enabled
    case .requiresApproval: .requiresApproval
    default: .disabled
    }
  }
  func register() throws { try SMAppService.mainApp.register() }
  func unregister() throws { try SMAppService.mainApp.unregister() }
  func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}

@MainActor @Observable
final class AppSettingsModel {
  private(set) var directory = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Books/Processed", isDirectory: true)
  private(set) var launchAtLogin: LaunchAtLoginState = .disabled
  private(set) var status = ""

  @ObservationIgnored private let store: StudioSettingsStore
  @ObservationIgnored private let loginService: any LaunchAtLoginServicing
  @ObservationIgnored private var didLoad = false

  init(
    store: StudioSettingsStore = StudioSettingsStore(url: AppPaths.studioSettingsURL),
    loginService: any LaunchAtLoginServicing = SystemLaunchAtLoginService()
  ) {
    self.store = store
    self.loginService = loginService
  }

  func load() async {
    guard !didLoad else { refreshLaunchAtLogin(); return }
    didLoad = true
    do {
      directory = try await store.load().resolvedProcessedDirectory(
        home: FileManager.default.homeDirectoryForCurrentUser)
      status = ""
    } catch { status = error.localizedDescription }
    refreshLaunchAtLogin()
  }

  func chooseDirectory() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.directoryURL = directory
    panel.begin { response in
      guard response == .OK, let url = panel.url else { return }
      Task { @MainActor in await self.saveDirectory(url.standardizedFileURL) }
    }
  }

  func resetDirectory() { Task { await saveDirectory(nil) } }

  func toggleLaunchAtLogin() {
    do {
      if launchAtLogin == .enabled { try loginService.unregister() } else { try loginService.register() }
      status = ""
    } catch { status = "Could not update Launch at Login: \(error.localizedDescription)" }
    refreshLaunchAtLogin()
  }

  func openLoginItems() { loginService.openSettings() }

  private func refreshLaunchAtLogin() { launchAtLogin = loginService.state }

  private func saveDirectory(_ value: URL?) async {
    do {
      try await store.save(StudioSettings(processedDirectory: value?.path))
      directory = (try await store.load()).resolvedProcessedDirectory(
        home: FileManager.default.homeDirectoryForCurrentUser)
      status = "New books will use this location. Existing cataloged books do not move."
    } catch { status = error.localizedDescription }
  }
}

struct AppSettingsView: View {
  @Bindable var model: AppSettingsModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        Text("Settings").font(.title2.bold())
        GroupBox("Processed Books") {
          VStack(alignment: .leading, spacing: 10) {
            Text(model.directory.path).textSelection(.enabled)
            Text(
              "Original EPUBs, M4B audiobooks, and ReadAloud EPUBs for new books are kept together here. Changing this does not move existing books."
            ).foregroundStyle(.secondary)
            HStack {
              Button("Choose Folder…") { model.chooseDirectory() }
              Button("Use ~/Books/Processed") { model.resetDirectory() }
              Button("Reveal") { NSWorkspace.shared.open(model.directory) }
            }
          }.padding(6)
        }
        GroupBox("Startup") {
          VStack(alignment: .leading, spacing: 10) {
            Toggle(
              "Open SpokenFolio at login",
              isOn: Binding(
                get: { model.launchAtLogin == .enabled },
                set: { _ in model.toggleLaunchAtLogin() }))
            Text("Launch at Login opens the normal SpokenFolio window and starts the gateway and queue.")
              .foregroundStyle(.secondary)
            if model.launchAtLogin == .requiresApproval {
              Button("Open Login Items…") { model.openLoginItems() }
            }
          }.padding(6)
        }
        if !model.status.isEmpty { Text(model.status).foregroundStyle(.secondary) }
        Spacer()
      }.padding(20)
    }.task { await model.load() }
  }
}

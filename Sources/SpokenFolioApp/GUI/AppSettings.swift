import AppKit
import BookJobKit
import Observation
import ServiceManagement
import SwiftUI

enum LaunchAtLoginState: Equatable {
  case enabled, disabled, requiresApproval
}

enum AppSettingsNotice: Equatable {
  case information(String)
  case failure(String)

  var message: String {
    switch self {
    case .information(let message), .failure(let message): message
    }
  }
}

enum SettingsScope: String, CaseIterable, Identifiable {
  static let persistenceKey = "SpokenFolioSettingsScope"

  case general
  case storage
  case readAloud
  case storyteller

  var id: Self { self }

  var title: String {
    switch self {
    case .general: "General"
    case .storage: "Storage"
    case .readAloud: "ReadAloud"
    case .storyteller: "Storyteller"
    }
  }

  var icon: String {
    switch self {
    case .general: "gearshape"
    case .storage: "externaldrive"
    case .readAloud: "text.bubble"
    case .storyteller: "rectangle.connected.to.line.below"
    }
  }
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
  private(set) var notice: AppSettingsNotice?
  private(set) var isLoading = false

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
    isLoading = true
    defer { isLoading = false }
    do {
      directory = try await store.load().resolvedProcessedDirectory(
        home: FileManager.default.homeDirectoryForCurrentUser)
      notice = nil
    } catch { notice = .failure(error.localizedDescription) }
    refreshLaunchAtLogin()
  }

  func chooseDirectory() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.directoryURL = directory
    let complete: (NSApplication.ModalResponse) -> Void = { response in
      guard response == .OK, let url = panel.url else { return }
      Task { @MainActor in await self.saveDirectory(url.standardizedFileURL) }
    }
    // The picker must always appear: fall back to a standalone panel when no
    // window can host a sheet, instead of swallowing the click.
    if let window = NSApp.keyWindow ?? NSApp.mainWindow, window.attachedSheet == nil {
      panel.beginSheetModal(for: window, completionHandler: complete)
    } else {
      panel.begin(completionHandler: complete)
    }
  }

  func resetDirectory() { Task { await saveDirectory(nil) } }

  func setLaunchAtLogin(_ enabled: Bool) {
    do {
      if enabled { try loginService.register() } else { try loginService.unregister() }
      notice = nil
    } catch {
      notice = .failure("Could not update Launch at Login: \(error.localizedDescription)")
    }
    refreshLaunchAtLogin()
  }

  func toggleLaunchAtLogin() { setLaunchAtLogin(launchAtLogin == .disabled) }

  func openLoginItems() { loginService.openSettings() }

  func revealDirectory() {
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      NSWorkspace.shared.activateFileViewerSelecting([directory])
    } catch {
      notice = .failure("Could not reveal the processed-books folder: \(error.localizedDescription)")
    }
  }

  private func refreshLaunchAtLogin() { launchAtLogin = loginService.state }

  private func saveDirectory(_ value: URL?) async {
    // A save must never be silently dropped: the directory panel can complete
    // while an earlier load or save still holds isLoading.
    while isLoading { try? await Task.sleep(for: .milliseconds(50)) }
    isLoading = true
    defer { isLoading = false }
    do {
      try await store.save(StudioSettings(processedDirectory: value?.path))
      directory = (try await store.load()).resolvedProcessedDirectory(
        home: FileManager.default.homeDirectoryForCurrentUser)
      notice = .information(
        "New books will use this location. Existing cataloged books do not move.")
    } catch { notice = .failure(error.localizedDescription) }
  }
}

struct AppSettingsView: View {
  @Bindable var model: AppSettingsModel
  @Bindable var tools: ReadAloudToolsModel
  @Bindable var storyteller: StorytellerStudioModel
  @AppStorage(SettingsScope.persistenceKey) private var scope = SettingsScope.general

  var body: some View {
    VStack(spacing: 0) {
      Picker("Settings area", selection: $scope) {
        ForEach(SettingsScope.allCases) { value in
          Label(value.title, systemImage: value.icon).tag(value)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .frame(maxWidth: 620)
      .padding(.horizontal, 24)
      .padding(.vertical, 14)

      Divider()

      switch scope {
      case .general: general
      case .storage: storage
      case .readAloud: ToolsView(model: tools)
      case .storyteller: StorytellerView(model: storyteller)
      }
    }
    .navigationTitle("Settings")
    .toolbar {
      if scope == .readAloud {
        ToolbarItem(placement: .primaryAction) {
          Button {
            Task { await tools.refresh() }
          } label: {
            Label("Check Tools", systemImage: "arrow.clockwise")
          }
          .disabled(tools.isBusy)
        }
      }
    }
    .task { await model.load() }
  }

  private var general: some View {
    Form {
      Section("Startup") {
        Toggle(
          "Open SpokenFolio at login",
          isOn: Binding(
            get: { model.launchAtLogin != .disabled },
            set: { model.setLaunchAtLogin($0) }))
        Text("Opening at login starts the normal window, TTS gateway, and production scheduler.")
          .foregroundStyle(.secondary)
        if model.launchAtLogin == .requiresApproval {
          LabeledContent("Approval") {
            Button("Open Login Items…") { model.openLoginItems() }
          }
          Text("macOS is waiting for approval before it can open SpokenFolio automatically.")
            .foregroundStyle(.orange)
        }
      }
      notice
    }
    .formStyle(.grouped)
    .disabled(model.isLoading)
  }

  private var storage: some View {
    Form {
      Section("Processed books") {
        LabeledContent("Folder") {
          Text(model.directory.path)
            .lineLimit(2)
            .truncationMode(.middle)
            .textSelection(.enabled)
        }
        Text(
          "New source EPUBs, M4B audiobooks, and ReadAloud EPUBs are kept together here. Existing cataloged books do not move when this changes."
        )
        .foregroundStyle(.secondary)
        HStack {
          Button("Choose Folder…") { model.chooseDirectory() }
          Button("Restore Default") { model.resetDirectory() }
          Button("Reveal in Finder") { model.revealDirectory() }
        }
      }
      notice
    }
    .formStyle(.grouped)
    .disabled(model.isLoading)
  }

  @ViewBuilder private var notice: some View {
    if let notice = model.notice {
      Section {
        Label {
          Text(notice.message).textSelection(.enabled)
        } icon: {
          switch notice {
          case .information: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
          case .failure: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
          }
        }
      }
    }
  }
}

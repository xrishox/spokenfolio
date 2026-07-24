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
  /// A path change awaiting the user's "move the whole library" confirmation.
  struct PendingMove: Identifiable, Equatable {
    let id = UUID()
    let destination: URL
    let bookCount: Int
    /// True when the user chose "Restore Default" — persists nil instead of
    /// an explicit path.
    let isDefault: Bool
  }

  private(set) var directory = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Books/SpokenFolio", isDirectory: true)
  private(set) var launchAtLogin: LaunchAtLoginState = .disabled
  private(set) var notice: AppSettingsNotice?
  private(set) var isLoading = false
  var pendingMove: PendingMove?
  private(set) var isRelocating = false
  private(set) var relocation: LibraryRelocationService.Snapshot?

  @ObservationIgnored private let store: StudioSettingsStore
  @ObservationIgnored private let loginService: any LaunchAtLoginServicing
  @ObservationIgnored private var didLoad = false
  @ObservationIgnored private var services: StudioServices?
  @ObservationIgnored private var relocationPoll: Task<Void, Never>?

  init(
    store: StudioSettingsStore = StudioSettingsStore(url: AppPaths.studioSettingsURL),
    loginService: any LaunchAtLoginServicing = SystemLaunchAtLoginService()
  ) {
    self.store = store
    self.loginService = loginService
  }

  /// Hands the model the process-wide service graph so a directory change
  /// can run the shared relocation service (the same instance the web API
  /// drives).
  func attach(services: StudioServices) { self.services = services }

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
    let home = FileManager.default.homeDirectoryForCurrentUser
    let target = (value ?? home.appendingPathComponent("Books/SpokenFolio", isDirectory: true))
      .standardizedFileURL
    // A real path change with cataloged books means moving the whole
    // library — that needs the user's explicit confirmation first.
    if services != nil, !isRelocating, target.path != directory.standardizedFileURL.path {
      let count = await movableBookCount()
      if count > 0 {
        pendingMove = PendingMove(
          destination: target, bookCount: count, isDefault: value == nil)
        return
      }
    }
    do {
      try await store.save(StudioSettings(processedDirectory: value?.standardizedFileURL.path))
      directory = (try await store.load()).resolvedProcessedDirectory(home: home)
      notice = .information("Books will be stored here.")
    } catch { notice = .failure(error.localizedDescription) }
  }

  /// Books whose folder lives under the current root — the ones a
  /// relocation would move.
  private func movableBookCount() async -> Int {
    let root = directory.standardizedFileURL.path
    let records =
      (try? await BookCatalogStore(root: AppPaths.bookCatalogRoot).scan().records) ?? []
    return records.filter {
      let path = URL(fileURLWithPath: $0.outputDirectory).standardizedFileURL.path
      return path != root && path.hasPrefix(root + "/")
    }.count
  }

  // MARK: - Library relocation

  func confirmPendingMove() {
    guard let pending = pendingMove else { return }
    pendingMove = nil
    guard let services, !isRelocating else { return }
    isRelocating = true
    notice = nil
    observeRelocation(services.relocation)
    Task { await runRelocation(pending, service: services.relocation) }
  }

  func cancelPendingMove() { pendingMove = nil }

  private func runRelocation(
    _ pending: PendingMove, service: LibraryRelocationService
  ) async {
    defer { isRelocating = false }
    do {
      try await service.relocate(to: pending.destination)
      let final = await service.currentSnapshot
      relocation = final
      let home = FileManager.default.homeDirectoryForCurrentUser
      directory =
        (try? await store.load())?.resolvedProcessedDirectory(home: home)
        ?? pending.destination
      if final.failures.isEmpty {
        let books = final.completed == 1 ? "book" : "books"
        notice = .information(
          "Moved \(final.completed) \(books) to \(pending.destination.path).")
      } else {
        let books = final.failures.count == 1 ? "book" : "books"
        notice = .failure(
          "\(final.failures.count) \(books) could not move and stay in the old "
            + "folder. Details are listed below.")
      }
    } catch {
      // Preconditions failed: nothing moved, nothing saved.
      notice = .failure(error.localizedDescription)
    }
  }

  /// Polls the shared relocation actor while a move runs — the same
  /// poll-and-render shape as the Library view's mirror banner.
  private func observeRelocation(_ service: LibraryRelocationService) {
    guard relocationPoll == nil else { return }
    relocationPoll = Task { [weak self] in
      defer { self?.relocationPoll = nil }
      while !Task.isCancelled {
        guard let self, self.isRelocating else { return }
        let snapshot = await service.currentSnapshot
        if snapshot.sequence != (self.relocation?.sequence ?? 0) {
          self.relocation = snapshot
        }
        try? await Task.sleep(for: .milliseconds(400))
      }
    }
  }

  // MARK: - First-run onboarding

  /// Creates the chosen folder and writes `studio-settings.json`, which ends
  /// onboarding permanently. Returns an error message to show inline, or nil
  /// on success.
  func completeOnboarding(path: String) async -> String? {
    let expanded = (path as NSString).expandingTildeInPath
    guard (expanded as NSString).isAbsolutePath else {
      return "Enter an absolute path, or one starting with ~."
    }
    let url = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
      !isDirectory.boolValue {
      return "That path exists but is a file, not a folder."
    }
    do {
      try FileManager.default.createDirectory(
        at: url, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o755])
      let home = FileManager.default.homeDirectoryForCurrentUser
      let defaultPath = home.appendingPathComponent("Books/SpokenFolio", isDirectory: true)
        .standardizedFileURL.path
      try await store.save(
        StudioSettings(processedDirectory: url.path == defaultPath ? nil : url.path))
      directory = (try await store.load()).resolvedProcessedDirectory(home: home)
      return nil
    } catch {
      return error.localizedDescription
    }
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
      Section("Book Library") {
        LabeledContent("Folder") {
          Text(model.directory.path)
            .lineLimit(2)
            .truncationMode(.middle)
            .textSelection(.enabled)
        }
        Text(
          "All book files — imported EPUBs, Storyteller downloads, TTS audiobooks, and TTS ReadAlouds — are stored here, one folder per book. Changing the location moves your whole library."
        )
        .foregroundStyle(.secondary)
        if model.isRelocating {
          HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(relocationProgressText)
              .foregroundStyle(.secondary)
          }
        }
        HStack {
          Button("Choose Folder…") { model.chooseDirectory() }
          Button("Restore Default") { model.resetDirectory() }
          Button("Reveal in Finder") { model.revealDirectory() }
        }
        .disabled(model.isRelocating)
      }
      relocationFailures
      notice
    }
    .formStyle(.grouped)
    .disabled(model.isLoading)
    .alert(
      "Move your book library?",
      isPresented: Binding(
        get: { model.pendingMove != nil },
        set: { if !$0 { model.cancelPendingMove() } }),
      presenting: model.pendingMove
    ) { pending in
      Button("Move \(pending.bookCount) \(pending.bookCount == 1 ? "Book" : "Books")") {
        model.confirmPendingMove()
      }
      Button("Cancel", role: .cancel) { model.cancelPendingMove() }
    } message: { pending in
      Text("Move \(pending.bookCount) \(pending.bookCount == 1 ? "book" : "books") to \(pending.destination.path)? Every book folder moves to the new location.")
    }
  }

  private var relocationProgressText: String {
    guard let snapshot = model.relocation, snapshot.total > 0 else {
      return "Preparing to move your library…"
    }
    let position = min(snapshot.completed + 1, snapshot.total)
    let title = snapshot.currentTitle ?? "…"
    return "Moving \(title) (\(position)/\(snapshot.total))…"
  }

  @ViewBuilder private var relocationFailures: some View {
    if let snapshot = model.relocation, !model.isRelocating, !snapshot.failures.isEmpty {
      Section("Books that did not move") {
        ForEach(Array(snapshot.failures.enumerated()), id: \.offset) { _, failure in
          Label {
            Text("\(failure.title): \(failure.reason)").textSelection(.enabled)
          } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
          }
        }
      }
    }
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

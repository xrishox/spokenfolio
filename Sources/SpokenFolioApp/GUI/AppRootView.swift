import SwiftUI

struct AppRootView: View {
  @Bindable var runtime: ApplicationRuntime
  @Bindable var create: StudioCreateModel
  @State private var library: StudioLibraryModel
  @State private var storyteller = StorytellerStudioModel()
  @State private var tools = ReadAloudToolsModel()

  init(runtime: ApplicationRuntime, create: StudioCreateModel) {
    self.runtime = runtime
    self.create = create
    _library = State(initialValue: StudioLibraryModel(coordinator: runtime.coordinator))
  }

  var body: some View {
    NavigationSplitView {
      List(selection: selection) {
        Section("Books") {
          sidebar(.production)
          sidebar(.library)
          sidebar(.quality)
        }
        Section("System") {
          sidebar(.server)
          sidebar(.settings)
        }
      }
      .listStyle(.sidebar)
      .navigationSplitViewColumnWidth(min: 170, ideal: 205, max: 250)
      .navigationTitle("SpokenFolio")
    } detail: {
      Group {
        switch runtime.navigation.selection {
        case .production:
          ProductionWorkspaceView(
            create: create, coordinator: runtime.coordinator,
            mode: Binding(
              get: { runtime.navigation.productionMode },
              set: { runtime.navigation.productionMode = $0 }),
            openLibrary: { _ in runtime.navigation.select(.library) })
        case .library:
          libraryView
        case .quality:
          ReadAloudQualityView(model: runtime.quality)
        case .server:
          ServerView(runtime: runtime)
        case .settings:
          AppSettingsView(model: runtime.settings, tools: tools, storyteller: storyteller)
        }
      }
      .navigationTitle(runtime.navigation.selection.title)
      .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
    }
    // Balanced keeps the detail column beside the sidebar. Prominent-detail
    // lays the detail out underneath the sidebar, so nested split views size
    // themselves against the whole window and collapse their trailing pane.
    .navigationSplitViewStyle(.balanced)
    .task {
      // Single owner of the queued-navigation callback; nested views must not
      // reassign it or the last-appearing view silently wins.
      create.onQueued = {
        runtime.navigation.productionMode = .queue
        runtime.navigation.select(.production)
      }
      create.useProcessedDirectory(runtime.settings.directory)
      await create.start()
    }
    .onChange(of: runtime.settings.directory) { _, directory in
      create.useProcessedDirectory(directory)
    }
  }

  private var libraryView: some View {
    StudioLibraryView(
      model: library,
      processedDirectory: runtime.settings.directory,
      queueQualityChecks: { targets in
        runtime.quality.enqueue(targets)
        runtime.navigation.select(.quality)
      },
      openQueue: {
        runtime.navigation.productionMode = .queue
        runtime.navigation.select(.production)
      })
  }

  private var selection: Binding<AppSection?> {
    // Deselection is deliberately impossible: one section is always active,
    // so a Cmd-click on the selected sidebar row keeps the current section.
    Binding(
      get: { runtime.navigation.selection },
      set: { if let value = $0 { runtime.navigation.select(value) } })
  }

  @ViewBuilder private func sidebar(_ section: AppSection) -> some View {
    HStack(spacing: 8) {
      Label(section.title, systemImage: section.icon)
      Spacer(minLength: 6)
      if section == .production {
        countBadge(runtime.coordinator.runningCount + runtime.coordinator.queuedCount, label: "jobs")
      } else if section == .quality {
        countBadge(
          runtime.quality.queuedCount + (runtime.quality.isBusy ? 1 : 0),
          label: "quality checks")
      } else if section == .server {
        Image(systemName: serverBadge)
          .foregroundStyle(serverBadgeColor)
          .accessibilityLabel(serverBadgeLabel)
      }
    }
    .tag(section)
  }

  @ViewBuilder private func countBadge(_ count: Int, label: String) -> some View {
    if count > 0 {
      Text("\(count)")
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .accessibilityLabel("\(count) \(label)")
    }
  }

  private var serverBadge: String {
    switch runtime.serverState {
    case .ready: "checkmark.circle.fill"
    case .degraded, .failed: "exclamationmark.triangle.fill"
    case .starting: "clock"
    case .stopped: "stop.circle"
    }
  }

  private var serverBadgeLabel: String {
    switch runtime.serverState {
    case .ready: "TTS Server ready"
    case .degraded: "TTS Server needs attention"
    case .failed: "TTS Server failed"
    case .starting: "TTS Server starting"
    case .stopped: "TTS Server stopped"
    }
  }

  private var serverBadgeColor: Color {
    switch runtime.serverState {
    case .ready: .green
    case .degraded, .failed: .orange
    default: .secondary
    }
  }
}

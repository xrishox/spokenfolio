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
          sidebar(.create)
          sidebar(.library)
          sidebar(.activity)
        }
        Section("Services") {
          sidebar(.storyteller)
          sidebar(.server)
        }
        Section("Maintenance") {
          sidebar(.tools)
          sidebar(.settings)
        }
      }
      .navigationSplitViewColumnWidth(min: 150, ideal: 180)
    } detail: {
      switch runtime.navigation.selection {
      case .create: StudioCreateView(model: create)
      case .library:
        StudioLibraryView(model: library) { record in
          guard let source = record.product(.sourceEPUB) else { return }
          create.addBooks([URL(fileURLWithPath: source.path)])
          runtime.navigation.select(.create)
        }
      case .activity: ActivityView(coordinator: runtime.coordinator)
      case .storyteller: StorytellerView(model: storyteller)
      case .server: ServerView(runtime: runtime)
      case .tools: ToolsView(model: tools)
      case .settings: AppSettingsView(model: runtime.settings)
      }
    }
    .task {
      create.onQueued = { runtime.navigation.select(.activity) }
      create.useProcessedDirectory(runtime.settings.directory)
    }
    .onChange(of: runtime.settings.directory) { _, directory in
      create.useProcessedDirectory(directory)
    }
  }

  private var selection: Binding<AppSection?> {
    Binding(
      get: { runtime.navigation.selection },
      set: { if let value = $0 { runtime.navigation.select(value) } })
  }

  @ViewBuilder private func sidebar(_ section: AppSection) -> some View {
    HStack {
      Label(section.rawValue, systemImage: section.icon)
      Spacer()
      if section == .activity {
        let count = runtime.coordinator.runningCount + runtime.coordinator.queuedCount
        if count > 0 { Text("\(count)").font(.caption).foregroundStyle(.secondary) }
      } else if section == .server {
        Image(systemName: serverBadge).foregroundStyle(serverBadgeColor)
      }
    }.tag(section)
  }

  private var serverBadge: String {
    switch runtime.serverState {
    case .ready: "checkmark.circle.fill"
    case .degraded, .failed: "exclamationmark.triangle.fill"
    case .starting: "clock"
    case .stopped: "stop.circle"
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

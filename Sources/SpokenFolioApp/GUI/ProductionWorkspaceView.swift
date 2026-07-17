import BookJobKit
import SwiftUI

struct ProductionWorkspaceView: View {
  @Bindable var create: StudioCreateModel
  @Bindable var coordinator: StudioJobCoordinator
  @Binding var mode: ProductionWorkspaceMode
  var openLibrary: ((UUID) -> Void)?

  @State private var confirmQueueCancellation = false

  init(
    create: StudioCreateModel, coordinator: StudioJobCoordinator,
    mode: Binding<ProductionWorkspaceMode>, openLibrary: ((UUID) -> Void)? = nil
  ) {
    self.create = create
    self.coordinator = coordinator
    _mode = mode
    self.openLibrary = openLibrary
  }

  var body: some View {
    VStack(spacing: 0) {
      workspaceHeader
      Divider()
      switch mode {
      case .create:
        CreateBatchView(model: create)
      case .queue, .history:
        ProductionJobsView(
          coordinator: coordinator, mode: mode, openLibrary: openLibrary)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .alert("Cancel waiting jobs?", isPresented: $confirmQueueCancellation) {
      Button("Cancel \(waitingCount) Waiting", role: .destructive) {
        Task { await coordinator.cancelWaitingJobs() }
      }
      if coordinator.runningCount > 0 {
        Button("Cancel All Including Current", role: .destructive) {
          Task { await coordinator.cancelWaitingJobs(includeActive: true) }
        }
      }
      Button("Keep Queue", role: .cancel) {}
    } message: {
      Text("Waiting jobs are cancelled immediately. Cancelling the current job safely persists intent before interrupting its child process.")
    }
  }

  private var workspaceHeader: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 12) { title; modePicker; Spacer(); queueActions; addBooks }
      VStack(alignment: .leading, spacing: 8) {
        HStack { title; Spacer(); addBooks }
        HStack(spacing: 10) { modePicker; Spacer(); queueActions }
      }
    }
    .padding(.horizontal, 16).padding(.vertical, 10)
    .background(.bar)
  }

  private var title: some View {
    VStack(alignment: .leading, spacing: 1) {
      Text("Production").font(.title2.bold())
      // Same "waiting" definition as the Cancel Waiting… button, or the
      // header can claim "0 waiting" while the button is visible.
      Text("\(coordinator.runningCount) running · \(waitingCount) waiting")
        .font(.caption).foregroundStyle(.secondary)
    }
  }

  private var modePicker: some View {
    Picker("Production view", selection: $mode) {
      ForEach(ProductionWorkspaceMode.allCases) { Text($0.rawValue).tag($0) }
    }
    .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 300)
  }

  @ViewBuilder private var queueActions: some View {
    if coordinator.isSuspended,
      coordinator.queuedCount > 0 || coordinator.runningCount > 0
    {
      Button("Resume Queue") { coordinator.resumeQueue() }
    } else if coordinator.queuedCount > 0 || coordinator.runningCount > 0 {
      Button(coordinator.runningCount > 0 ? "Pause After Current" : "Pause Queue") {
        coordinator.pauseQueue()
      }
    }
    if coordinator.runningCount > 0, !coordinator.isSuspended {
      Button("Pause Now") { coordinator.pauseQueue(interruptActive: true) }
    }
    if waitingCount > 0 {
      Button("Cancel Waiting…", role: .destructive) { confirmQueueCancellation = true }
    }
  }

  private var addBooks: some View {
    Button {
      mode = .create
      create.requestBooks()
    } label: {
      Label("Add EPUBs…", systemImage: "plus")
    }
    .buttonStyle(.borderedProminent)
    .keyboardShortcut("o", modifiers: .command)
  }

  private var waitingCount: Int {
    coordinator.rows.filter {
      ![.running, .completed, .cancelled].contains($0.state.lifecycle)
    }.count
  }
}

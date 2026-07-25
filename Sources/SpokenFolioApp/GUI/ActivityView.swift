import AppKit
import BookJobKit
import SwiftUI

/// Compatibility entry point for callers that still present Activity directly.
struct ActivityView: View {
  @Bindable var coordinator: StudioJobCoordinator

  var body: some View {
    ProductionJobsView(coordinator: coordinator, mode: .queue)
  }
}

struct ProductionJobsView: View {
  @Bindable var coordinator: StudioJobCoordinator
  let mode: ProductionWorkspaceMode
  var openLibrary: ((UUID) -> Void)?

  @State private var selection: Set<UUID> = []
  @State private var search = ""
  @State private var historySort: ProductionHistorySort = .newest
  @State private var confirmSelectedCancellation = false
  @State private var reorderNotice: String?

  init(
    coordinator: StudioJobCoordinator, mode: ProductionWorkspaceMode,
    openLibrary: ((UUID) -> Void)? = nil
  ) {
    self.coordinator = coordinator
    self.mode = mode
    self.openLibrary = openLibrary
  }

  var body: some View {
    VStack(spacing: 0) {
      issues
      if mode == .queue { activeSummary }
      commandStrip
      Divider()
      GeometryReader { geometry in
        // Split views do not stretch to fill on their own, and
        // .frame(maxHeight: .infinity) merely CENTERS a non-expanding split
        // in the leftover space (measured: a 153 pt table floating mid-pane).
        // Force the split to the exact available size.
        if geometry.size.width >= 760 {
          HSplitView {
            jobTable
              .frame(minWidth: 380, idealWidth: geometry.size.width * 0.58)
              .frame(maxHeight: .infinity)
              .layoutPriority(1)
            inspector
              .frame(minWidth: 300)
              .frame(maxWidth: .infinity, maxHeight: .infinity)
          }
          .frame(width: geometry.size.width, height: geometry.size.height)
        } else {
          VSplitView {
            jobTable
              .frame(minHeight: 190, idealHeight: geometry.size.height * 0.58)
              .frame(maxWidth: .infinity)
              .layoutPriority(1)
            inspector
              .frame(minHeight: 170)
              .frame(maxWidth: .infinity, maxHeight: .infinity)
          }
          .frame(width: geometry.size.width, height: geometry.size.height)
        }
      }
    }
    .searchable(text: $search, prompt: mode == .queue ? "Search queue" : "Search history")
    .task { await coordinator.reload() }
    .onChange(of: visibleRows.map(\.id)) { _, ids in
      selection.formIntersection(Set(ids))
    }
    .alert("Cancel selected jobs?", isPresented: $confirmSelectedCancellation) {
      Button("Cancel \(selection.count) Jobs", role: .destructive) {
        let ids = selection
        Task { await coordinator.cancelJobs(ids) }
      }
      Button("Keep Jobs", role: .cancel) {}
    } message: {
      Text("Waiting jobs are cancelled immediately. A running job is interrupted safely after cancellation intent is saved.")
    }
  }

  private var visibleRows: [StudioJobCoordinator.Row] {
    ProductionJobPresentation.rows(
      coordinator.rows, mode: mode, search: search, historySort: historySort)
  }

  private var selectedRows: [StudioJobCoordinator.Row] {
    coordinator.rows.filter { selection.contains($0.id) }
  }

  @ViewBuilder private var issues: some View {
    if let error = coordinator.error {
      Label(error, systemImage: "xmark.octagon.fill")
        .foregroundStyle(.red)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(.red.opacity(0.08))
    }
    if let notice = reorderNotice {
      HStack(spacing: 8) {
        Label(notice, systemImage: "arrow.up.arrow.down")
        Spacer()
        Button("Dismiss") { reorderNotice = nil }
      }
      .foregroundStyle(.orange)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 14).padding(.vertical, 7)
      .background(.orange.opacity(0.08))
    }
    if !coordinator.scanIssues.isEmpty {
      VStack(alignment: .leading, spacing: 2) {
        Label(
          "\(coordinator.scanIssues.count) unreadable job record\(coordinator.scanIssues.count == 1 ? "" : "s")",
          systemImage: "exclamationmark.triangle.fill")
          .font(.callout.bold())
        ForEach(coordinator.scanIssues.prefix(3), id: \.directory) { issue in
          Text("\(issue.directory): \(issue.message)")
            .font(.caption).lineLimit(2).textSelection(.enabled)
        }
      }
      .foregroundStyle(.orange)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 14).padding(.vertical, 7)
      .background(.orange.opacity(0.08))
    }
  }

  @ViewBuilder private var activeSummary: some View {
    if let active = primaryRunningRow {
      HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 2) {
          Text(active.request.title).font(.headline).lineLimit(1)
          Text(
            coordinator.isSuspended
              ? "\(ProductionJobPresentation.statusTitle(active)) · queue pauses after this job"
              : ProductionJobPresentation.statusTitle(active))
            .font(.caption).foregroundStyle(.secondary)
          // The delivery lane runs concurrently with synthesis; show it as a
          // second line rather than pretending only one job can run.
          if let delivery = deliveryRow, delivery.id != active.id {
            Label(
              "Delivering: \(delivery.request.title) · \(ProductionJobPresentation.statusTitle(delivery))",
              systemImage: "paperplane.fill")
              .font(.caption).foregroundStyle(.secondary).lineLimit(1)
          }
        }
        if let progress = ProductionJobPresentation.progress(active) {
          ProgressView(value: progress).frame(maxWidth: 320)
          Text(progress, format: .percent.precision(.fractionLength(0)))
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        } else {
          ProgressView().controlSize(.small)
        }
        Spacer()
        if coordinator.isSuspended {
          Button("Resume Queue") { coordinator.resumeQueue() }
        } else {
          Button("Pause Now") { coordinator.pauseQueue(interruptActive: true) }
        }
      }
      .padding(.horizontal, 14).padding(.vertical, 8)
      .background(.quaternary.opacity(0.3))
    } else if coordinator.isSuspended {
      HStack(spacing: 8) {
        Image(systemName: "pause.circle.fill").foregroundStyle(.orange)
        VStack(alignment: .leading, spacing: 1) {
          Text("Queue Paused").font(.callout.bold())
          Text("Unfinished work is safe. Resume when you are ready to continue.")
            .font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Button("Resume Queue") { coordinator.resumeQueue() }
          .buttonStyle(.borderedProminent)
      }
      .padding(.horizontal, 14).padding(.vertical, 8)
      .background(.orange.opacity(0.07))
    }
  }

  private var commandStrip: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 10) { commandContents }
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 10) { selectionCommands }
        HStack(spacing: 10) { modeCommands }
      }
    }
    .padding(.horizontal, 14).padding(.vertical, 9)
  }

  @ViewBuilder private var commandContents: some View {
    selectionCommands
    Spacer()
    modeCommands
  }

  @ViewBuilder private var selectionCommands: some View {
    if !selection.isEmpty, mode == .queue {
      Text("\(selection.count) selected").foregroundStyle(.secondary)
      if selectedRows.contains(where: canPause) {
        Button("Pause Selected") {
          let ids = selection
          Task { await coordinator.pauseJobs(ids) }
        }
      }
      if selectedRows.contains(where: canResume) {
        Button("Resume / Retry Selected") {
          let ids = selection
          Task { await coordinator.resumeJobs(ids) }
        }
      }
      Button("Cancel Selected…", role: .destructive) {
        confirmSelectedCancellation = true
      }
    } else {
      Text(mode == .queue ? "Durable FIFO" : "Completed work")
        .font(.callout).foregroundStyle(.secondary)
    }
  }

  @ViewBuilder private var modeCommands: some View {
    if mode == .history {
      Picker("Order", selection: $historySort) {
        ForEach(ProductionHistorySort.allCases) { Text($0.rawValue).tag($0) }
      }
      .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 260)
    }
    Text("\(visibleRows.count) job\(visibleRows.count == 1 ? "" : "s")")
      .foregroundStyle(.secondary)
    Button {
      Task { await coordinator.reload() }
    } label: {
      Label("Refresh", systemImage: "arrow.clockwise")
    }
  }

  private var jobTable: some View {
    Group {
      if visibleRows.isEmpty {
        ContentUnavailableView(
          mode == .queue ? "Queue Is Empty" : "No Job History",
          systemImage: mode == .queue ? "text.line.first.and.arrowtriangle.forward" : "clock.arrow.circlepath",
          description: Text(
            search.isEmpty
              ? (mode == .queue
                ? "Add EPUBs to create durable production jobs."
                : "Completed and cancelled production jobs appear here.")
              : "No jobs match your search."))
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if mode == .queue {
        queueList
      } else {
        historyTable
      }
    }
  }

  /// Fixed column widths shared by the queue header and rows. The queue is a
  /// `List` (Table cannot reorder rows), so the columns are hand-laid-out.
  private enum QueueColumn {
    static let position: CGFloat = 34
    static let kind: CGFloat = 150
    static let status: CGFloat = 190
    static let updated: CGFloat = 88
  }

  private var queueList: some View {
    let positions = queuePositionIndex
    return List(selection: $selection) {
      Section {
        ForEach(visibleRows) { row in
          queueRow(row, position: positions[row.id])
            .moveDisabled(row.state.lifecycle == .running || !queueOrderEditable)
            .contextMenu { queueRowMenu(row) }
        }
        .onMove(perform: moveRows)
      } header: {
        queueHeader
      }
    }
    .listStyle(.inset)
    .alternatingRowBackgrounds(.enabled)
  }

  private var queueHeader: some View {
    HStack(alignment: .center, spacing: 12) {
      Text("#").frame(width: QueueColumn.position, alignment: .leading)
      Text("Title").frame(maxWidth: .infinity, alignment: .leading)
      Text("Type").frame(width: QueueColumn.kind, alignment: .leading)
      Text("State / Progress").frame(width: QueueColumn.status, alignment: .leading)
      Text("Updated").frame(width: QueueColumn.updated, alignment: .leading)
    }
    .font(.caption).foregroundStyle(.secondary)
  }

  private func queueRow(_ row: StudioJobCoordinator.Row, position: Int?) -> some View {
    HStack(alignment: .center, spacing: 12) {
      Text(position.map(String.init) ?? "—").monospacedDigit()
        .foregroundStyle(.secondary)
        .frame(width: QueueColumn.position, alignment: .leading)
      VStack(alignment: .leading, spacing: 1) {
        Text(row.request.title).lineLimit(1)
        if let author = row.request.author, !author.isEmpty {
          Text(author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      Text(ProductionJobPresentation.kindTitle(row)).lineLimit(2)
        .frame(width: QueueColumn.kind, alignment: .leading)
      VStack(alignment: .leading, spacing: 3) {
        Label(ProductionJobPresentation.statusTitle(row), systemImage: statusIcon(row))
          .foregroundStyle(statusColor(row.state.lifecycle))
        if let progress = ProductionJobPresentation.progress(row) {
          ProgressView(value: progress)
        }
      }
      .frame(width: QueueColumn.status, alignment: .leading)
      Text(row.state.updatedAt, style: .relative).foregroundStyle(.secondary)
        .frame(width: QueueColumn.updated, alignment: .leading)
    }
    .padding(.vertical, 2)
  }

  @ViewBuilder private func queueRowMenu(_ row: StudioJobCoordinator.Row) -> some View {
    if row.state.lifecycle != .running {
      let order = movableQueueIDs
      let index = order.firstIndex(of: row.id)
      // Preemption: this book moves to the front, the running book pauses at
      // a safe chapter checkpoint, and it re-queues directly behind.
      Button("Run This Book Next") {
        Task {
          if let failure = await coordinator.runNext(row.id) { reorderNotice = failure }
        }
      }
      Divider()
      Button("Move to Top") { moveRow(row.id, toIndex: 0) }
        .disabled(index == nil || index == 0)
      Button("Move Up") { if let index { moveRow(row.id, toIndex: index - 1) } }
        .disabled(index == nil || index == 0)
      Button("Move Down") { if let index { moveRow(row.id, toIndex: index + 1) } }
        .disabled(index == nil || index == order.count - 1)
      Button("Move to Bottom") { moveRow(row.id, toIndex: order.count - 1) }
        .disabled(index == nil || index == order.count - 1)
    }
  }

  private var historyTable: some View {
    Table(visibleRows, selection: $selection) {
      TableColumn("Title") { row in
        VStack(alignment: .leading, spacing: 1) {
          Text(row.request.title).lineLimit(1)
          if let author = row.request.author, !author.isEmpty {
            Text(author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
          }
        }
      }
      TableColumn("Type") { row in
        Text(ProductionJobPresentation.kindTitle(row)).lineLimit(2)
      }
      TableColumn("Result") { row in
        Label(
          ProductionJobPresentation.statusTitle(row),
          systemImage: statusIcon(row.state.lifecycle))
          .foregroundStyle(statusColor(row.state.lifecycle))
      }
      TableColumn("Updated") { row in
        Text(row.state.updatedAt, style: .relative).foregroundStyle(.secondary)
      }
    }
  }

  private var inspector: some View {
    Group {
      if selectedRows.count == 1, let row = selectedRows.first {
        ProductionJobInspector(
          row: row, openLibrary: openLibrary,
          pause: mode == .queue && canPause(row) ? {
            Task { await coordinator.pauseJobs([row.id]) }
          } : nil,
          resume: mode == .queue && canResume(row) ? {
            Task { await coordinator.resumeJobs([row.id]) }
          } : nil,
          cancel: mode == .queue ? { confirmSelectedCancellation = true } : nil)
      } else if selectedRows.count > 1 {
        VStack(alignment: .leading, spacing: 10) {
          Text("\(selectedRows.count) Jobs Selected").font(.title2.bold())
          Text(
            mode == .queue
              ? "Use the selection actions above to pause, retry, or cancel this group."
              : "Select a single job to see its outcome and verified products.")
            .foregroundStyle(.secondary)
        }
        .padding(18).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      } else {
        ContentUnavailableView("Select a Job", systemImage: "doc.text.magnifyingglass")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
  }

  private var queuePositionIndex: [UUID: Int] {
    Dictionary(
      uniqueKeysWithValues: ProductionJobPresentation.rows(
        coordinator.rows, mode: .queue, search: ""
      ).enumerated().map { ($0.element.id, $0.offset + 1) })
  }

  /// Reordering must submit the complete waiting queue; a search filter hides
  /// rows, so drags are disabled until the filter is cleared. Menu moves stay
  /// available because they compute against the unfiltered order.
  private var queueOrderEditable: Bool {
    search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  /// The complete non-running, non-terminal queue (including held and
  /// needs-attention rows) in durable order — the exact array shape
  /// `StudioJobCoordinator.reorder` requires.
  private var movableQueueIDs: [UUID] {
    ProductionJobPresentation.rows(coordinator.rows, mode: .queue, search: "")
      .filter { $0.state.lifecycle != .running }
      .map(\.id)
  }

  private func moveRows(from source: IndexSet, to destination: Int) {
    guard queueOrderEditable else { return }
    var ids = visibleRows.map(\.id)
    ids.move(fromOffsets: source, toOffset: destination)
    let running = Set(
      visibleRows.filter { $0.state.lifecycle == .running }.map(\.id))
    applyOrder(ids.filter { !running.contains($0) })
  }

  private func moveRow(_ id: UUID, toIndex target: Int) {
    var order = movableQueueIDs
    guard let index = order.firstIndex(of: id) else { return }
    let clamped = min(max(target, 0), order.count - 1)
    guard clamped != index else { return }
    order.remove(at: index)
    order.insert(id, at: clamped)
    applyOrder(order)
  }

  private func applyOrder(_ orderedIDs: [UUID]) {
    Task {
      // `reorder` re-applies the scheduler snapshot itself; only a refusal
      // (queue changed underneath the drag) needs surfacing.
      reorderNotice = await coordinator.reorder(orderedIDs)
    }
  }

  /// The heavyweight production child, or — when only the delivery lane is
  /// busy — that job, so the summary never hides a running child.
  private var primaryRunningRow: StudioJobCoordinator.Row? {
    if let id = coordinator.activeJobID,
      let row = coordinator.rows.first(where: {
        $0.id == id && $0.state.lifecycle == .running
      })
    {
      return row
    }
    return coordinator.rows.first { $0.state.lifecycle == .running }
  }

  private var deliveryRow: StudioJobCoordinator.Row? {
    guard let id = coordinator.deliveryActiveJobID else { return nil }
    return coordinator.rows.first { $0.id == id && $0.state.lifecycle == .running }
  }

  private func canPause(_ row: StudioJobCoordinator.Row) -> Bool {
    row.state.lifecycle == .running
      || row.control.queueDisposition == .ready
      || row.control.queueDisposition == .retryReady
  }

  private func canResume(_ row: StudioJobCoordinator.Row) -> Bool {
    [.paused, .needsAttention].contains(row.state.lifecycle)
      || (row.state.lifecycle == .queued && row.control.queueDisposition == .held)
  }

  /// Row-aware icon: the concurrently running delivery-lane job gets a
  /// paperplane instead of the synthesis waveform.
  private func statusIcon(_ row: StudioJobCoordinator.Row) -> String {
    if row.state.lifecycle == .running, row.id == coordinator.deliveryActiveJobID {
      return "paperplane.fill"
    }
    return statusIcon(row.state.lifecycle)
  }

  private func statusIcon(_ lifecycle: BookJobLifecycle) -> String {
    switch lifecycle {
    case .queued: "clock"
    case .running: "waveform"
    case .paused: "pause.circle"
    case .needsAttention: "exclamationmark.triangle.fill"
    case .completed: "checkmark.circle.fill"
    case .cancelled: "xmark.circle"
    }
  }

  private func statusColor(_ lifecycle: BookJobLifecycle) -> Color {
    switch lifecycle {
    case .needsAttention: .orange
    case .completed: .green
    case .cancelled: .secondary
    default: .primary
    }
  }
}

private struct ProductionJobInspector: View {
  let row: StudioJobCoordinator.Row
  var openLibrary: ((UUID) -> Void)?
  var pause: (() -> Void)?
  var resume: (() -> Void)?
  var cancel: (() -> Void)?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        VStack(alignment: .leading, spacing: 4) {
          Text(row.request.title).font(.title2.bold()).textSelection(.enabled)
          if let author = row.request.author { Text(author).foregroundStyle(.secondary) }
          Label(
            ProductionJobPresentation.statusTitle(row),
            systemImage: row.state.lifecycle == .needsAttention
              ? "exclamationmark.triangle.fill" : "circle.fill")
            .foregroundStyle(row.state.lifecycle == .needsAttention ? .orange : .secondary)
        }

        if let error = row.state.lastError {
          VStack(alignment: .leading, spacing: 4) {
            Label("Needs attention", systemImage: "exclamationmark.triangle.fill")
              .font(.headline).foregroundStyle(.orange)
            Text(error).textSelection(.enabled)
          }
          .padding(10).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }

        if pause != nil || resume != nil || cancel != nil {
          HStack {
            if let resume { Button(row.state.lifecycle == .needsAttention ? "Retry" : "Resume", action: resume) }
            if let pause { Button("Pause", action: pause) }
            if let cancel { Button("Cancel…", role: .destructive, action: cancel) }
          }
        }

        inspectorSection("Overview") {
          InspectorValue("Job", ProductionJobPresentation.kindTitle(row))
          InspectorValue("Created", row.request.createdAt.formatted(date: .abbreviated, time: .shortened))
          InspectorValue("Updated", row.state.updatedAt.formatted(date: .abbreviated, time: .shortened))
          InspectorValue("Attempt", row.state.attempt.formatted())
          if let ordinal = row.request.batchOrdinal, let count = row.request.batchCount {
            InspectorValue("Batch position", "\(ordinal + 1) of \(count)")
          }
          if let progress = row.state.audiobookProgress {
            InspectorValue("Chapters", "\(progress.totalChapters)")
            if let title = progress.currentChapterTitle {
              InspectorValue("Current chapter", title)
            }
            if progress.totalUnits > 0 {
              InspectorValue("Current units", "\(progress.completedUnits) of \(progress.totalUnits)")
            }
          }
        }

        inspectorSection("Stages") {
          ForEach(applicableStages, id: \.stage) { stage in
            HStack(alignment: .top, spacing: 8) {
              Image(systemName: stageIcon(stage.status))
                .foregroundStyle(stageColor(stage.status)).frame(width: 16)
              VStack(alignment: .leading, spacing: 2) {
                HStack {
                  Text(ProductionJobPresentation.stageTitle(stage.stage))
                  Spacer()
                  Text(ProductionJobPresentation.stageStatusTitle(stage.status))
                    .font(.caption).foregroundStyle(.secondary)
                }
                if let fraction = stage.fraction,
                  [.running, .paused, .needsAttention].contains(stage.status)
                {
                  ProgressView(value: fraction)
                }
                if let message = stage.message, !message.isEmpty {
                  Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
              }
            }
            .padding(.vertical, 3)
          }
        }

        inspectorSection("Requested Settings") {
          InspectorValue("Voice", row.request.narration.voiceID)
          InspectorValue("AAC", "\(row.request.narration.bitrateKbps) kbps")
          InspectorValue("Workers", row.request.narration.workers.formatted())
          InspectorValue("Paragraph pause", "\(row.request.narration.paragraphPauseSeconds.formatted()) s")
          InspectorValue("Chapter pause", "\(row.request.narration.chapterPauseSeconds.formatted()) s")
          InspectorValue("Chapter titles", row.request.narration.announceTitles ? "Announced" : "Not announced")
          if let readAloud = row.request.readAloud {
            InspectorValue("ReadAloud", "Opus \(readAloud.opusBitrateKbps) kbps")
            InspectorValue(
              "Speech recognition",
              readAloud.resolvedASREngineID == "apple"
                ? "Apple Speech" : "Whisper · \(readAloud.resolvedASRModelID ?? "default")")
          }
          if let delivery = row.request.storyteller {
            InspectorValue("Storyteller", delivery.connectionID.uuidString.lowercased())
            InspectorValue(
              "Send", delivery.products.map(productTitle).sorted().joined(separator: ", "))
          }
        }

        if let actual = row.state.actualNarration {
          inspectorSection("Actual Siri Runtime") {
            InspectorValue("Backend / model", "\(actual.backendID) · \(actual.modelID)")
            InspectorValue("Voice", actual.voiceID)
            if let revision = actual.voiceRevision { InspectorValue("Voice revision", revision) }
            if let runtime = actual.runtime {
              InspectorValue("macOS", "\(runtime.macOSVersion) (\(runtime.macOSBuild))")
              InspectorValue("Framework", "\(runtime.frameworkIdentifier) \(runtime.frameworkVersion)")
            }
          }
        }

        if !row.state.products.isEmpty {
          inspectorSection("Verified Products") {
            ForEach(row.state.products, id: \.kind) { product in
              HStack {
                VStack(alignment: .leading, spacing: 2) {
                  Text(productTitle(product.kind)).font(.callout.bold())
                  Text("\(byteCount(product.size)) · \(product.verifiedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Reveal") {
                  NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: product.path)])
                }
              }
            }
          }
        }

        if !row.state.warnings.isEmpty {
          inspectorSection("Warnings") {
            ForEach(Array(row.state.warnings.enumerated()), id: \.offset) { _, warning in
              Label(warning, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange).textSelection(.enabled)
            }
          }
        }

        if let catalogID = row.request.catalogID, let openLibrary {
          Button("Open in Library") { openLibrary(catalogID) }
        }
      }
      .padding(18).frame(maxWidth: 720, alignment: .leading)
    }
  }

  private var applicableStages: [BookJobStageState] {
    row.state.stages.filter { stage in
      if stage.status != .pending { return true }
      switch stage.stage {
      case .preparation, .m4bSynthesis, .m4bAssembly, .m4bVerification:
        return row.request.resolvedOperation == .production
      case .readAloudAudioProcessing, .readAloudTranscription, .readAloudMarkup,
        .readAloudAlignment, .readAloudVerification:
        return row.request.readAloud != nil
      case .storytellerPreflight, .storytellerUpload, .storytellerReconciliation:
        return row.request.storyteller != nil
      }
    }
  }

  @ViewBuilder private func inspectorSection<Content: View>(
    _ title: String, @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      Text(title).font(.headline)
      content()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func stageIcon(_ status: BookJobStageStatus) -> String {
    switch status {
    case .pending: "circle"
    case .running: "circle.dotted"
    case .succeeded: "checkmark.circle.fill"
    case .failed, .needsAttention: "exclamationmark.triangle.fill"
    case .paused: "pause.circle.fill"
    case .skipped: "minus.circle"
    }
  }

  private func stageColor(_ status: BookJobStageStatus) -> Color {
    switch status {
    case .succeeded: .green
    case .failed, .needsAttention: .orange
    case .running: .accentColor
    default: .secondary
    }
  }

  private func productTitle(_ kind: BookProductKind) -> String {
    switch kind {
    case .sourceEPUB: "EPUB"
    case .m4b: "M4B"
    case .readAloudEPUB: "ReadAloud"
    }
  }

  private func byteCount(_ count: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(clamping: count), countStyle: .file)
  }
}

private struct InspectorValue: View {
  let label: String
  let value: String

  init(_ label: String, _ value: String) {
    self.label = label
    self.value = value
  }

  var body: some View {
    LabeledContent(label) {
      Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
    }
    .font(.callout)
  }
}

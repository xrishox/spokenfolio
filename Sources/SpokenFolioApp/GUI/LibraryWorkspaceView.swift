import AppKit
import BookJobKit
import LibraryKit
import ReadAloudKit
import SwiftUI

struct StudioLibraryView: View {
  @Bindable var model: StudioLibraryModel
  let processedDirectory: URL
  let queueQualityChecks: ([LibraryReadAloudAuditTarget]) -> Void
  let openQueue: () -> Void

  // The scope filter survives relaunches, matching the WebUI's remembered tab.
  @AppStorage("libraryFilter") private var storedFilter = StudioLibraryFilter.all.rawValue
  @State private var query = StudioLibraryQuery()
  @State private var sortOrder = [KeyPathComparator(\StudioLibraryRow.title)]
  @State private var showCompactInspector = false
  @State private var downloadChoice: DownloadChoice?
  @State private var deleteChoice: DeleteChoice?

  private var visibleRows: [StudioLibraryRow] {
    query.apply(to: model.rows).sorted(using: sortOrder)
  }

  private var selectedRows: [StudioLibraryRow] {
    model.rows.filter { model.selectedRowIDs.contains($0.id) }
  }

  private var selectedRow: StudioLibraryRow? {
    guard model.selectedRowIDs.count == 1, let id = model.selectedRowIDs.first else { return nil }
    return model.rows.first { $0.id == id }
  }

  var body: some View {
    GeometryReader { geometry in
      let compact = geometry.size.width < 820
      VStack(spacing: 0) {
        header(compact: compact)
        serverSlotsLegend
        statusBanners
        if model.selectedRowCount > 0 && (compact || model.selectedRowCount > 1) {
          selectionActions(compact: compact)
          Divider()
        }
        if model.rows.isEmpty {
          ContentUnavailableView(
            "No Books", systemImage: "books.vertical",
            description: Text("Add EPUBs, or compare with a Storyteller connection."))
        } else if visibleRows.isEmpty {
          ContentUnavailableView {
            Label(
              query.searchText.isEmpty ? "No Books in This Filter" : "No Matching Books",
              systemImage: "line.3.horizontal.decrease.circle")
          } description: {
            Text(
              query.searchText.isEmpty
                ? "No books match the \(query.filter.rawValue) filter."
                : "Nothing in \(query.filter.rawValue) matches “\(query.searchText)”.")
          } actions: {
            if query.filter != .all {
              Button("Show All Books") { query.filter = .all }
            }
            if !query.searchText.isEmpty {
              Button("Clear Search") { query.searchText = "" }
            }
          }
        } else if compact {
          libraryTable(compact: true)
        } else {
          // Splits must be forced to the available size; see ActivityView.
          GeometryReader { split in
            HSplitView {
              libraryTable(compact: false)
                .frame(minWidth: 500, idealWidth: 620)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
              inspector
                .frame(minWidth: 340, idealWidth: 400, maxWidth: 520)
                .frame(maxHeight: .infinity)
            }
            .frame(width: split.size.width, height: split.size.height)
          }
        }
      }
      .sheet(isPresented: $showCompactInspector) {
        inspector
          .frame(idealWidth: 520, idealHeight: 650)
      }
    }
    .task { await model.reload() }
    .onAppear {
      query.filter = StudioLibraryFilter(rawValue: storedFilter) ?? .all
    }
    .onChange(of: query.filter) { _, value in
      storedFilter = value.rawValue
    }
    .sheet(item: $downloadChoice) { choice in
      StudioDownloadFormatsSheet(model: model, choice: choice)
    }
    .sheet(item: $deleteChoice) { choice in
      LibraryDeleteSheet(model: model, choice: choice)
    }
    .sheet(item: $model.processing) { processing in
      LibraryProcessSheet(model: processing)
    }
    .sheet(item: $model.pendingRecord) { record in
      StudioLibraryMatchSheet(model: model, record: record)
    }
    .sheet(item: $model.pendingIdentifierRecord) { record in
      StudioIdentifierSheet(model: model, record: record)
    }
    .sheet(item: $model.pendingProcessingRow) { row in
      StudioProcessingSheet(model: model, row: row)
    }
  }

  private func beginProcessing(_ rows: [StudioLibraryRow], intent: LibraryProcessModel.Intent) {
    model.beginProcessing(
      rows, intent: intent, processedDirectory: processedDirectory, onViewQueue: openQueue)
  }

  @ViewBuilder private func header(compact: Bool) -> some View {
    let title = HStack(spacing: 8) {
      Text("Library").font(.title2.bold())
      Text("\(visibleRows.count) of \(model.rows.count)")
        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
      if model.isRefreshing { ProgressView().controlSize(.small) }
    }
    let source = Picker(
      "Compare with",
      selection: Binding(
        get: { model.connectionID },
        set: { model.selectConnection($0) })
    ) {
      Text("Local only").tag(UUID?.none)
      ForEach(model.connections) { connection in
        Text("\(connection.displayName) — \(connection.username)").tag(Optional(connection.id))
      }
    }
    let search = HStack(spacing: 6) {
      Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
      TextField("Search title, author, ISBN, or ASIN", text: $query.searchText)
        .textFieldStyle(.plain)
      if !query.searchText.isEmpty {
        Button {
          query.searchText = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Clear Search")
      }
    }
    .padding(.horizontal, 8).padding(.vertical, 6)
    .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
    let filter = Menu {
      ForEach(StudioLibraryFilter.allCases) { value in
        Button {
          query.filter = value
        } label: {
          if query.filter == value {
            Label(value.rawValue, systemImage: "checkmark")
          } else {
            Text(value.rawValue)
          }
        }
      }
    } label: {
      Label(query.filter.rawValue, systemImage: "line.3.horizontal.decrease.circle")
    }
    let refresh = Button {
      Task { await model.reload() }
    } label: {
      Label("Refresh", systemImage: "arrow.clockwise")
    }
    .disabled(model.isRefreshing)
    let importBooks = Button {
      model.chooseImportBooks()
    } label: {
      Label("Import Books…", systemImage: "square.and.arrow.down")
    }
    .help("Import local EPUBs into the library.")
    .disabled(model.isImporting)
    // Mirror every Storyteller file that has no local copy; the mirror
    // service dedups, so a second click never double-downloads.
    let downloadAll = Button {
      downloadChoice = DownloadChoice(subtitle: "Every Storyteller book", rows: model.rows)
    } label: {
      Label("Download All…", systemImage: "arrow.down.circle")
    }
    .help(
      model.mirrorableRows.isEmpty
        ? "Every ready Storyteller file is already in the library."
        : "Download every Storyteller file without a local copy.")
    .disabled(model.mirrorSnapshot.isBusy || model.mirrorableRows.isEmpty)

    Group {
      if compact {
        VStack(alignment: .leading, spacing: 10) {
          HStack { title; Spacer(); refresh }
          source
          HStack { search; filter }
          HStack {
            importBooks
            if model.connectionID != nil { downloadAll }
            Spacer()
          }
        }
      } else {
        VStack(spacing: 10) {
          HStack { title; Spacer(); search.frame(idealWidth: 260, maxWidth: 360); filter; refresh }
          HStack {
            source.frame(maxWidth: 390)
            Spacer()
            importBooks
            if model.connectionID != nil { downloadAll }
          }
        }
      }
    }
    .padding(.horizontal, 16).padding(.vertical, 12)
  }

  @ViewBuilder private var statusBanners: some View {
    if model.snapshotStale, let connection = model.connections.first(where: { $0.id == model.connectionID }) {
      banner(
        "Showing the last saved snapshot for \(connection.displayName). Refresh when the server is available.",
        systemImage: "clock.arrow.circlepath", color: .orange)
    }
    if let error = model.error, !model.snapshotStale {
      banner(error, systemImage: "exclamationmark.triangle.fill", color: .red)
    }
    if !model.issues.isEmpty {
      banner(
        "\(model.issues.count) catalog entr\(model.issues.count == 1 ? "y is" : "ies are") unreadable.",
        systemImage: "exclamationmark.circle", color: .orange)
    }
    if model.editionGapCount > 0 {
      banner(
        "\(model.editionGapCount) book\(model.editionGapCount == 1 ? " has" : "s have") no library edition record; quality and coherence are unavailable for \(model.editionGapCount == 1 ? "it" : "them").",
        systemImage: "questionmark.circle", color: .orange)
    }
    // Storyteller download progress, scoped to the connection it describes.
    let mirror = model.mirrorSnapshot
    if mirror.connectionID == nil || mirror.connectionID == model.connectionID {
      if mirror.isBusy {
        banner(
          "Downloading from Storyteller… \(mirror.completed) of \(mirror.total)\(mirror.currentTitle.map { " — \($0)" } ?? "")",
          systemImage: "arrow.down.circle", color: .blue)
      } else if !mirror.failures.isEmpty, mirror.completed > 0 {
        banner(
          "Download finished with \(mirror.failures.count) failure\(mirror.failures.count == 1 ? "" : "s"): \(mirror.failures[0].title) — \(mirror.failures[0].reason)",
          systemImage: "exclamationmark.triangle.fill", color: .orange)
      }
    }
    if model.isImporting {
      banner(
        "Importing \(model.importCompleted + 1) of \(model.importTotal)…",
        systemImage: "square.and.arrow.down", color: .blue)
    } else if !model.importFailures.isEmpty {
      banner(
        "\(model.importFailures.count) import failure\(model.importFailures.count == 1 ? "" : "s"): "
          + model.importFailures.map { "\($0.title) — \($0.reason)" }.joined(separator: "; "),
        systemImage: "exclamationmark.triangle.fill", color: .orange)
    }
  }

  private func banner(_ message: String, systemImage: String, color: Color) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: systemImage).foregroundStyle(color)
      Text(message).font(.callout).textSelection(.enabled)
      Spacer()
    }
    .padding(.horizontal, 16).padding(.vertical, 8)
    .background(color.opacity(0.09))
  }

  private func selectionActions(compact: Bool) -> some View {
    let localQuality = model.selectedQualityTargets(.local)
    let remoteQuality = model.selectedQualityTargets(.storyteller)
    let allQuality = model.selectedQualityTargets(.all)
    let selected = model.selectedRows
    return ViewThatFits(in: .horizontal) {
      HStack(spacing: 10) {
        Text("\(model.selectedRowCount) selected").font(.headline)
        selectionButtons(
          selected: selected, localQuality: localQuality,
          remoteQuality: remoteQuality, allQuality: allQuality)
        Spacer()
        if compact, model.selectedRowCount == 1 {
          Button("Details…") { showCompactInspector = true }
        }
        Button("Clear") { model.selectedRowIDs.removeAll() }
      }
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text("\(model.selectedRowCount) selected").font(.headline)
          Spacer()
          if compact, model.selectedRowCount == 1 {
            Button("Details…") { showCompactInspector = true }
          }
          Button("Clear") { model.selectedRowIDs.removeAll() }
        }
        HStack(spacing: 10) {
          selectionButtons(
            selected: selected, localQuality: localQuality,
            remoteQuality: remoteQuality, allQuality: allQuality)
        }
      }
    }
    .padding(.horizontal, 16).padding(.vertical, 10)
    .background(.bar)
  }

  @ViewBuilder private func selectionButtons(
    selected: [StudioLibraryRow],
    localQuality: [LibraryReadAloudAuditTarget],
    remoteQuality: [LibraryReadAloudAuditTarget],
    allQuality: [LibraryReadAloudAuditTarget]
  ) -> some View {
    Button("Process \(selected.count) Book\(selected.count == 1 ? "" : "s")…") {
      beginProcessing(selected, intent: .process)
    }
    .buttonStyle(.borderedProminent)
    .disabled(selected.isEmpty)
    let mirrorable = selected.filter(StudioLibraryModel.mirrorable)
    if !mirrorable.isEmpty {
      Button("Download to Library (\(mirrorable.count))") {
        downloadChoice = DownloadChoice(
          subtitle: "\(mirrorable.count) selected book\(mirrorable.count == 1 ? "" : "s")",
          rows: mirrorable)
      }
      .disabled(model.mirrorSnapshot.isBusy)
      .help("Download the selected books' Storyteller files without a local copy.")
    }
    let verifiable = selected.filter { $0.record != nil && $0.remote != nil }
    if !verifiable.isEmpty {
      Button("Verify Storyteller Files (\(verifiable.count))") {
        model.verifyRemote(verifiable)
      }
      .disabled(model.isVerifyingRemote)
      .help(
        "Recheck which of the selected books' files are on Storyteller by "
          + "hashing the server copies.")
    }
    Menu("Check Quality") {
      Button("Local ReadAlouds (\(localQuality.count))") { queueQualityChecks(localQuality) }
        .disabled(localQuality.isEmpty)
      Button("Storyteller ReadAlouds (\(remoteQuality.count))") { queueQualityChecks(remoteQuality) }
        .disabled(remoteQuality.isEmpty)
      Button("All Available (\(allQuality.count))") { queueQualityChecks(allQuality) }
        .disabled(allQuality.isEmpty)
    }
    .fixedSize()
    Menu("Narration") {
      Button("Human") { model.assertSelectedNarration(.human) }
      Button("TTS") { model.assertSelectedNarration(.otherTTS) }
      Button("Unknown") { model.assertSelectedNarration(.unknown) }
    }
    .fixedSize()
    .disabled(!model.canAssertSelectedNarration || model.isBusy)
    .help(
      model.canAssertSelectedNarration
        ? "Set narration provenance on every selected Storyteller ReadAloud."
        : "Every selected book must have a ready Storyteller ReadAloud.")
    Button("Delete…", role: .destructive) {
      deleteChoice = DeleteChoice(rows: selected)
    }
    .disabled(selected.isEmpty)
    .help("Delete the selected books' files locally, on Storyteller, or both.")
  }

  private func libraryTable(compact: Bool) -> some View {
    Group {
      if compact {
        Table(visibleRows, selection: $model.selectedRowIDs, sortOrder: $sortOrder) {
          TableColumn("Title", value: \StudioLibraryRow.title) { row in
            titleCell(row)
          }
          .width(min: 180, ideal: 260)
          TableColumn("Completeness", value: \StudioLibraryRow.sortLevel) { row in
            completenessCell(row, lineLimit: 1)
          }
          .width(min: 95, ideal: 145)
          TableColumn("Slots", value: \StudioLibraryRow.sortSlots) { row in
            slotsCell(row)
          }
          .width(min: 150, ideal: 175)
          TableColumn("Quality", value: \StudioLibraryRow.sortQuality) { row in
            qualityCell(row)
          }
          .width(min: 100, ideal: 125)
        }
      } else {
        Table(visibleRows, selection: $model.selectedRowIDs, sortOrder: $sortOrder) {
          TableColumn("Title", value: \StudioLibraryRow.title) { row in
            titleCell(row)
          }
          .width(min: 180, ideal: 260)
          TableColumn("Completeness", value: \StudioLibraryRow.sortLevel) { row in
            completenessCell(row, lineLimit: 2)
          }
          .width(min: 95, ideal: 145)
          TableColumn("Slots", value: \StudioLibraryRow.sortSlots) { row in
            slotsCell(row)
          }
          .width(min: 150, ideal: 175)
          TableColumn("Narration", value: \StudioLibraryRow.sortNarration) { row in
            Label(row.narration.displayName, systemImage: narrationSymbol(row.narration))
              .font(.caption).lineLimit(1)
          }
          .width(min: 90, ideal: 120)
          TableColumn("Quality", value: \StudioLibraryRow.sortQuality) { row in
            qualityCell(row)
          }
          .width(min: 100, ideal: 125)
        }
      }
    }
    .alternatingRowBackgrounds(.enabled)
  }

  private func titleCell(_ row: StudioLibraryRow) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(row.title).lineLimit(1)
      if let author = row.author, !author.isEmpty {
        Text(author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
      }
      if row.suggestedRemote != nil {
        Label("Storyteller match — confirm", systemImage: "questionmark.circle.fill")
          .font(.caption).foregroundStyle(.orange).lineLimit(1)
      }
    }
    .padding(.vertical, 3)
  }

  /// The five-slot summary: EPUB, TTS audiobook/ReadAloud, human
  /// audiobook/ReadAloud. Green = verified local, blue = on Storyteller,
  /// orange = needs a decision, dash = missing.
  /// Server-state borders render only on the Storyteller-facing tabs, where
  /// the question "which copy is on the server" is the one being asked.
  private var showServerSlots: Bool {
    query.filter == .storyteller || query.filter == .linked
  }

  @ViewBuilder private var serverSlotsLegend: some View {
    if showServerSlots {
      HStack(spacing: 12) {
        Label("solid border: on Storyteller, verified identical to your local file",
          systemImage: "rectangle")
        Label("dashed border: a file is on Storyteller", systemImage: "rectangle.dashed")
      }
      .font(.caption2)
      .foregroundStyle(.secondary)
      .padding(.horizontal, 16)
      .padding(.vertical, 3)
    }
  }

  private func slotsCell(_ row: StudioLibraryRow) -> some View {
    let slots = row.slots
    let server = showServerSlots ? row.serverSlots : StudioLibraryRow.ServerSlots()
    return HStack(spacing: 7) {
      slotChip("E", slots.epub, "EPUB", server: server.epub)
      slotChip("A", slots.ttsAudiobook, "TTS audiobook", tag: "T", server: server.ttsAudiobook)
      slotChip("R", slots.ttsReadAloud, "TTS ReadAloud", tag: "T", server: server.ttsReadAloud)
      slotChip("A", slots.humanAudiobook, "Human audiobook", tag: "H", server: server.humanAudiobook)
      slotChip("R", slots.humanReadAloud, "Human ReadAloud", tag: "H", server: server.humanReadAloud)
    }
    .font(.caption.monospaced())
  }

  private func slotChip(
    _ letter: String, _ state: StudioLibraryRow.SlotState, _ name: String, tag: String? = nil,
    server: StudioLibraryRow.SlotServerState? = nil
  ) -> some View {
    // A solid border = the server copy is verified identical to the current
    // local file; a dashed border = a file is on the server for this slot.
    // No border = absent or not known; nothing is guessed.
    let serverNote = switch server {
    case .verifiedCurrent: " · on Storyteller (verified identical)"
    case .present: " · on Storyteller"
    case nil: ""
    }
    return HStack(spacing: 1) {
      if let tag {
        Text(tag).font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary)
      }
      Text(letter + mark(state))
        .foregroundStyle(color(state))
    }
    .padding(.horizontal, 3)
    .padding(.vertical, 1)
    .overlay {
      switch server {
      case .verifiedCurrent:
        RoundedRectangle(cornerRadius: 4).strokeBorder(color(state).opacity(0.9), lineWidth: 1)
      case .present:
        RoundedRectangle(cornerRadius: 4)
          .strokeBorder(
            color(state).opacity(0.7),
            style: StrokeStyle(lineWidth: 1, dash: [2.5, 2]))
      case nil:
        EmptyView()
      }
    }
    .help("\(name): \(describe(state))\(serverNote)")
    .accessibilityLabel("\(name) \(describe(state))\(serverNote)")
  }

  private func mark(_ state: StudioLibraryRow.SlotState) -> String {
    switch state {
    case .verified, .present: "✓"
    case .pending: "?"
    case .missing: "–"
    }
  }

  private func color(_ state: StudioLibraryRow.SlotState) -> Color {
    switch state {
    case .verified: .green
    case .present: .blue
    case .pending: .orange
    case .missing: Color.secondary.opacity(0.6)
    }
  }

  private func describe(_ state: StudioLibraryRow.SlotState) -> String {
    switch state {
    case .verified: "verified on this Mac"
    case .present: "on Storyteller"
    case .pending: "needs a decision"
    case .missing: "missing"
    }
  }

  private func completenessCell(_ row: StudioLibraryRow, lineLimit: Int) -> some View {
    HStack(spacing: 6) {
      completenessBadge(row.level)
      Text(row.level.label).font(.caption).lineLimit(lineLimit)
    }
  }

  private func qualityCell(_ row: StudioLibraryRow) -> some View {
    Label(row.qualityLabel, systemImage: qualitySymbol(row.qualityLabel))
      .font(.caption).lineLimit(1)
  }

  private var inspector: some View {
    Group {
      if let selectedRow {
        StudioLibraryInspector(
          model: model, row: selectedRow,
          beginProcessing: beginProcessing,
          queueQualityChecks: queueQualityChecks,
          requestDownload: { row in
            downloadChoice = DownloadChoice(subtitle: row.title, rows: [row])
          })
      } else if model.selectedRowCount > 1 {
        ContentUnavailableView(
          "\(model.selectedRowCount) Books Selected", systemImage: "checkmark.circle",
          description: Text("Use the visible batch actions above the Library."))
      } else {
        ContentUnavailableView(
          "Select a Book", systemImage: "sidebar.right",
          description: Text("Details, files, identity, and available actions appear here."))
      }
    }
    .background(.background)
  }

  private func completenessBadge(_ level: LibraryLevel) -> some View {
    Text("\(level.rawValue)")
      .font(.caption.bold()).monospacedDigit()
      .frame(width: 24, height: 24)
      .background(
        Color(hue: Double(level.rawValue) / 30.0, saturation: 0.70, brightness: 0.78),
        in: Circle())
      .foregroundStyle(.white)
      .accessibilityLabel("Completeness level \(level.rawValue), \(level.label)")
  }

  private func narrationSymbol(_ value: NarrationProvenance) -> String {
    switch value {
    case .human: "person.wave.2"
    case .spokenFolioTTS, .otherTTS: "waveform"
    case .unknown: "questionmark.circle"
    }
  }

  private func qualitySymbol(_ value: String) -> String {
    switch value {
    case "Likely correct": "checkmark.circle.fill"
    case "Broken", "Likely broken": "xmark.octagon.fill"
    case "Needs review", "Inconclusive": "exclamationmark.triangle.fill"
    default: "minus.circle"
    }
  }
}

/// Identifies one target set for the Storyteller format-chooser sheet, so the
/// header, selection bar, and inspector all present the same flow.
private struct DownloadChoice: Identifiable {
  let id = UUID()
  /// What the download applies to, shown under the sheet title.
  let subtitle: String
  let rows: [StudioLibraryRow]
}

/// Chooses which remote formats to pull for a set of books. Every format is
/// on by default; the model intersects the choice with what each book
/// actually has remotely and lacks locally, so nothing is re-downloaded.
private struct StudioDownloadFormatsSheet: View {
  @Bindable var model: StudioLibraryModel
  let choice: DownloadChoice
  @Environment(\.dismiss) private var dismiss

  @State private var includeEPUB = true
  @State private var includeAudiobook = true
  @State private var includeReadAloud = true

  private var chosenFormats: Set<LibraryRemoteFormat> {
    var formats: Set<LibraryRemoteFormat> = []
    if includeEPUB { formats.insert(.ebook) }
    if includeAudiobook { formats.insert(.audiobook) }
    if includeReadAloud { formats.insert(.readaloud) }
    return formats
  }

  /// Books that would actually download something, and roughly how many
  /// files that is — the per-book intersection of the chosen formats with
  /// what Storyteller has that is not yet local.
  private var plan: (books: Int, files: Int) {
    var books = 0
    var files = 0
    for row in choice.rows {
      let wanted = row.downloadableFormats.intersection(chosenFormats)
      guard !wanted.isEmpty else { continue }
      books += 1
      files += wanted.count
    }
    return (books, files)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Download from Storyteller").font(.title2.bold())
      Text(choice.subtitle).foregroundStyle(.secondary)
      Toggle("EPUB", isOn: $includeEPUB)
      Toggle("Human Audiobook", isOn: $includeAudiobook)
      Toggle("Human ReadAloud", isOn: $includeReadAloud)
      let plan = plan
      Text(
        plan.books == 0
          ? "Nothing to download — the checked formats are already local or not ready on Storyteller."
          : "\(plan.books) book\(plan.books == 1 ? "" : "s"), roughly \(plan.files) file\(plan.files == 1 ? "" : "s"). Formats already in the library are skipped."
      )
      .font(.caption).foregroundStyle(.secondary)
      HStack {
        Button("Cancel") { dismiss() }
        Spacer()
        Button("Download") {
          model.downloadFromStoryteller(choice.rows, formats: chosenFormats)
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(plan.books == 0 || model.mirrorSnapshot.isBusy)
      }
    }.padding(20).frame(idealWidth: 440)
  }
}

/// Identifies the set of books a Delete flow applies to.
private struct DeleteChoice: Identifiable {
  let id = UUID()
  let rows: [StudioLibraryRow]
}

/// Deletes selected product slots locally, on Storyteller, or both. One global
/// scope applies to every checked slot; each book acts only where the slot
/// exists in that scope (missing slots are silently skipped, never blocking).
/// Deleting the source EPUB removes the entire local book and is called out in
/// red; any human-narrated loss requires the acknowledgment before deleting.
private struct LibraryDeleteSheet: View {
  @Bindable var model: StudioLibraryModel
  let choice: DeleteChoice
  @Environment(\.dismiss) private var dismiss

  private enum Phase { case choose, running, done }

  // Slots default off — the user opts into exactly what they mean to destroy.
  @State private var deleteSource = false
  @State private var deleteM4B = false
  @State private var deleteReadAloud = false
  @State private var deleteHumanAudiobook = false
  @State private var deleteHumanReadAloud = false
  @State private var scope: LibraryDeletePlanner.Scope = .local
  @State private var acknowledged = false
  @State private var phase: Phase = .choose
  @State private var outcomes: [LibraryDeleteService.Outcome] = []

  private var slots: Set<BookProductKind> {
    var slots: Set<BookProductKind> = []
    if deleteSource { slots.insert(.sourceEPUB) }
    if deleteM4B { slots.insert(.m4b) }
    if deleteReadAloud { slots.insert(.readAloudEPUB) }
    if deleteHumanAudiobook { slots.insert(.humanAudiobook) }
    if deleteHumanReadAloud { slots.insert(.humanReadAloudEPUB) }
    return slots
  }

  private var selection: LibraryDeletePlanner.Selection { .init(slots: slots, scope: scope) }
  private var plan: LibraryDeletePlanner.Plan {
    LibraryDeletePlanner.plan(rows: choice.rows, selection: selection)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Delete").font(.title2.bold())
      Text(
        "\(choice.rows.count) selected book\(choice.rows.count == 1 ? "" : "s"). Choose what to delete and where."
      ).foregroundStyle(.secondary)

      switch phase {
      case .choose, .running: chooser
      case .done: summary
      }
    }
    .padding(20).frame(idealWidth: 520)
  }

  @ViewBuilder private var chooser: some View {
    Picker("Delete from", selection: $scope) {
      Text("Local").tag(LibraryDeletePlanner.Scope.local)
      Text("Storyteller").tag(LibraryDeletePlanner.Scope.storyteller)
      Text("Both").tag(LibraryDeletePlanner.Scope.both)
    }
    .pickerStyle(.segmented)
    .disabled(phase == .running)

    VStack(alignment: .leading, spacing: 4) {
      Toggle("TTS Audiobook (M4B)", isOn: $deleteM4B)
      Toggle("TTS ReadAloud", isOn: $deleteReadAloud)
      Toggle("Human Audiobook", isOn: $deleteHumanAudiobook)
      Toggle("Human ReadAloud", isOn: $deleteHumanReadAloud)
      Toggle(isOn: $deleteSource) {
        Text("Source EPUB — deletes the **entire local book**")
      }
      .tint(.red)
    }
    .disabled(phase == .running)

    let plan = plan
    manifest(plan)

    if needsAcknowledgment(plan) {
      Toggle(isOn: $acknowledged) {
        Text("I understand this permanently deletes the data above and cannot be undone.")
          .font(.callout)
      }
      .tint(.red)
      .disabled(phase == .running)
    }

    HStack {
      Button("Cancel") { dismiss() }.disabled(phase == .running)
      Spacer()
      if phase == .running { ProgressView().controlSize(.small) }
      Button("Delete", role: .destructive) {
        phase = .running
        let rows = choice.rows
        let selection = selection
        let ack = Set(plan.impacts.map(\.rowID))
        Task {
          let result = await model.performDelete(
            rows, selection: selection, acknowledgedRowIDs: acknowledged ? ack : [])
          outcomes = result
          phase = .done
        }
      }
      .keyboardShortcut(.defaultAction)
      .disabled(
        plan.impacts.isEmpty || phase == .running
          || (needsAcknowledgment(plan) && !acknowledged))
    }
  }

  private func needsAcknowledgment(_ plan: LibraryDeletePlanner.Plan) -> Bool {
    plan.impacts.contains { $0.wholeBookLocal || $0.losesHumanContent }
  }

  @ViewBuilder private func manifest(_ plan: LibraryDeletePlanner.Plan) -> some View {
    if plan.impacts.isEmpty {
      Text("Nothing to delete — none of the checked slots exist for these books in that scope.")
        .font(.caption).foregroundStyle(.secondary)
    } else {
      ScrollView {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(plan.impacts, id: \.rowID) { impact in
            VStack(alignment: .leading, spacing: 2) {
              Text(impact.title).font(.callout.bold())
              if impact.wholeBookLocal {
                Text("• Deletes the entire local book (source, every local file, and its folder)")
                  .font(.caption).foregroundStyle(.red)
              } else if !impact.localSlots.isEmpty {
                Text("• Local: \(impact.localSlots.map { Self.label($0.kind) }.joined(separator: ", "))")
                  .font(.caption)
              }
              if !impact.remoteSlots.isEmpty {
                Text(
                  "• Storyteller: "
                    + impact.remoteSlots.map {
                      $0.format.rawValue + ($0.humanNarration ? " (human)" : "")
                    }.joined(separator: ", ")
                )
                .font(.caption)
                .foregroundStyle(impact.remoteSlots.contains(where: \.humanNarration) ? .red : .primary)
              }
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: 180)
      if needsAcknowledgment(plan) {
        Text("Deleting the source removes the whole local book; human-narrated files cannot be re-created and must be re-downloaded from Storyteller.")
          .font(.caption).foregroundStyle(.red)
      }
    }
    if !plan.skipped.isEmpty {
      Text("Skipped (no checked slots present): \(plan.skipped.map(\.title).joined(separator: ", "))")
        .font(.caption).foregroundStyle(.secondary)
    }
  }

  @ViewBuilder private var summary: some View {
    let deleted = outcomes.filter { $0.didSomething }
    let blocked = outcomes.filter { $0.blocked != nil }
    let failed = outcomes.filter { !$0.failures.isEmpty }
    VStack(alignment: .leading, spacing: 6) {
      Text("\(deleted.count) book\(deleted.count == 1 ? "" : "s") updated.")
      if !blocked.isEmpty {
        Text("Skipped (busy): " + blocked.map { "\($0.title) — \($0.blocked ?? "")" }.joined(separator: "; "))
          .font(.caption).foregroundStyle(.orange)
      }
      if !failed.isEmpty {
        Text(
          "Failures: "
            + failed.flatMap { o in o.failures.map { "\(o.title): \($0.reason)" } }
              .joined(separator: "; ")
        )
        .font(.caption).foregroundStyle(.red)
      }
    }
    HStack {
      Spacer()
      Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
    }
  }

  private static func label(_ kind: BookProductKind) -> String {
    switch kind {
    case .sourceEPUB: "Source EPUB"
    case .m4b: "TTS Audiobook"
    case .readAloudEPUB: "TTS ReadAloud"
    case .humanAudiobook: "Human Audiobook"
    case .humanReadAloudEPUB: "Human ReadAloud"
    }
  }
}

private struct StudioLibraryInspector: View {
  @Bindable var model: StudioLibraryModel
  let row: StudioLibraryRow
  let beginProcessing: ([StudioLibraryRow], LibraryProcessModel.Intent) -> Void
  let queueQualityChecks: ([LibraryReadAloudAuditTarget]) -> Void
  let requestDownload: (StudioLibraryRow) -> Void

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        VStack(alignment: .leading, spacing: 4) {
          Text(row.title).font(.title3.bold()).textSelection(.enabled)
          if let author = row.author, !author.isEmpty {
            Text(author).foregroundStyle(.secondary).textSelection(.enabled)
          }
          Text("Level \(row.level.rawValue) · \(row.level.label)")
            .font(.callout.weight(.medium))
          Text(row.detail).font(.caption).foregroundStyle(.secondary)
        }

        if row.suggestedRemote != nil {
          suggestionSection
        }

        inspectorSection("Slots") {
          slotRow("EPUB", state: row.slots.epub)
          slotRow("TTS audiobook", state: row.slots.ttsAudiobook)
          slotRow("TTS ReadAloud", state: row.slots.ttsReadAloud)
          slotRow("Human audiobook", state: row.slots.humanAudiobook)
          slotRow("Human ReadAloud", state: row.slots.humanReadAloud)
          if let provenance = row.ttsProvenance {
            Text(provenance).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
          }
          HStack(spacing: 8) {
            // One flow covers create, recreate, download-from-Storyteller,
            // and delivery — the sheet adapts to what this book has.
            Button("Process…") { beginProcessing([row], .process) }
              .buttonStyle(.borderedProminent)
              .disabled(row.record == nil && row.remote?.asset(.ebook)?.state != .ready)
            if StudioLibraryModel.mirrorable(row) {
              Button("Download to Library") { requestDownload(row) }
                .disabled(model.mirrorSnapshot.isBusy)
                .help("Choose which Storyteller files to download, without processing.")
            }
            if let record = row.record {
              Button("Reveal Files") { NSWorkspace.shared.open(record.layout.directory) }
            }
          }
          if row.record == nil {
            Text(
              row.remote?.asset(.ebook)?.state == .ready
                ? "No local copy yet — Process downloads the EPUB from Storyteller first."
                : "No local copy, and Storyteller has no ready ebook to download.")
              .font(.caption).foregroundStyle(.secondary)
          }
        }

        inspectorSection("Storyteller") {
          if let remote = row.remote {
            remoteStatusLine("EPUB", asset: remote.asset(.ebook))
            remoteStatusLine("Audiobook", asset: remote.asset(.audiobook))
            remoteStatusLine("ReadAloud", asset: remote.asset(.readaloud))
            if let readAloud = remote.asset(.readaloud), readAloud.state == .processing {
              ProgressView(value: readAloud.stageProgress ?? 0) {
                Text(readAloud.currentStage ?? readAloud.status ?? "Processing")
              }
            }
            if remote.asset(.readaloud)?.state == .ready {
              LabeledContent("Narration") {
                Menu(row.narration.displayName) {
                  Button("Human") { model.assertNarration(row, provenance: .human) }
                  Button("TTS") { model.assertNarration(row, provenance: .otherTTS) }
                  Button("Unknown") { model.assertNarration(row, provenance: .unknown) }
                }
                .fixedSize()
              }
            } else if remote.asset(.ebook)?.state == .ready,
              remote.asset(.audiobook)?.state == .ready
            {
              Button("Create ReadAloud on Server…") { model.pendingProcessingRow = row }
                .help(
                  "Storyteller aligns its own ebook and audiobook on the server; nothing is downloaded.")
            }
          } else {
            Text(model.connectionID == nil ? "No Storyteller connection selected." : "Not linked on the selected server.")
              .foregroundStyle(.secondary)
          }
          if row.record != nil, !model.connections.isEmpty {
            Button("Send to Storyteller…") { beginProcessing([row], .sendOnly) }
              .help("Send existing products without creating anything new.")
          }
        }

        inspectorSection("ReadAloud Quality") {
          LabeledContent("Local", value: row.localQualityVerdict.map(readableVerdict) ?? "Not checked")
          LabeledContent("Storyteller", value: row.remoteQualityVerdict.map(readableVerdict) ?? "Not checked")
          let local = qualityTargets(.local)
          let remote = qualityTargets(.storyteller)
          let all = qualityTargets(.all)
          Menu("Check Quality") {
            Button("Local ReadAloud") { queueQualityChecks(local) }.disabled(local.isEmpty)
            Button("Storyteller ReadAloud") { queueQualityChecks(remote) }.disabled(remote.isEmpty)
            Button("Both") { queueQualityChecks(all) }.disabled(all.isEmpty)
          }
          .fixedSize()
          .disabled(all.isEmpty)
        }

        inspectorSection("Edition Identity") {
          identifierList
          if let record = row.record {
            AsinSectionView(model: model, row: row, record: record)
            actionGrid {
              Button("Correct ISBN…") { model.beginIdentifierEdit(row) }
              if let connectionID = model.connectionID {
                if record.remoteLinks.contains(where: {
                  $0.providerID == "storyteller" && $0.connectionID == connectionID
                }) {
                  Button("Verify Storyteller Files") {
                    model.verifyRemote([row])
                  }
                  .disabled(model.isVerifyingRemote)
                  .help(
                    "Recheck which of this book's files are on Storyteller by "
                      + "hashing the server copies.")
                  Button("Unlink Storyteller") {
                    model.forgetLink(record, connectionID: connectionID)
                  }
                } else {
                  Button("Match Edition…") { model.beginMatch(record) }
                }
              }
            }
          }
        }
      }
      .padding(16)
    }
  }

  private func qualityTargets(_ scope: StudioLibraryModel.QualityScope) -> [LibraryReadAloudAuditTarget] {
    var result: [LibraryReadAloudAuditTarget] = []
    if scope != .storyteller, row.localReadAloudReady, let id = row.localReadAloudProductID {
      result.append(.localProduct(id))
    }
    if scope != .local, let remote = row.remote, let asset = remote.asset(.readaloud),
      asset.state == .ready
    {
      result.append(.remote(
        connectionID: remote.connectionID, bookID: remote.remoteBookID,
        assetID: asset.assetID))
    }
    return result
  }

  @ViewBuilder private var identifierList: some View {
    // The ASIN renders in its own block below, with catalog resolution.
    let local = (row.record?.metadata.identifiers ?? []).filter {
      $0.kind?.lowercased().contains("asin") != true
    }
    let remote = row.remote?.identifiers ?? []
    if local.isEmpty, remote.isEmpty {
      Text("No edition identifiers recorded.").foregroundStyle(.secondary)
    } else {
      ForEach(Array(local.enumerated()), id: \.offset) { _, identifier in
        LabeledContent(identifier.kind ?? "Local", value: identifier.value)
          .textSelection(.enabled)
      }
      ForEach(Array(remote.enumerated()), id: \.offset) { _, identifier in
        LabeledContent(identifier.name ?? identifier.kind ?? "Storyteller", value: identifier.value)
          .textSelection(.enabled)
      }
    }
  }

  private func statusLine(_ name: String, ready: Bool) -> some View {
    Label(name, systemImage: ready ? "checkmark.circle.fill" : "minus.circle")
      .foregroundStyle(ready ? .primary : .secondary)
      .accessibilityValue(ready ? "Ready" : "Missing")
  }

  /// An unlinked Storyteller book that looks like this edition. Nothing is
  /// merged until the user decides; a wrong suggestion costs one click.
  private var suggestionSection: some View {
    VStack(alignment: .leading, spacing: 9) {
      Label("Storyteller has a matching book", systemImage: "questionmark.circle.fill")
        .font(.headline).foregroundStyle(.orange)
      if let suggested = row.suggestedRemote {
        Text(
          "\u{201C}\(suggested.title)\u{201D}\(suggested.authors.isEmpty ? "" : " — \(suggested.authors.joined(separator: ", "))") on the selected server has the same identity. Confirm whether it is this edition; nothing changes until you decide."
        )
        .font(.callout)
        HStack {
          Button("Same Edition — Link") { model.confirmSuggestedMatch(row) }
            .buttonStyle(.borderedProminent)
          Button("Different Edition — Keep Separate") { model.declineSuggestedMatch(row) }
        }
        .disabled(model.isBusy)
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
  }

  private func slotRow(_ name: String, state: StudioLibraryRow.SlotState) -> some View {
    LabeledContent {
      Label(slotDescription(state), systemImage: slotSymbol(state))
        .foregroundStyle(slotColor(state))
        .font(.callout)
    } label: {
      Text(name)
    }
    .accessibilityLabel("\(name): \(slotDescription(state))")
  }

  private func slotSymbol(_ state: StudioLibraryRow.SlotState) -> String {
    switch state {
    case .verified: "checkmark.seal.fill"
    case .present: "checkmark.icloud.fill"
    case .pending: "questionmark.circle.fill"
    case .missing: "minus.circle"
    }
  }

  private func slotColor(_ state: StudioLibraryRow.SlotState) -> Color {
    switch state {
    case .verified: .green
    case .present: .blue
    case .pending: .orange
    case .missing: .secondary
    }
  }

  private func slotDescription(_ state: StudioLibraryRow.SlotState) -> String {
    switch state {
    case .verified: "Verified on this Mac"
    case .present: "On Storyteller"
    case .pending: "Needs a decision"
    case .missing: "Missing"
    }
  }

  @ViewBuilder private func remoteStatusLine(
    _ name: String, asset: LibraryRemoteAssetSnapshot?
  ) -> some View {
    let state = asset?.state ?? .missing
    HStack {
      Label(name, systemImage: remoteStateSymbol(state))
      Spacer()
      Text(remoteStateLabel(state)).font(.caption).foregroundStyle(.secondary)
      if let size = asset?.fileSize {
        Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: size), countStyle: .file))
          .font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private func remoteStateSymbol(_ state: LibraryRemoteAssetState) -> String {
    switch state {
    case .ready: "checkmark.circle.fill"
    case .processing: "clock.arrow.circlepath"
    case .broken: "xmark.octagon.fill"
    case .unknown: "questionmark.circle"
    case .missing: "minus.circle"
    }
  }

  private func remoteStateLabel(_ state: LibraryRemoteAssetState) -> String {
    switch state {
    case .ready: "Ready"
    case .processing: "Processing"
    case .broken: "Broken"
    case .unknown: "Unknown"
    case .missing: "Missing"
    }
  }

  private func readableVerdict(_ value: String) -> String {
    switch value {
    case ReadAloudAuditVerdict.likelyCorrect.rawValue: "Likely correct"
    case ReadAloudAuditVerdict.needsReview.rawValue: "Needs review"
    case ReadAloudAuditVerdict.likelyBroken.rawValue: "Likely broken"
    case ReadAloudAuditVerdict.broken.rawValue: "Broken"
    case ReadAloudAuditVerdict.inconclusive.rawValue: "Inconclusive"
    default: value
    }
  }

  private func inspectorSection<Content: View>(
    _ title: String, @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 9) {
      Text(title).font(.headline)
      Divider()
      content()
    }
  }

  private func actionGrid<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    LazyVGrid(
      columns: [GridItem(.adaptive(minimum: 135), spacing: 8)],
      alignment: .leading, spacing: 8, content: content)
  }
}

/// Web-parity ASIN block for the Edition Identity section: shows the recorded
/// ASIN and what it identifies in the online catalog, with find-by-search and
/// manual-entry flows. Lookups are read-only; saving is an explicit action
/// through the shared identifier write path.
private struct AsinSectionView: View {
  @Bindable var model: StudioLibraryModel
  let row: StudioLibraryRow
  let record: BookCatalogRecord

  private enum Mode { case idle, manual, search }
  private enum Resolution {
    case checking
    case found(AsinCatalog.Candidate)
    case notFound
  }

  @State private var mode = Mode.idle
  @State private var manualValue = ""
  @State private var searchTitle = ""
  @State private var searchAuthor = ""
  @State private var candidates: [AsinCatalog.Candidate] = []
  @State private var selectedASIN: String?
  @State private var resolution = Resolution.checking
  @State private var isWorking = false
  @State private var sectionError: String?

  private var asin: String? {
    record.metadata.identifiers.first {
      $0.kind?.lowercased().contains("asin") == true
    }?.value
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if let asin {
        LabeledContent("ASIN", value: asin).textSelection(.enabled)
        resolutionLines
      } else {
        Text("No known ASIN for this book.").font(.caption).foregroundStyle(.secondary)
      }
      switch mode {
      case .idle: idleButtons
      case .manual: manualEditor
      case .search: searchEditor
      }
      if let sectionError {
        Text(sectionError).font(.caption).foregroundStyle(.red).textSelection(.enabled)
      }
    }
    .task(id: asin) { await resolveCurrent() }
  }

  @ViewBuilder private var resolutionLines: some View {
    switch resolution {
    case .checking:
      Text("Checking what this ASIN identifies…").font(.caption).foregroundStyle(.secondary)
    case .notFound:
      Text("This ASIN was not found in the online catalog.")
        .font(.caption).foregroundStyle(.secondary)
    case .found(let candidate):
      Text(identifiesLine(candidate))
        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
      if clearlyDiffers(candidate.title, row.title) {
        Label(
          "The book is named \u{201C}\(row.title)\u{201D} locally, but this ASIN identifies \u{201C}\(candidate.title)\u{201D}.",
          systemImage: "exclamationmark.triangle.fill")
          .font(.caption).foregroundStyle(.orange)
      }
    }
  }

  private var idleButtons: some View {
    HStack(spacing: 8) {
      Button(asin == nil ? "Find ASIN…" : "Find Different ASIN…") {
        searchTitle = row.title
        searchAuthor = row.author ?? ""
        candidates = []
        selectedASIN = nil
        sectionError = nil
        mode = .search
      }
      Button("Set ASIN…") {
        manualValue = asin ?? ""
        sectionError = nil
        mode = .manual
      }
    }
    .controlSize(.small)
  }

  private var manualEditor: some View {
    VStack(alignment: .leading, spacing: 6) {
      TextField("ASIN (10 characters, e.g. B0ABC12DEF)", text: $manualValue)
        .textFieldStyle(.roundedBorder)
      HStack(spacing: 8) {
        Button("Cancel") {
          mode = .idle
          sectionError = nil
        }
        Button("Save ASIN") { save(manualValue) }
          .disabled(
            manualValue.trimmingCharacters(in: .whitespaces).isEmpty || isWorking)
        if isWorking { ProgressView().controlSize(.small) }
      }
      .controlSize(.small)
    }
  }

  private var searchEditor: some View {
    VStack(alignment: .leading, spacing: 6) {
      TextField("Title", text: $searchTitle).textFieldStyle(.roundedBorder)
      TextField("Author (optional)", text: $searchAuthor).textFieldStyle(.roundedBorder)
      HStack(spacing: 8) {
        Button("Cancel") {
          mode = .idle
          sectionError = nil
        }
        Button(isWorking ? "Searching…" : "Search Catalog") { runSearch() }
          .disabled(searchTitle.trimmingCharacters(in: .whitespaces).isEmpty || isWorking)
        if isWorking { ProgressView().controlSize(.small) }
      }
      .controlSize(.small)
      if !candidates.isEmpty {
        candidateList
        Button("Save Selected ASIN") {
          if let selectedASIN { save(selectedASIN) }
        }
        .disabled(selectedASIN == nil || isWorking)
        .controlSize(.small)
      }
    }
  }

  private var candidateList: some View {
    ScrollView {
      LazyVStack(spacing: 5) {
        ForEach(candidates, id: \.asin) { candidate in
          Button {
            selectedASIN = candidate.asin
          } label: {
            HStack(alignment: .top, spacing: 8) {
              Image(
                systemName: selectedASIN == candidate.asin
                  ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(
                  selectedASIN == candidate.asin ? Color.accentColor : .secondary)
              VStack(alignment: .leading, spacing: 2) {
                Text(candidate.title).font(.callout.weight(.medium)).foregroundStyle(.primary)
                if !candidate.authors.isEmpty {
                  Text(candidate.authors.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                  Text(candidate.asin).font(.caption.monospaced()).foregroundStyle(.tertiary)
                  if !candidate.narrators.isEmpty {
                    Text("narrated by \(candidate.narrators.joined(separator: ", "))")
                      .font(.caption2).foregroundStyle(.secondary)
                  }
                }
              }
              Spacer()
            }
            .padding(7)
            .contentShape(Rectangle())
            .background(
              selectedASIN == candidate.asin
                ? Color.accentColor.opacity(0.13) : Color.secondary.opacity(0.07),
              in: RoundedRectangle(cornerRadius: 7))
          }
          .buttonStyle(.plain)
        }
      }
    }
    .frame(maxHeight: 190)
  }

  private func identifiesLine(_ candidate: AsinCatalog.Candidate) -> String {
    var line = "Identifies: \(candidate.title)"
    if !candidate.authors.isEmpty { line += " — \(candidate.authors.joined(separator: ", "))" }
    if !candidate.narrators.isEmpty {
      line += " (narrated by \(candidate.narrators.joined(separator: ", ")))"
    }
    return line
  }

  /// A subtle warning only when the titles clearly differ, so punctuation
  /// and casing variants do not cry wolf.
  private func clearlyDiffers(_ resolved: String, _ local: String) -> Bool {
    func normalize(_ value: String) -> String {
      value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return normalize(resolved) != normalize(local)
  }

  private func resolveCurrent() async {
    guard let asin else { return }
    resolution = .checking
    if let candidate = (try? await AsinCatalog.resolve(asin: asin)) ?? nil {
      resolution = .found(candidate)
    } else {
      resolution = .notFound
    }
  }

  private func runSearch() {
    isWorking = true
    sectionError = nil
    Task {
      defer { isWorking = false }
      do {
        let author = searchAuthor.trimmingCharacters(in: .whitespaces)
        let results = try await AsinCatalog.search(
          title: searchTitle, author: author.isEmpty ? nil : author)
        candidates = results
        selectedASIN = results.first?.asin
        if results.isEmpty { sectionError = "No matches found in the catalog." }
      } catch { sectionError = error.localizedDescription }
    }
  }

  private func save(_ value: String) {
    isWorking = true
    sectionError = nil
    Task {
      defer { isWorking = false }
      do {
        try await model.saveASIN(
          value.trimmingCharacters(in: .whitespaces), editionID: record.id)
        mode = .idle
      } catch { sectionError = error.localizedDescription }
    }
  }
}

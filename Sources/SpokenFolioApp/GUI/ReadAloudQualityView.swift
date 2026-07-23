import AppKit
import Foundation
import LibraryKit
import Observation
import ReadAloudKit
import StorytellerKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor @Observable
final class ReadAloudQualityModel {
  struct Artifact: Identifiable, Equatable {
    let id: String
    let target: LibraryReadAloudAuditTarget
    let title: String
    let author: String?
    let source: String
    let artifactSHA256: String?
    let referenceSHA256: String?
    let history: [LibraryReadAloudAuditRun]

    var activeRun: LibraryReadAloudAuditRun? {
      history.first { [.running, .queued].contains($0.lifecycle) }
    }

    var latestResult: LibraryReadAloudAuditRun? {
      history.first { run in
        guard run.lifecycle == .completed,
          run.analyzerIdentity == "readaloud-quality-v1",
          run.policyVersion == ReadAloudQualityAuditor.policyVersion
        else { return false }
        if let artifactSHA256, run.artifactSHA256 != artifactSHA256 { return false }
        if let referenceSHA256, run.referenceSHA256 != referenceSHA256 { return false }
        return true
      } ?? history.first { [.failed, .cancelled].contains($0.lifecycle) }
    }

    var presentedRun: LibraryReadAloudAuditRun? { activeRun ?? latestResult }

    var outcomeLabel: String {
      guard let run = presentedRun else { return "Not checked" }
      switch run.lifecycle {
      case .queued: return "Queued"
      case .running: return "Checking"
      case .failed: return "Audit failed"
      case .cancelled: return "Cancelled"
      case .completed:
        switch run.verdict {
        case "likelyCorrect": return "Likely correct"
        case "needsReview": return "Review needed"
        case "inconclusive": return "Inconclusive"
        case "likelyBroken": return "Likely broken"
        case "broken": return "Broken"
        default: return "Complete"
        }
      }
    }

    var outcomeRank: Int {
      guard let run = presentedRun else { return 6 }
      if run.lifecycle == .failed { return 0 }
      if [.queued, .running].contains(run.lifecycle) { return 5 }
      switch run.verdict {
      case "broken": return 0
      case "likelyBroken": return 1
      case "needsReview": return 2
      case "inconclusive": return 3
      case "likelyCorrect": return 4
      default: return 6
      }
    }

    var checkedAt: Date? { latestResult?.completedAt ?? latestResult?.updatedAt }
  }

  enum ArtifactScope: String, CaseIterable {
    case all = "All"
    case attention = "Needs Attention"
    case unchecked = "Not Checked"
    case passed = "Likely Correct"
  }

  typealias AutomaticAuditResolution = QualityQueueService.AutomaticAuditResolution

  var audits: [LibraryReadAloudAuditRun] = []
  var connections: [StorytellerConnection] = []
  var connectionID: UUID?
  var remoteBooks: [StorytellerBook] = []
  var selectedRemoteBookIDs = Set<UUID>()
  var progress: Double?
  var status = ""
  var error: String?
  var thorough = false
  // Transient queue messages describe the previous view of the list; changing
  // scope or search would otherwise leave them stranded.
  var artifactScope: ArtifactScope = .all {
    didSet { if oldValue != artifactScope { status = "" } }
  }
  var search = "" {
    didSet { if oldValue != search { status = "" } }
  }
  var selectedAuditID: UUID?
  var selectedArtifactIDs = Set<String>()
  var selectedQueueRunIDs = Set<UUID>()
  private(set) var artifacts: [Artifact] = []
  private(set) var isBusy = false
  private(set) var currentTarget: LibraryReadAloudAuditTarget?
  private(set) var currentRunID: UUID?
  private(set) var auditTitles: [LibraryReadAloudAuditTarget: String] = [:]
  @ObservationIgnored private let databaseURL: URL
  /// The process-wide queue engine. All execution and cancellation authority
  /// lives there; this model mirrors its snapshots and owns presentation.
  @ObservationIgnored let service: QualityQueueService
  @ObservationIgnored private var subscription: Task<Void, Never>?
  @ObservationIgnored private var observedRevision: UInt64?
  /// Test seam forwarded to the engine. Never set in production.
  var executeOverride: (@Sendable (LibraryReadAloudAuditRun) async throws -> Void)? {
    get { service.executeOverride }
    set { service.executeOverride = newValue }
  }

  init(databaseURL: URL = AppPaths.libraryDatabaseURL) {
    self.databaseURL = databaseURL
    self.service = QualityQueueService(databaseURL: databaseURL)
    subscribeToService()
  }

  deinit {
    subscription?.cancel()
  }

  private func makeStore() throws -> LibraryStore {
    try LibraryStore(databaseURL: databaseURL)
  }

  private func subscribeToService() {
    subscription = Task { [weak self, service] in
      for await snapshot in service.snapshots() {
        guard let self else { return }
        self.apply(snapshot)
      }
    }
  }

  private func apply(_ snapshot: QualityQueueSnapshot) {
    currentTarget = snapshot.currentTarget
    currentRunID = snapshot.currentRunID
    progress = snapshot.progress
    isBusy = snapshot.isBusy
    if !snapshot.status.isEmpty || status != snapshot.status { status = snapshot.status }
    error = snapshot.error
    for (target, title) in snapshot.learnedTitles { auditTitles[target] = title }
    if observedRevision != snapshot.revision {
      observedRevision = snapshot.revision
      if let store = try? makeStore() { try? reloadAudits(from: store) }
    }
  }

  var queuedCount: Int {
    audits.count { $0.lifecycle == .queued && $0.id != currentRunID }
  }
  var attentionArtifactCount: Int {
    artifacts.count { artifact in
      artifact.latestResult.map(Self.isProblem) == true
    }
  }
  var uncheckedCount: Int { artifacts.count { $0.presentedRun == nil } }
  var likelyCorrectCount: Int {
    artifacts.count { $0.latestResult?.lifecycle == .completed && $0.latestResult?.verdict == "likelyCorrect" }
  }
  var visibleArtifacts: [Artifact] {
    let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
    return artifacts.filter { artifact in
      let scopeMatches: Bool = switch artifactScope {
      case .all: true
      case .attention:
        artifact.latestResult.map(Self.isProblem) == true
          || artifact.latestResult?.lifecycle == .failed
      case .unchecked: artifact.presentedRun == nil
      case .passed:
        artifact.latestResult?.lifecycle == .completed
          && artifact.latestResult?.verdict == "likelyCorrect"
      }
      guard scopeMatches else { return false }
      guard !query.isEmpty else { return true }
      return artifact.title.localizedCaseInsensitiveContains(query)
        || artifact.author?.localizedCaseInsensitiveContains(query) == true
        || artifact.source.localizedCaseInsensitiveContains(query)
    }
  }
  var queueAudits: [LibraryReadAloudAuditRun] {
    let presented = audits.map(presentedRun)
    return presented.filter { [.running, .queued].contains($0.lifecycle) }.sorted {
      if $0.lifecycle != $1.lifecycle { return $0.lifecycle == .running }
      if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
      return $0.id.uuidString < $1.id.uuidString
    }
  }
  var currentTitle: String? { currentTarget.map(title) }
  var selectedAudit: LibraryReadAloudAuditRun? {
    selectedAuditID.flatMap { id in audits.first(where: { $0.id == id }) }
      ?? selectedArtifact?.presentedRun
  }
  var selectedArtifact: Artifact? {
    guard selectedArtifactIDs.count == 1, let id = selectedArtifactIDs.first else { return nil }
    return artifacts.first(where: { $0.id == id })
  }
  var selectedArtifacts: [Artifact] {
    artifacts.filter { selectedArtifactIDs.contains($0.id) }
  }

  func reload() async {
    do {
      let store = try makeStore()
      connections = try await StorytellerConnectionStore.shared.connections()
      if connectionID == nil { connectionID = connections.first?.id }
      try reloadAudits(from: store)
    } catch { self.error = error.localizedDescription }
  }

  func chooseLocalReadAlouds() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.epub]
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    guard let window = NSApp.keyWindow, window.attachedSheet == nil else {
      error = "Close the current dialog before choosing ReadAloud files."
      return
    }
    panel.beginSheetModal(for: window) { [weak self] response in
      guard response == .OK else { return }
      let urls = panel.urls
      Task { @MainActor in self?.enqueueLocal(urls) }
    }
  }

  func loadRemoteBooks() async {
    guard let connection = connections.first(where: { $0.id == connectionID }) else {
      remoteBooks = []
      return
    }
    do {
      let token = try await Self.storytellerToken(connection.id)
      let client = try StorytellerClient(origin: connection.origin, tokenProvider: { token })
      remoteBooks = try await client.books().filter { $0.asset(.readaloud) != nil }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
      selectedRemoteBookIDs.formIntersection(remoteBooks.lazy.map(\.uuid))
      updateRemoteTitles(connectionID: connection.id, books: remoteBooks)
    } catch {
      remoteBooks = []
      selectedRemoteBookIDs.removeAll()
      self.error = error.localizedDescription
    }
  }

  func queueSelectedRemoteBooks() {
    guard let connectionID else { return }
    let targets = Self.remoteTargets(
      connectionID: connectionID, books: remoteBooks,
      selectedBookIDs: selectedRemoteBookIDs)
    enqueue(targets)
    selectedRemoteBookIDs.removeAll()
  }

  static func remoteTargets(
    connectionID: UUID, books: [StorytellerBook], selectedBookIDs: Set<UUID>
  ) -> [LibraryReadAloudAuditTarget] {
    books.compactMap { book -> LibraryReadAloudAuditTarget? in
      guard selectedBookIDs.contains(book.uuid), let asset = book.asset(.readaloud) else {
        return nil
      }
      return .remote(connectionID: connectionID, bookID: book.uuid, assetID: asset.uuid)
    }
  }

  static func automaticAuditResolution(
    connectionID: UUID, book: StorytellerBook
  ) -> AutomaticAuditResolution {
    QualityQueueService.automaticAuditResolution(connectionID: connectionID, book: book)
  }

  func selectAllRemoteBooks() { selectedRemoteBookIDs = Set(remoteBooks.map(\.uuid)) }
  func clearRemoteBookSelection() { selectedRemoteBookIDs.removeAll() }

  func selectArtifacts(_ ids: Set<String>) {
    selectedArtifactIDs = Self.validArtifactSelection(ids, artifacts: artifacts)
    guard let artifact = selectedArtifact else {
      selectedAuditID = nil
      return
    }
    if !artifact.history.contains(where: { $0.id == selectedAuditID }) {
      selectedAuditID = artifact.presentedRun?.id
    }
  }

  func selectArtifact(_ id: String?) {
    selectArtifacts(id.map { Set([$0]) } ?? [])
  }

  func selectAllVisibleArtifacts() {
    selectArtifacts(Set(visibleArtifacts.map(\.id)))
  }

  func keepSelectionVisible() {
    // Never invent a selection: forcing the first row breaks an in-progress
    // multi-selection and hides the empty-selection guidance.
    let visibleIDs = Set(visibleArtifacts.map(\.id))
    selectArtifacts(selectedArtifactIDs.intersection(visibleIDs))
  }

  static func validArtifactSelection(
    _ requested: Set<String>, artifacts: [Artifact]
  ) -> Set<String> {
    requested.intersection(Set(artifacts.map(\.id)))
  }

  func title(for target: LibraryReadAloudAuditTarget) -> String {
    if let title = auditTitles[target], !title.isEmpty { return title }
    switch target {
    case .localProduct(let id): return "Local ReadAloud \(id.uuidString.prefix(8))"
    case .remote(_, let bookID, _): return "Storyteller book \(bookID.uuidString.prefix(8))"
    case .standalone(let path):
      return URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    }
  }

  private func presentedRun(_ run: LibraryReadAloudAuditRun) -> LibraryReadAloudAuditRun {
    guard run.id == currentRunID else { return run }
    var value = run
    value.lifecycle = .running
    return value
  }

  private static func isProblem(_ run: LibraryReadAloudAuditRun) -> Bool {
    if run.lifecycle == .failed { return true }
    return ["broken", "likelyBroken", "needsReview", "inconclusive"].contains(run.verdict)
  }

  @discardableResult
  func enqueue(_ targets: [LibraryReadAloudAuditTarget]) -> Int {
    let count = service.enqueue(targets, mode: thorough ? .thorough : .standard)
    let snapshot = service.currentSnapshot
    status = snapshot.status
    error = snapshot.error
    if let store = try? makeStore() { try? reloadAudits(from: store) }
    return count
  }

  static func queueRuns(
    targets: [LibraryReadAloudAuditTarget],
    excluding active: Set<LibraryReadAloudAuditTarget>,
    mode: ReadAloudAuditMode, now: Date
  ) -> [LibraryReadAloudAuditRun] {
    QualityQueueService.queueRuns(targets: targets, excluding: active, mode: mode, now: now)
  }

  static func requeuedAfterGracefulInterruption(
    _ run: LibraryReadAloudAuditRun, at date: Date = Date()
  ) -> LibraryReadAloudAuditRun {
    QualityQueueService.requeuedAfterGracefulInterruption(run, at: date)
  }

  static func cancelledWaitingRuns(
    _ runs: [LibraryReadAloudAuditRun], selectedIDs: Set<UUID>? = nil,
    at date: Date = Date()
  ) -> [LibraryReadAloudAuditRun] {
    QualityQueueService.cancelledWaitingRuns(runs, selectedIDs: selectedIDs, at: date)
  }

  func cancelWaitingAudits(_ selectedIDs: Set<UUID>? = nil) {
    let cancelled = service.cancelWaitingAudits(selectedIDs)
    let snapshot = service.currentSnapshot
    status = snapshot.status
    error = snapshot.error
    selectedQueueRunIDs.subtract(cancelled)
    if let store = try? makeStore() { try? reloadAudits(from: store) }
  }

  func cancelCurrentAudit() {
    service.cancelCurrentAudit()
    status = service.currentSnapshot.status
  }

  func cancelAllAudits() {
    service.cancelAllAudits()
    let snapshot = service.currentSnapshot
    status = snapshot.status
    error = snapshot.error
    if let store = try? makeStore() { try? reloadAudits(from: store) }
  }

  func recheckSelectedArtifact() {
    guard let target = selectedArtifact?.target else { return }
    _ = enqueue([target])
  }

  func recheckSelectedArtifacts() {
    _ = enqueue(selectedArtifacts.map(\.target))
  }

  func resumeQueuedAudits() {
    service.resumeQueuedAudits()
  }

  private func enqueueLocal(_ urls: [URL]) {
    do {
      let store = try makeStore()
      let editions = try store.scanEditions().editions
      let targets = urls.map { url -> LibraryReadAloudAuditTarget in
        let standardized = url.standardizedFileURL.path
        let product = editions.lazy.flatMap(\.products).first {
          $0.kind == .readAloudEPUB
            && URL(fileURLWithPath: $0.path).standardizedFileURL.path == standardized
        }
        return product.map { .localProduct($0.id) } ?? .standalone(path: standardized)
      }
      enqueue(targets)
    } catch { self.error = error.localizedDescription }
  }

  private func reloadAudits(from store: LibraryStore) throws {
    let loaded = try store.readAloudAudits()
    let editions = try store.scanEditions().editions
    var titles: [LibraryReadAloudAuditTarget: String] = [:]
    var metadata: [LibraryReadAloudAuditTarget: (String, String?, String, String?, String?)] = [:]
    for edition in editions {
      for product in edition.products where product.kind == .readAloudEPUB {
        let target = LibraryReadAloudAuditTarget.localProduct(product.id)
        titles[target] = edition.metadata.title
        metadata[target] = (
          edition.metadata.title, edition.metadata.author, "Local", product.sha256,
          edition.source.sha256)
      }
    }
    let connectionIDs = Set(connections.map(\.id)).union(loaded.compactMap { run -> UUID? in
      if case .remote(let connectionID, _, _) = run.target { return connectionID }
      return nil
    })
    for connectionID in connectionIDs {
      let books = try store.remoteBooks(connectionID: connectionID)
      let connectionName = connections.first(where: { $0.id == connectionID })?.displayName
        ?? "Storyteller"
      for book in books {
        guard let asset = book.asset(.readaloud), asset.state != .missing else { continue }
        let target = LibraryReadAloudAuditTarget.remote(
          connectionID: connectionID, bookID: book.remoteBookID, assetID: asset.assetID)
        titles[target] = book.title
        metadata[target] = (
          book.title, book.authors.joined(separator: ", "), connectionName, asset.sha256, nil)
      }
      let bookTitles = Dictionary(uniqueKeysWithValues: books.map { ($0.remoteBookID, $0.title) })
      for run in loaded {
        guard case .remote(let id, let bookID, _) = run.target, id == connectionID,
          let bookTitle = bookTitles[bookID]
        else { continue }
        titles[run.target] = bookTitle
      }
    }
    for run in loaded {
      if case .standalone(let path) = run.target {
        let title = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        titles[run.target] = title
        metadata[run.target] = (title, nil, "Local file", nil, nil)
      } else if metadata[run.target] == nil {
        metadata[run.target] = (
          titles[run.target] ?? title(for: run.target), nil, sourceName(for: run.target), nil, nil)
      }
    }
    let histories = Dictionary(grouping: loaded, by: \.target).mapValues { values in
      values.sorted {
        if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
        return $0.id.uuidString < $1.id.uuidString
      }
    }
    audits = loaded
    auditTitles = titles
    service.updateTitles(titles)
    artifacts = metadata.map { target, value in
      Artifact(
        id: Self.artifactID(target), target: target, title: value.0,
        author: value.1?.isEmpty == true ? nil : value.1, source: value.2,
        artifactSHA256: value.3, referenceSHA256: value.4,
        history: histories[target] ?? [])
    }.sorted {
      let result = $0.title.localizedStandardCompare($1.title)
      if result != .orderedSame { return result == .orderedAscending }
      return $0.source.localizedStandardCompare($1.source) == .orderedAscending
    }
    selectArtifacts(Self.validArtifactSelection(selectedArtifactIDs, artifacts: artifacts))
  }

  private static func artifactID(_ target: LibraryReadAloudAuditTarget) -> String {
    switch target {
    case .localProduct(let id): return "local:\(id.uuidString.lowercased())"
    case .remote(let connectionID, let bookID, let assetID):
      return "remote:\(connectionID.uuidString.lowercased()):\(bookID.uuidString.lowercased()):\(assetID.uuidString.lowercased())"
    case .standalone(let path): return "file:\(path)"
    }
  }

  private func sourceName(for target: LibraryReadAloudAuditTarget) -> String {
    switch target {
    case .localProduct: return "Local"
    case .standalone: return "Local file"
    case .remote(let connectionID, _, _):
      return connections.first(where: { $0.id == connectionID })?.displayName ?? "Storyteller"
    }
  }

  private func updateRemoteTitles(connectionID: UUID, books: [StorytellerBook]) {
    let titles = Dictionary(uniqueKeysWithValues: books.map { ($0.uuid, $0.title) })
    for run in audits {
      guard case .remote(let id, let bookID, _) = run.target, id == connectionID,
        let bookTitle = titles[bookID]
      else { continue }
      auditTitles[run.target] = bookTitle
    }
  }

  private static func storytellerToken(_ connectionID: UUID) async throws -> String {
    try await StorytellerConnectionStore.shared.token(connectionID)
  }

  func cancelAndWait() async {
    await service.cancelAndWait()
  }
}

struct ReadAloudQualityView: View {
  private struct MetricItem: Identifiable {
    var label: String
    var value: String
    var id: String { label }
  }

  @Bindable var model: ReadAloudQualityModel
  @State private var showsStorytellerSelection = false
  @State private var showsQueue = false
  @State private var confirmCancelCurrent = false
  @State private var confirmCancelAll = false
  @State private var sortOrder = [
    KeyPathComparator(\ReadAloudQualityModel.Artifact.title, order: .forward)
  ]

  var body: some View {
    VStack(spacing: 0) {
      qualityToolbar
      if let error = model.error {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .font(.callout).foregroundStyle(.red).lineLimit(2)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 14).padding(.vertical, 8)
          .background(Color.red.opacity(0.08))
      }
      queueStatusBar
      Divider()
      GeometryReader { geometry in
        // Splits must be forced to the available size; see ActivityView.
        if geometry.size.width >= 820 {
          HSplitView {
            artifactTable
              .frame(minWidth: 340, idealWidth: 420, maxWidth: 620)
              .frame(maxHeight: .infinity)
            outcomePane
              .frame(minWidth: 420, idealWidth: 560)
              .frame(maxWidth: .infinity, maxHeight: .infinity)
              .layoutPriority(1)
          }
          .frame(width: geometry.size.width, height: geometry.size.height)
        } else {
          VSplitView {
            artifactTable
              .frame(minHeight: 160, idealHeight: 240)
              .frame(maxWidth: .infinity)
            outcomePane
              .frame(minHeight: 180, idealHeight: 320)
              .frame(maxWidth: .infinity, maxHeight: .infinity)
          }
          .frame(width: geometry.size.width, height: geometry.size.height)
        }
      }
    }
    .overlay(alignment: .bottom) {
      if showsQueue {
        queueDrawer
          .frame(maxHeight: 180)
          .shadow(color: .black.opacity(0.18), radius: 10, y: -2)
      }
    }
    .task { await model.reload() }
    .onChange(of: model.search) {
      model.keepSelectionVisible()
    }
    .sheet(isPresented: $showsStorytellerSelection) {
      StorytellerAuditSelectionView(model: model)
    }
    .confirmationDialog(
      "Cancel the current quality check?", isPresented: $confirmCancelCurrent
    ) {
      Button("Cancel Current Check", role: .destructive) { model.cancelCurrentAudit() }
      Button("Keep Checking", role: .cancel) {}
    } message: {
      Text("Progress on this check is discarded. It can be queued again later.")
    }
    .confirmationDialog("Cancel all quality checks?", isPresented: $confirmCancelAll) {
      Button("Cancel All Checks", role: .destructive) { model.cancelAllAudits() }
      Button("Keep Queue", role: .cancel) {}
    } message: {
      Text("The running check is interrupted and every waiting check is removed.")
    }
  }

  private var qualityToolbar: some View {
    VStack(alignment: .leading, spacing: 10) {
      ViewThatFits(in: .horizontal) {
        HStack {
          qualityTitle
          Spacer()
          qualitySearch.frame(minWidth: 180, idealWidth: 260, maxWidth: 340)
          refreshButton
        }
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            qualityTitle
            Spacer()
            refreshButton
          }
          qualitySearch
        }
      }
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 6) {
          scopeButton(.all, count: model.artifacts.count)
          scopeButton(.attention, count: model.attentionArtifactCount)
          scopeButton(.unchecked, count: model.uncheckedCount)
          scopeButton(.passed, count: model.likelyCorrectCount)
        }
      }
    }
    .padding(14)
  }

  private var qualityTitle: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("ReadAloud Quality").font(.title2.bold())
      Text("\(model.visibleArtifacts.count) of \(model.artifacts.count) ReadAlouds")
        .font(.caption).foregroundStyle(.secondary)
    }
  }

  private var qualitySearch: some View {
    TextField("Search title, author, or source", text: $model.search)
      .textFieldStyle(.roundedBorder)
  }

  private var refreshButton: some View {
    Button { Task { await model.reload() } } label: {
      Label("Refresh", systemImage: "arrow.clockwise")
    }
  }

  private func scopeButton(
    _ scope: ReadAloudQualityModel.ArtifactScope, count: Int
  ) -> some View {
    Button {
      model.artifactScope = scope
      model.keepSelectionVisible()
    } label: {
      Text("\(scope.rawValue)  \(count)")
    }
    .buttonStyle(.bordered)
    .tint(model.artifactScope == scope ? .accentColor : .secondary)
    .accessibilityLabel("\(scope.rawValue), \(count) ReadAlouds")
  }

  private var queueStatusBar: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 12) {
        queueSummary.frame(maxWidth: .infinity, alignment: .leading)
        queueCancellationActions
      }
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 10) {
          depthControl
          Spacer()
          addLocalButton
          addStorytellerButton
          queueToggleButton
        }
        VStack(alignment: .leading, spacing: 7) {
          depthControl
          HStack(spacing: 10) {
            addLocalButton
            addStorytellerButton
            Spacer()
            queueToggleButton
          }
        }
      }
    }
    .padding(.horizontal, 14).padding(.vertical, 9)
    .background(.bar)
  }

  @ViewBuilder private var queueSummary: some View {
    if let title = model.currentTitle {
      VStack(alignment: .leading, spacing: 3) {
        Text("Checking \(title)")
          .font(.callout.weight(.semibold))
          .lineLimit(1)
          .truncationMode(.middle)
        ProgressView(value: model.progress ?? 0).frame(maxWidth: 240)
      }
    } else {
      Label(
        model.queuedCount == 0 ? "Quality queue is idle" : "Preparing next quality check",
        systemImage: model.queuedCount == 0 ? "checkmark.circle" : "clock")
        .foregroundStyle(.secondary)
    }
  }

  private var queueCancellationActions: some View {
    HStack(spacing: 8) {
      Button("Cancel Current", role: .destructive) { confirmCancelCurrent = true }
        .disabled(model.currentRunID == nil)
      Button("Cancel All", role: .destructive) { confirmCancelAll = true }
        .disabled(model.queueAudits.isEmpty)
    }
    .fixedSize()
  }

  private var depthControl: some View {
    Picker("Depth", selection: $model.thorough) {
      Text("Standard").tag(false)
      Text("Thorough").tag(true)
    }
    .pickerStyle(.segmented).labelsHidden().frame(width: 170)
    .accessibilityLabel("Quality check depth")
  }

  private var addLocalButton: some View {
    Button { model.chooseLocalReadAlouds() } label: {
      Label("Add Local", systemImage: "plus")
    }
  }

  private var addStorytellerButton: some View {
    Button { showsStorytellerSelection = true } label: {
      Label("Add Storyteller", systemImage: "plus")
    }
    .disabled(model.connections.isEmpty)
  }

  private var queueToggleButton: some View {
    Button { showsQueue.toggle() } label: {
      Label(
        showsQueue ? "Hide Queue" : "Show Queue (\(model.queueAudits.count))",
        systemImage: showsQueue ? "chevron.down" : "list.bullet")
    }
  }

  private var queueDrawer: some View {
    VStack(spacing: 0) {
      Divider()
      ViewThatFits(in: .horizontal) {
        HStack {
          queueDrawerTitle
          Spacer()
          queueDrawerActions
        }
        VStack(alignment: .leading, spacing: 6) {
          queueDrawerTitle
          queueDrawerActions
        }
      }
      .padding(.horizontal, 14).padding(.vertical, 8)
      List(model.queueAudits, selection: $model.selectedQueueRunIDs) { run in
        HStack {
          Image(systemName: run.lifecycle == .running ? "waveform" : "clock")
            .foregroundStyle(run.lifecycle == .running ? .blue : .secondary)
          Text(model.title(for: run.target)).lineLimit(1)
          Spacer()
          Text(run.lifecycle == .running ? "Checking" : "Waiting")
            .font(.caption).foregroundStyle(.secondary)
        }.tag(run.id)
      }
      .frame(maxHeight: 118)
      .overlay {
        if model.queueAudits.isEmpty {
          ContentUnavailableView("Queue is empty", systemImage: "tray")
        }
      }
    }
    .background(.regularMaterial)
  }

  private var queueDrawerTitle: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("Quality Queue").font(.headline)
      Text("One audit runs at a time; waiting checks remain in FIFO order.")
        .font(.caption).foregroundStyle(.secondary)
    }
  }

  private var queueDrawerActions: some View {
    HStack {
      Button("Remove Selected", role: .destructive) {
        model.cancelWaitingAudits(model.selectedQueueRunIDs)
      }
      .disabled(model.selectedQueueRunIDs.isEmpty)
      Button("Clear Waiting", role: .destructive) { model.cancelWaitingAudits() }
        .disabled(model.queuedCount == 0)
      Button("Cancel All", role: .destructive) { confirmCancelAll = true }
        .disabled(model.queueAudits.isEmpty)
    }
  }

  private var artifactTable: some View {
    VStack(spacing: 0) {
      artifactSelectionBar
      Divider()
      Table(
        model.visibleArtifacts.sorted(using: sortOrder),
        selection: Binding(
          get: { model.selectedArtifactIDs },
          set: { model.selectArtifacts($0) }),
        sortOrder: $sortOrder
      ) {
        TableColumn("ReadAloud", value: \.title) { artifact in
          VStack(alignment: .leading, spacing: 2) {
            Text(artifact.title).lineLimit(1)
            if let author = artifact.author {
              Text(author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
          }
        }
        .width(min: 180, ideal: 280)
        TableColumn("Outcome", value: \.outcomeLabel) { artifact in
          Label(artifact.outcomeLabel, systemImage: outcomeIcon(artifact.presentedRun))
            .foregroundStyle(outcomeColor(artifact.presentedRun))
        }
        .width(min: 125, ideal: 150)
        TableColumn("Source", value: \.source) { artifact in
          Text(artifact.source).lineLimit(1)
        }
        .width(min: 90, ideal: 130)
        TableColumn("Checked") { artifact in
          if let date = artifact.checkedAt {
            Text(date, format: .dateTime.month().day().year())
          } else {
            Text("—").foregroundStyle(.tertiary)
          }
        }
        .width(min: 85, ideal: 105)
      }
      .overlay {
        if model.visibleArtifacts.isEmpty {
          if model.artifacts.isEmpty {
            ContentUnavailableView(
              "No ReadAlouds", systemImage: "checkmark.shield",
              description: Text("Add a local file or refresh a Storyteller connection."))
          } else {
            ContentUnavailableView {
              Label(
                model.search.isEmpty ? "No ReadAlouds in this scope" : "No matching ReadAlouds",
                systemImage: "line.3.horizontal.decrease.circle")
            } description: {
              Text(
                model.search.isEmpty
                  ? "The \(model.artifactScope.rawValue) scope is empty."
                  : "Nothing in the \(model.artifactScope.rawValue) scope matches “\(model.search)”.")
            } actions: {
              if model.artifactScope != .all {
                Button("Show All") { model.artifactScope = .all }
              }
              if !model.search.isEmpty {
                Button("Clear Search") { model.search = "" }
              }
            }
          }
        }
      }
    }
  }

  private var artifactSelectionBar: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 10) {
        selectionSummary
        Spacer()
        selectionActions
      }
      VStack(alignment: .leading, spacing: 7) {
        selectionSummary
        selectionActions
      }
    }
    .padding(.horizontal, 10).padding(.vertical, 7)
    .background(.bar)
  }

  private var selectionSummary: some View {
    Group {
      if model.selectedArtifactIDs.isEmpty {
        Text("Select rows · Command-click or Shift-click for multiple")
      } else {
        Text("\(model.selectedArtifactIDs.count) selected")
      }
    }
    .font(.callout.weight(.medium))
    .foregroundStyle(model.selectedArtifactIDs.isEmpty ? .secondary : .primary)
    .accessibilityLabel("\(model.selectedArtifactIDs.count) ReadAlouds selected")
  }

  private var selectionActions: some View {
    HStack(spacing: 8) {
      Button("Select All Results") { model.selectAllVisibleArtifacts() }
        .disabled(model.visibleArtifacts.isEmpty)
      Button("Clear") { model.selectArtifacts([]) }
        .disabled(model.selectedArtifactIDs.isEmpty)
      Button("Check Selected") { model.recheckSelectedArtifacts() }
        .buttonStyle(.borderedProminent)
        .disabled(model.selectedArtifactIDs.isEmpty)
    }
  }

  private var outcomePane: some View {
    Group {
      if model.selectedArtifactIDs.count > 1 {
        VStack(spacing: 14) {
          Image(systemName: "checklist")
            .font(.system(size: 32))
            .foregroundStyle(.secondary)
          Text("\(model.selectedArtifactIDs.count) ReadAlouds selected")
            .font(.title2.bold())
          Text("Queue one quality check for every selected ReadAloud. Existing queued or running checks are skipped automatically.")
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 440)
          Button("Check Selected ReadAlouds") { model.recheckSelectedArtifacts() }
            .buttonStyle(.borderedProminent)
          Text("Use Command-click, Shift-click, or Select All Results to change the selection.")
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
      } else if let artifact = model.selectedArtifact {
        ScrollView {
          VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
              VStack(alignment: .leading, spacing: 4) {
                Text(artifact.title).font(.title2.bold())
                if let author = artifact.author { Text(author).foregroundStyle(.secondary) }
                Text(artifact.source).font(.caption).foregroundStyle(.secondary)
              }
              Spacer()
              Button(artifact.presentedRun == nil ? "Queue Check" : "Check Again") {
                model.recheckSelectedArtifact()
              }
            }
            if artifact.history.count > 1 {
              VStack(alignment: .leading, spacing: 6) {
                Text("History").font(.headline)
                ScrollView(.horizontal, showsIndicators: false) {
                  HStack {
                    ForEach(artifact.history) { run in
                      Button {
                        model.selectedAuditID = run.id
                      } label: {
                        VStack(alignment: .leading, spacing: 2) {
                          Text(resultLabel(run)).font(.callout.weight(.medium))
                          Text(run.updatedAt, format: .dateTime.month().day().hour().minute())
                            .font(.caption).foregroundStyle(.secondary)
                        }
                      }
                      .buttonStyle(.bordered)
                      .tint(model.selectedAuditID == run.id ? .accentColor : .secondary)
                    }
                  }
                }
              }
            }
            if let run = model.selectedAudit {
              resultDetail(run)
            } else {
              ContentUnavailableView(
                "Not checked", systemImage: "questionmark.diamond",
                description: Text(
                  "Queue a quality check to verify structure, content identity, timing, coverage, and compatibility."))
            }
          }
          .padding(18)
        }
      } else {
        ContentUnavailableView(
          "Select a ReadAloud", systemImage: "doc.text.magnifyingglass",
          description: Text("Choose an artifact to inspect its latest outcome and evidence."))
      }
    }
    .background(Color.secondary.opacity(0.035))
  }

  @ViewBuilder private func resultDetail(_ run: LibraryReadAloudAuditRun) -> some View {
    Text(resultLabel(run).uppercased())
      .font(.title3.bold())
      .foregroundStyle(color(run.verdict, lifecycle: run.lifecycle))
    if let explanation = explanation(run) { Text(explanation) }
    HStack(spacing: 20) {
      metadata("Mode", run.mode == "thorough" ? "Thorough" : "Standard")
      metadata("Evidence", run.evidenceAdequacy.map(friendly) ?? "Pending")
      metadata(
        "Updated",
        (run.completedAt ?? run.updatedAt).formatted(
          .dateTime.month().day().year().hour().minute()))
    }
    if [.running, .queued].contains(run.lifecycle) {
      ProgressView(value: run.id == model.currentRunID ? model.progress : run.progress)
      Text(run.id == model.currentRunID ? model.status : (run.progressMessage ?? "Queued"))
        .foregroundStyle(.secondary)
    }
    if let error = run.error {
      detailCard(title: "Audit execution failed", text: error, color: .red)
    }
    let metrics = metricItems(run)
    if !metrics.isEmpty {
      VStack(alignment: .leading, spacing: 10) {
        Text("Evidence summary").font(.headline)
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 135), spacing: 10)], spacing: 10) {
          ForEach(metrics) { item in
            VStack(alignment: .leading, spacing: 3) {
              Text(item.value).font(.title3.bold()).monospacedDigit()
              Text(item.label).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
          }
        }
      }
    }
    VStack(alignment: .leading, spacing: 10) {
      Text("Findings and suspected causes").font(.headline)
      if run.findings.isEmpty {
        Text(
          run.lifecycle == .completed
            ? "No reportable defect or fundamental mismatch was detected."
            : "No semantic findings are available for this run.")
          .foregroundStyle(.secondary)
      } else {
        ForEach(run.findings) { finding in findingCard(finding) }
      }
    }
  }

  private func outcomeIcon(_ run: LibraryReadAloudAuditRun?) -> String {
    guard let run else { return "questionmark.circle" }
    switch run.lifecycle {
    case .queued: return "clock"
    case .running: return "waveform"
    case .failed: return "exclamationmark.triangle.fill"
    case .cancelled: return "minus.circle"
    case .completed:
      switch run.verdict {
      case "likelyCorrect": return "checkmark.circle.fill"
      case "broken", "likelyBroken": return "xmark.octagon.fill"
      case "needsReview": return "exclamationmark.triangle.fill"
      default: return "questionmark.diamond.fill"
      }
    }
  }

  private func outcomeColor(_ run: LibraryReadAloudAuditRun?) -> Color {
    guard let run else { return .secondary }
    return color(run.verdict, lifecycle: run.lifecycle)
  }

  private func resultLabel(_ run: LibraryReadAloudAuditRun) -> String {
    let lifecycle: LibraryReadAloudAuditLifecycle =
      model.currentRunID == run.id ? .running : run.lifecycle
    guard lifecycle == .completed else {
      switch lifecycle {
      case .queued: return "Queued"
      case .running: return "Checking"
      case .failed: return "Failed"
      case .cancelled: return "Cancelled"
      case .completed: return "Complete"
      }
    }
    switch run.verdict {
    case "likelyCorrect": return "Likely correct"
    case "needsReview": return "Review needed"
    case "inconclusive": return "Inconclusive"
    case "likelyBroken": return "Likely broken"
    case "broken": return "Broken"
    default: return "Complete"
    }
  }

  private func metadata(_ label: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(label.uppercased()).font(.caption2.bold()).foregroundStyle(.secondary)
      Text(value).font(.callout)
    }
  }

  private func detailCard(title: String, text: String, color: Color) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title).font(.headline).foregroundStyle(color)
      Text(text)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(12)
    .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
  }

  private func findingCard(_ finding: LibraryReadAloudAuditFinding) -> some View {
    let evidence = finding.evidenceData.flatMap {
      try? JSONDecoder().decode(ReadAloudAuditFinding.self, from: $0)
    }
    let findingColor = color(finding.verdict, lifecycle: .completed)
    return VStack(alignment: .leading, spacing: 7) {
      HStack {
        Text(friendly(finding.dimension).uppercased()).font(.caption.bold())
          .foregroundStyle(findingColor)
        Text(friendly(finding.confidence)).font(.caption).foregroundStyle(.secondary)
        Spacer()
        Text(friendly(finding.code)).font(.caption).foregroundStyle(.secondary)
      }
      Text(finding.summary)
      if let evidence {
        if let path = evidence.documentPath {
          Text("Document: \(path)").font(.caption).foregroundStyle(.secondary)
        }
        if let begin = evidence.clipBegin, let end = evidence.clipEnd {
          Text(String(format: "Audio interval: %.2f–%.2f seconds", begin, end))
            .font(.caption).foregroundStyle(.secondary)
        }
        if let reference = evidence.referenceExcerpt {
          Text("Text: “\(reference)”").font(.caption)
        }
        if let transcript = evidence.transcriptExcerpt {
          Text("Audio transcript: “\(transcript)”").font(.caption)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(12)
    .background(findingColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
  }

  private func metricItems(_ run: LibraryReadAloudAuditRun) -> [MetricItem] {
    guard let data = run.metricsData,
      let value = try? JSONDecoder().decode(ReadAloudAuditMetrics.self, from: data)
    else { return [] }
    func percent(_ number: Double) -> String { number.formatted(.percent.precision(.fractionLength(1))) }
    var result = [
      MetricItem(label: "Audio files", value: "\(value.audioCount)"),
      MetricItem(label: "Timed clips", value: "\(value.clipCount)"),
    ]
    if let coverage = value.primaryCoverage {
      result.append(.init(label: "Primary text covered", value: percent(coverage)))
    }
    if let similarity = value.freshASRWeightedSimilarity {
      result.append(.init(label: "Fresh ASR similarity", value: percent(similarity)))
    }
    if value.freshASRSampleCount > 0 {
      result.append(.init(label: "ASR samples", value: "\(value.freshASRSampleCount)"))
      result.append(
        .init(label: "Severe ASR mismatches", value: "\(value.freshASRSevereSampleCount)"))
    }
    if let coverage = value.textToTranscriptCoverage {
      result.append(.init(label: "Text found in audio", value: percent(coverage)))
    }
    if let coverage = value.transcriptToTextCoverage {
      result.append(.init(label: "Audio found in text", value: percent(coverage)))
    }
    if let similarity = value.clipWeightedSimilarity {
      result.append(.init(label: "Timestamp similarity", value: percent(similarity)))
    }
    if value.largestPrimaryOmissionTokens > 0 {
      result.append(
        .init(
          label: "Largest prose omission", value: "\(value.largestPrimaryOmissionTokens) words"))
    }
    return result
  }

  private func explanation(_ run: LibraryReadAloudAuditRun) -> String? {
    if let finding = run.findings.first { return finding.summary }
    switch run.verdict {
    case "likelyCorrect": return "No fundamental content or alignment failure was detected."
    case "needsReview": return "The audit found evidence that should be reviewed."
    case "inconclusive": return "The available evidence was not sufficient for a reliable conclusion."
    case "likelyBroken": return "The audit found strong evidence of a content or alignment problem."
    case "broken": return "The ReadAloud failed a fundamental content or alignment check."
    default: return run.progressMessage
    }
  }

  private func friendly(_ value: String) -> String {
    value.replacingOccurrences(
      of: "([a-z0-9])([A-Z])", with: "$1 $2", options: .regularExpression
    ).replacingOccurrences(of: "_", with: " ").lowercased()
  }

  private func color(_ verdict: String?, lifecycle: LibraryReadAloudAuditLifecycle) -> Color {
    guard lifecycle == .completed else {
      return lifecycle == .failed ? .red : lifecycle == .cancelled ? .gray : .blue
    }
    switch verdict {
    case "likelyCorrect": return Color.green
    case "needsReview": return Color.yellow
    case "inconclusive": return Color.gray
    case "likelyBroken": return Color.orange
    case "broken": return Color.red
    default: return Color.gray
    }
  }
}

private struct StorytellerAuditSelectionView: View {
  @Bindable var model: ReadAloudQualityModel
  @Environment(\.dismiss) private var dismiss
  @State private var search = ""

  private var visibleBooks: [StorytellerBook] {
    let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return model.remoteBooks }
    return model.remoteBooks.filter { book in
      book.title.localizedCaseInsensitiveContains(query)
        || book.authors.contains { $0.name.localizedCaseInsensitiveContains(query) }
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Add Storyteller ReadAlouds").font(.title2.bold())
      if model.connections.count > 1 {
        ScrollView(.horizontal) {
          HStack {
            ForEach(model.connections) { connection in
              let selected = model.connectionID == connection.id
              Button {
                model.connectionID = connection.id
                Task { await model.loadRemoteBooks() }
              } label: {
                Text(connection.displayName)
                  .padding(.horizontal, 10).padding(.vertical, 6)
                  .foregroundStyle(selected ? Color.white : Color.primary)
                  .background(
                    selected ? Color.accentColor : Color.secondary.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 7))
              }
              .buttonStyle(.plain)
            }
          }
        }
      }
      TextField("Search title or author", text: $search)
        .textFieldStyle(.roundedBorder)
      HStack {
        Text("\(model.selectedRemoteBookIDs.count) selected")
          .foregroundStyle(.secondary)
        Spacer()
        Button("Select Visible") {
          model.selectedRemoteBookIDs.formUnion(visibleBooks.map(\.uuid))
        }.disabled(visibleBooks.isEmpty)
        Button("Clear") { model.clearRemoteBookSelection() }
          .disabled(model.selectedRemoteBookIDs.isEmpty)
      }
      List(visibleBooks, id: \.uuid, selection: $model.selectedRemoteBookIDs) { book in
        VStack(alignment: .leading, spacing: 2) {
          Text(book.title).font(.headline)
          if !book.authors.isEmpty {
            Text(book.authors.map(\.name).joined(separator: ", "))
              .font(.caption).foregroundStyle(.secondary)
          }
        }
        .padding(.vertical, 3)
        .tag(book.uuid)
      }
      HStack {
        Button("Cancel") { dismiss() }
        Spacer()
        Button("Add \(model.selectedRemoteBookIDs.count) to Queue") {
          model.queueSelectedRemoteBooks()
          dismiss()
        }
        .buttonStyle(.borderedProminent)
        .disabled(model.selectedRemoteBookIDs.isEmpty)
      }
    }
    .padding(20)
    .frame(minWidth: 440, idealWidth: 680, minHeight: 340, idealHeight: 520)
    .task {
      if model.remoteBooks.isEmpty { await model.loadRemoteBooks() }
    }
  }
}

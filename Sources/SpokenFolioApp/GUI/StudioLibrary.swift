import AppKit
import BookJobKit
import Foundation
import LibraryKit
import Observation
import ReadAloudKit
import StorytellerKit
import SwiftUI

struct StudioLibraryRow: Identifiable, Equatable {
  enum Presence: String { case local = "Local", storyteller = "Storyteller", both = "Both" }
  let id: String
  let title: String
  let author: String?
  let record: BookCatalogRecord?
  let remote: LibraryRemoteBookSnapshot?
  let level: LibraryLevel
  let presence: Presence
  let narration: NarrationProvenance
  let stale: Bool
  let localEPUBReady: Bool
  let localAudiobookReady: Bool
  let localReadAloudReady: Bool
  let localReadAloudProductID: UUID?
  let ttsProvenance: String?
  let localQualityVerdict: String?
  let remoteQualityVerdict: String?
  let updatedAt: Date
  /// Stored pre-folded so live search never folds every row per keystroke.
  let searchIndex: String
  /// An unlinked Storyteller book that looks like this edition (same
  /// identifiers or normalized title/author). Nothing merges in the catalog
  /// until the user confirms; this only groups the presentation so the same
  /// book never renders as two rows.
  let suggestedRemote: LibraryRemoteBookSnapshot?

  init(
    id: String, title: String, author: String?, record: BookCatalogRecord?,
    remote: LibraryRemoteBookSnapshot?, level: LibraryLevel, presence: Presence,
    narration: NarrationProvenance, stale: Bool, localEPUBReady: Bool,
    localAudiobookReady: Bool, localReadAloudReady: Bool,
    localReadAloudProductID: UUID?, ttsProvenance: String?,
    localQualityVerdict: String?, remoteQualityVerdict: String?,
    updatedAt: Date, searchIndex: String,
    suggestedRemote: LibraryRemoteBookSnapshot? = nil
  ) {
    self.id = id
    self.title = title
    self.author = author
    self.record = record
    self.remote = remote
    self.level = level
    self.presence = presence
    self.narration = narration
    self.stale = stale
    self.localEPUBReady = localEPUBReady
    self.localAudiobookReady = localAudiobookReady
    self.localReadAloudReady = localReadAloudReady
    self.localReadAloudProductID = localReadAloudProductID
    self.ttsProvenance = ttsProvenance
    self.localQualityVerdict = localQualityVerdict
    self.remoteQualityVerdict = remoteQualityVerdict
    self.updatedAt = updatedAt
    self.searchIndex = searchIndex.folding(
      options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    self.suggestedRemote = suggestedRemote
  }

  /// The five-slot view of a book: EPUB, TTS audiobook, TTS ReadAloud, human
  /// audiobook, human ReadAloud. Local products are always SpokenFolio TTS;
  /// human slots come from the linked (or suggested) Storyteller book plus
  /// its narration assertion.
  enum SlotState {
    /// Verified local product.
    case verified
    /// Present on Storyteller (linked).
    case present
    /// Present but needing a decision: unconfirmed match, or narration unknown.
    case pending
    case missing
  }

  struct Slots {
    var epub: SlotState
    var ttsAudiobook: SlotState
    var ttsReadAloud: SlotState
    var humanAudiobook: SlotState
    var humanReadAloud: SlotState
  }

  var slots: Slots {
    let effectiveRemote = remote ?? suggestedRemote
    let remoteIsSuggestion = remote == nil && suggestedRemote != nil
    func remoteState(_ format: LibraryRemoteFormat) -> Bool {
      effectiveRemote?.asset(format)?.state == .ready
    }
    func slot(local: Bool, remoteReady: Bool, narrationMatches: Bool) -> SlotState {
      if local { return .verified }
      guard remoteReady, narrationMatches else { return .missing }
      return remoteIsSuggestion ? .pending : .present
    }
    let narrationKnownTTS = narration == .spokenFolioTTS || narration == .otherTTS
    let narrationKnownHuman = narration == .human
    let narrationUnknown = narration == .unknown
    var humanAudiobook = slot(
      local: false, remoteReady: remoteState(.audiobook), narrationMatches: narrationKnownHuman)
    var humanReadAloud = slot(
      local: false, remoteReady: remoteState(.readaloud), narrationMatches: narrationKnownHuman)
    // Unknown narration: the remote pair exists but nobody has said whether
    // it is human; it renders as a pending question in the human slots.
    if narrationUnknown, remoteState(.audiobook) { humanAudiobook = .pending }
    if narrationUnknown, remoteState(.readaloud) { humanReadAloud = .pending }
    return Slots(
      epub: localEPUBReady
        ? .verified
        : slot(local: false, remoteReady: remoteState(.ebook), narrationMatches: true),
      ttsAudiobook: slot(
        local: localAudiobookReady, remoteReady: remoteState(.audiobook),
        narrationMatches: narrationKnownTTS),
      ttsReadAloud: slot(
        local: localReadAloudReady, remoteReady: remoteState(.readaloud),
        narrationMatches: narrationKnownTTS),
      humanAudiobook: humanAudiobook,
      humanReadAloud: humanReadAloud)
  }

  var sortSlots: Int {
    let all = [slots.epub, slots.ttsAudiobook, slots.ttsReadAloud, slots.humanAudiobook, slots.humanReadAloud]
    return all.reduce(0) { total, state in
      switch state {
      case .verified: total + 3
      case .present: total + 2
      case .pending: total + 1
      case .missing: total
      }
    }
  }

  var detail: String {
    var values = [presence.rawValue, "Level \(level.rawValue): \(level.label)"]
    if narration != .unknown { values.append(narration == .human ? "Human narration" : "TTS") }
    if stale { values.append("Snapshot stale") }
    return values.joined(separator: " • ")
  }

  var sortAuthor: String { author ?? "" }
  var sortLevel: Int { level.rawValue }
  var sortNarration: String { narration.displayName }
  var sortQuality: String { qualityLabel }

  var qualityLabel: String {
    let verdict = [localQualityVerdict, remoteQualityVerdict]
      .compactMap { $0 }
      .max { Self.verdictSeverity($0) < Self.verdictSeverity($1) }
    return verdict.map(Self.readableVerdict) ?? "Not checked"
  }

  var localPackageSummary: String {
    Self.packageSummary(
      epub: localEPUBReady ? "✓" : "–", audiobook: localAudiobookReady ? "✓" : "–",
      readAloud: localReadAloudReady ? "✓" : "–")
  }

  var remotePackageSummary: String {
    guard let remote else { return "—" }
    return Self.packageSummary(
      epub: Self.remoteStateMark(remote.asset(.ebook)?.state),
      audiobook: Self.remoteStateMark(remote.asset(.audiobook)?.state),
      readAloud: Self.remoteStateMark(remote.asset(.readaloud)?.state))
  }

  private static func packageSummary(epub: String, audiobook: String, readAloud: String) -> String {
    "E\(epub) A\(audiobook) R\(readAloud)"
  }

  private static func remoteStateMark(_ state: LibraryRemoteAssetState?) -> String {
    switch state {
    case .ready: "✓"
    case .processing: "◷"
    case .broken: "!"
    case .unknown: "?"
    case .missing, nil: "–"
    }
  }

  private static func readableVerdict(_ value: String) -> String {
    switch value {
    case ReadAloudAuditVerdict.likelyCorrect.rawValue: "Likely correct"
    case ReadAloudAuditVerdict.needsReview.rawValue: "Needs review"
    case ReadAloudAuditVerdict.likelyBroken.rawValue: "Likely broken"
    case ReadAloudAuditVerdict.broken.rawValue: "Broken"
    case ReadAloudAuditVerdict.inconclusive.rawValue: "Inconclusive"
    default: value.replacingOccurrences(of: "_", with: " ").capitalized
    }
  }

  private static func verdictSeverity(_ value: String) -> Int {
    switch value {
    case ReadAloudAuditVerdict.broken.rawValue: 5
    case ReadAloudAuditVerdict.likelyBroken.rawValue: 4
    case ReadAloudAuditVerdict.needsReview.rawValue: 3
    case ReadAloudAuditVerdict.inconclusive.rawValue: 2
    case ReadAloudAuditVerdict.likelyCorrect.rawValue: 1
    default: 0
    }
  }
}

extension NarrationProvenance {
  var displayName: String {
    switch self {
    case .unknown: "Unknown"
    case .spokenFolioTTS: "SpokenFolio TTS"
    case .otherTTS: "Other TTS"
    case .human: "Human"
    }
  }
}

/// The heuristic that pairs an unlinked Storyteller book with a local edition
/// for a suggested (user-confirmable) match: shared identifier evidence, or
/// normalized title equality with compatible author. Presentation only —
/// nothing links in the catalog without the user's confirmation.
enum LibraryMatchSuggestion {
  static func matches(record: BookCatalogRecord, remote: LibraryRemoteBookSnapshot) -> Bool {
    let localIdentifiers = Set(
      record.metadata.identifiers.map { $0.value.lowercased() }.filter { !$0.isEmpty })
    let remoteIdentifiers = Set(
      (remote.identifiers.map(\.value) + remote.assets.flatMap { $0.identifiers.map(\.value) })
        .map { $0.lowercased() }.filter { !$0.isEmpty })
    if !localIdentifiers.isEmpty, !localIdentifiers.isDisjoint(with: remoteIdentifiers) {
      return true
    }
    let title = StorytellerConflictPlanner.normalize(record.metadata.title)
    guard !title.isEmpty, title == StorytellerConflictPlanner.normalize(remote.title) else {
      return false
    }
    guard let author = record.metadata.author,
      case let localAuthor = StorytellerConflictPlanner.normalize(author),
      !localAuthor.isEmpty
    else { return true }
    guard !remote.authors.isEmpty else { return true }
    return remote.authors.contains {
      StorytellerConflictPlanner.normalize($0) == localAuthor
    }
  }
}

enum StudioLibraryFilter: String, CaseIterable, Identifiable {
  case all = "All Books"
  case attention = "Needs Attention"
  case local = "Local Only"
  case storyteller = "Storyteller Only"
  case linked = "Local + Storyteller"

  var id: Self { self }
}

struct StudioLibraryQuery: Equatable {
  var searchText = ""
  var filter: StudioLibraryFilter = .all

  func apply(to rows: [StudioLibraryRow]) -> [StudioLibraryRow] {
    let terms = searchText.folding(
      options: [.caseInsensitive, .diacriticInsensitive], locale: .current
    ).split(whereSeparator: \Character.isWhitespace).map(String.init)
    return rows.filter { row in
      let matchesFilter = switch filter {
      case .all: true
      case .attention:
        row.level.rawValue < LibraryLevel.localComplete.rawValue
          || row.localQualityVerdict.map(Self.problemVerdict) == true
          || row.remoteQualityVerdict.map(Self.problemVerdict) == true
          || row.stale
          || row.suggestedRemote != nil
      case .local: row.presence == .local
      case .storyteller: row.presence == .storyteller
      case .linked: row.presence == .both
      }
      guard matchesFilter, !terms.isEmpty else { return matchesFilter }
      return terms.allSatisfy(row.searchIndex.contains)
    }
  }

  private static func problemVerdict(_ value: String) -> Bool {
    value != ReadAloudAuditVerdict.likelyCorrect.rawValue
  }
}

@MainActor
@Observable
final class StudioLibraryModel {
  private static let selectedConnectionKey = "SpokenFolioLibraryConnection"
  private(set) var records: [BookCatalogRecord] = []
  private(set) var issues: [String] = []
  /// Catalog records whose library edition row is missing. Their books still
  /// render, but quality and coherence cannot be evaluated — surfaced instead
  /// of failing the whole library view.
  private(set) var editionGapCount = 0
  private(set) var connections: [StorytellerConnection] = []
  private(set) var rows: [StudioLibraryRow] = []
  private(set) var snapshotStale = false
  private(set) var isRefreshing = false
  var error: String?
  var pendingRecord: BookCatalogRecord?
  var pendingIdentifierRecord: BookCatalogRecord?
  var pendingProcessingRow: StudioLibraryRow?
  /// The unified Process flow, presented as a sheet while non-nil.
  var processing: LibraryProcessModel?
  var identifierValue = ""
  var pushIdentifierToStoryteller = false
  var connectionID: UUID?
  var candidates: [StorytellerMatchCandidate] = []
  var selectedCandidateID: UUID?
  var selectedRowIDs = Set<String>()
  var isBusy = false

  @ObservationIgnored private let catalogStore: BookCatalogStore
  @ObservationIgnored private let coordinator: StudioJobCoordinator
  @ObservationIgnored private var libraryStore: LibraryStore?
  @ObservationIgnored private var reloadIdentity = UUID()

  init(
    coordinator: StudioJobCoordinator,
    catalogStore: BookCatalogStore = BookCatalogStore(root: AppPaths.bookCatalogRoot)
  ) {
    self.coordinator = coordinator
    self.catalogStore = catalogStore
    connectionID = UserDefaults.standard.string(forKey: Self.selectedConnectionKey)
      .flatMap(UUID.init(uuidString:))
  }

  func reload() async {
    let identity = UUID()
    reloadIdentity = identity
    isRefreshing = false
    do {
      let scan = try await catalogStore.scan()
      guard reloadIdentity == identity else { return }
      records = scan.records
      issues = scan.issues
      connections = try await StorytellerConnectionStore.shared.connections()
      guard reloadIdentity == identity else { return }
      if let connectionID, !connections.contains(where: { $0.id == connectionID }) {
        self.connectionID = nil
        UserDefaults.standard.removeObject(forKey: Self.selectedConnectionKey)
      }
      let library = try durableLibrary()
      snapshotStale = false
      // Selection is pruned only once the final merged row set exists;
      // pruning here would drop remote-only selections mid-refresh.
      rows = try buildRows(library: library)
      if let connectionID,
        let connection = connections.first(where: { $0.id == connectionID })
      {
        isRefreshing = true
        defer { if reloadIdentity == identity { isRefreshing = false } }
        await Task.yield()
        do {
          let token = try await StorytellerConnectionStore.shared.token(connectionID)
          let client = try StorytellerClient(origin: connection.origin, tokenProvider: { token })
          let books = try await client.books()
          guard reloadIdentity == identity else { return }
          _ = try library.replaceRemoteInventory(
            connectionID: connectionID,
            books: books.map { Self.snapshot($0, connectionID: connectionID) })
          error = nil
        } catch {
          guard reloadIdentity == identity else { return }
          snapshotStale = true
          self.error = "Using the last Storyteller snapshot: \(error.localizedDescription)"
        }
      } else { error = nil }
      guard reloadIdentity == identity else { return }
      rows = try buildRows(library: library)
      selectedRowIDs.formIntersection(rows.lazy.map(\.id))
    } catch {
      guard reloadIdentity == identity else { return }
      isRefreshing = false
      self.error = error.localizedDescription
    }
  }

  func selectConnection(_ id: UUID?) {
    selectedRowIDs.removeAll()
    connectionID = id
    UserDefaults.standard.set(id?.uuidString, forKey: Self.selectedConnectionKey)
    Task { await reload() }
  }

  func assertNarration(_ row: StudioLibraryRow, provenance: NarrationProvenance) {
    guard let remote = row.remote, let readAloud = remote.asset(.readaloud) else { return }
    do {
      let library = try durableLibrary()
      let existing = try library.provenance(
        connectionID: remote.connectionID, remoteBookID: remote.remoteBookID,
        remoteAssetID: readAloud.assetID)
      try library.assertProvenance(
        .init(
          connectionID: remote.connectionID, remoteBookID: remote.remoteBookID,
          remoteAssetID: readAloud.assetID, remoteSHA256: readAloud.sha256,
          provenance: provenance, coherence: existing?.coherence ?? .unknown,
          source: "user:narration"))
      Task { await reload() }
    } catch { self.error = error.localizedDescription }
  }

  var selectedRowCount: Int { selectedRowIDs.count }

  var selectedRows: [StudioLibraryRow] {
    rows.filter { selectedRowIDs.contains($0.id) }
  }

  /// Opens the unified Process sheet for the given books.
  func beginProcessing(
    _ rows: [StudioLibraryRow], intent: LibraryProcessModel.Intent,
    processedDirectory: URL, onViewQueue: @escaping () -> Void
  ) {
    guard !rows.isEmpty else { return }
    let model = LibraryProcessModel(
      rows: rows, intent: intent, connections: connections,
      preferredConnectionID: connectionID, coordinator: coordinator,
      catalogStore: catalogStore, processedDirectory: processedDirectory)
    model.onViewQueue = onViewQueue
    processing = model
  }

  enum QualityScope { case local, storyteller, all }

  func selectedQualityTargets(_ scope: QualityScope) -> [LibraryReadAloudAuditTarget] {
    var result: [LibraryReadAloudAuditTarget] = []
    for row in rows where selectedRowIDs.contains(row.id) {
      if scope != .storyteller, row.localReadAloudReady,
        let productID = row.localReadAloudProductID
      {
        let target = LibraryReadAloudAuditTarget.localProduct(productID)
        if !result.contains(target) { result.append(target) }
      }
      if scope != .local, let remote = row.remote,
        let asset = remote.asset(.readaloud), asset.state == .ready
      {
        let target = LibraryReadAloudAuditTarget.remote(
          connectionID: remote.connectionID, bookID: remote.remoteBookID,
          assetID: asset.assetID)
        if !result.contains(target) { result.append(target) }
      }
    }
    return result
  }

  var canAssertSelectedNarration: Bool {
    guard !selectedRowIDs.isEmpty else { return false }
    let selected = rows.filter { selectedRowIDs.contains($0.id) }
    return selected.count == selectedRowIDs.count && selected.allSatisfy {
      $0.remote?.asset(.readaloud)?.state == .ready
    }
  }

  func assertSelectedNarration(_ provenance: NarrationProvenance) {
    let selected = rows.filter { selectedRowIDs.contains($0.id) }
    guard !selected.isEmpty else { return }
    guard selected.count == selectedRowIDs.count,
      selected.allSatisfy({ $0.remote?.asset(.readaloud)?.state == .ready })
    else {
      error = "Narration can only be set in bulk when every selected book has a ready Storyteller ReadAloud."
      return
    }
    do {
      let library = try durableLibrary()
      let assertions = try selected.map { row -> LibraryProvenanceAssertion in
        guard let remote = row.remote, let readAloud = remote.asset(.readaloud) else {
          throw LibraryStoreError.notFound("selected Storyteller ReadAloud")
        }
        let existing = try library.provenance(
          connectionID: remote.connectionID, remoteBookID: remote.remoteBookID,
          remoteAssetID: readAloud.assetID)
        return .init(
          connectionID: remote.connectionID, remoteBookID: remote.remoteBookID,
          remoteAssetID: readAloud.assetID, remoteSHA256: readAloud.sha256,
          provenance: provenance, coherence: existing?.coherence ?? .unknown,
          source: "user:bulk-narration")
      }
      try library.assertProvenance(assertions)
      error = nil
      Task { await reload() }
    } catch { self.error = error.localizedDescription }
  }

  func beginIdentifierEdit(_ row: StudioLibraryRow) {
    guard let record = row.record else { return }
    pendingIdentifierRecord = record
    identifierValue = record.metadata.identifiers.first {
      $0.kind?.lowercased().contains("isbn") == true
    }?.value ?? ""
    pushIdentifierToStoryteller = row.remote != nil
  }

  func saveIdentifier() {
    guard let record = pendingIdentifierRecord,
      let canonical = CanonicalPublicationIdentifier(kind: "isbn", value: identifierValue),
      canonical.kind == .isbn13
    else {
      error = "Enter a valid ISBN-10 or ISBN-13, including its check digit."
      return
    }
    let selectedConnectionID = connectionID
    let linkedRemoteID = selectedConnectionID.flatMap { connectionID in
      record.remoteLinks.first {
        $0.connectionID == connectionID && $0.providerID == "storyteller"
      }.flatMap { UUID(uuidString: $0.remoteBookID) }
    }
    isBusy = true
    Task {
      defer { isBusy = false }
      do {
        try durableLibrary().setEditionIdentifier(
          editionID: record.id, kind: "isbn-13", value: canonical.value,
          note: "Corrected in Library")
        if pushIdentifierToStoryteller, let connectionID = selectedConnectionID,
          let remoteID = linkedRemoteID,
          let connection = connections.first(where: { $0.id == connectionID })
        {
          guard connection.permissions.bookUpdate else {
            throw StorytellerAPIError.missingPermission("bookUpdate")
          }
          let token = try await StorytellerConnectionStore.shared.token(connectionID)
          let client = try StorytellerClient(origin: connection.origin, tokenProvider: { token })
          let capabilities = try await client.mutationCapabilities()
          guard capabilities.identifierETag else {
            throw StorytellerAPIError.unsafeMutationServer(
              "conditional identifier editing is unavailable")
          }
          let snapshot = try await client.bookIdentifiers(remoteID)
          guard let type = try await client.identifierTypes().first(where: { $0.kind == "isbn-13" })
          else { throw StorytellerAPIError.invalidResponse("Storyteller has no ISBN-13 type") }
          var values = snapshot.identifiers.filter {
            !($0.identifierTypeUuid == type.uuid && $0.ebookUuid == nil
              && $0.audiobookUuid == nil && $0.readaloudUuid == nil)
          }
          values.append(.init(identifierTypeUuid: type.uuid, value: canonical.value))
          try await client.replaceBookIdentifiers(
            remoteID, identifiers: values, expectedETag: snapshot.etag)
        }
        pendingIdentifierRecord = nil
        await reload()
      } catch { self.error = error.localizedDescription }
    }
  }

  func startStorytellerReadAloud() {
    guard let row = pendingProcessingRow, let remote = row.remote,
      let connection = connections.first(where: { $0.id == remote.connectionID })
    else { return }
    guard connection.permissions.bookProcess else {
      error = "The selected Storyteller account cannot start ReadAloud processing."
      return
    }
    isBusy = true
    Task {
      defer { isBusy = false }
      do {
        let intent = try durableLibrary().beginRemoteReadAloudAutoAudit(
          connectionID: connection.id, bookID: remote.remoteBookID)
        try durableLibrary().markRemoteReadAloudAutoAuditWaiting(intent.id)
        let token = try await StorytellerConnectionStore.shared.token(connection.id)
        let client = try StorytellerClient(origin: connection.origin, tokenProvider: { token })
        try await client.startReadAloudProcessing(bookID: remote.remoteBookID)
        pendingProcessingRow = nil
        await reload()
      } catch { self.error = error.localizedDescription }
    }
  }

  private func durableLibrary() throws -> LibraryStore {
    if let libraryStore { return libraryStore }
    let value = try LibraryStore(databaseURL: AppPaths.libraryDatabaseURL)
    libraryStore = value
    return value
  }

  private struct AssetKey: Hashable {
    let bookID: UUID
    let assetID: UUID
  }

  /// Everything row construction needs, loaded up front. Querying per row
  /// turns a large library reload into thousands of database round trips.
  private struct RowContext {
    let editionsByID: [UUID: LibraryEdition]
    let provenanceByAsset: [AssetKey: LibraryProvenanceAssertion]
    let auditsByTarget: [LibraryReadAloudAuditTarget: LibraryReadAloudAuditRun]
  }

  private func buildRows(library: LibraryStore) throws -> [StudioLibraryRow] {
    let remoteBooks = try connectionID.map {
      try library.remoteBooks(connectionID: $0, includeMissing: false)
    } ?? []
    let remoteByID = Dictionary(uniqueKeysWithValues: remoteBooks.map { ($0.remoteBookID, $0) })
    let context = try rowContext(library: library, remoteBooks: remoteBooks)
    editionGapCount = records.count { context.editionsByID[$0.id] == nil }
    var consumed = Set<UUID>()
    var result: [StudioLibraryRow] = []
    var linksByRecordID: [UUID: BookCatalogRemoteLink] = [:]
    for record in records {
      let link = connectionID.flatMap { selected in
        record.remoteLinks.first { $0.providerID == "storyteller" && $0.connectionID == selected }
      }
      if let link { linksByRecordID[record.id] = link }
      let remoteID = link.flatMap { UUID(uuidString: $0.remoteBookID) }
      let remote = remoteID.flatMap { remoteByID[$0] }
      if let remoteID, remote != nil { consumed.insert(remoteID) }
      result.append(try row(record: record, remote: remote, context: context))
    }
    // Group unlinked remote books that look like a local edition into that
    // edition's row as a suggested match instead of a confusing second row.
    // Declined suggestions are remembered in the link's exclusion list.
    for remote in remoteBooks where !consumed.contains(remote.remoteBookID) {
      let candidateIndex = result.firstIndex { candidate in
        guard let record = candidate.record, candidate.remote == nil,
          candidate.suggestedRemote == nil
        else { return false }
        let excluded = linksByRecordID[record.id]?.excludedRemoteBookIDs ?? []
        guard !excluded.contains(remote.remoteBookID.uuidString.lowercased()) else {
          return false
        }
        return LibraryMatchSuggestion.matches(record: record, remote: remote)
      }
      if let candidateIndex {
        let existing = result[candidateIndex]
        result[candidateIndex] = try row(
          record: existing.record, remote: nil, suggested: remote, context: context)
      } else {
        result.append(try row(record: nil, remote: remote, context: context))
      }
    }
    return result.sorted {
      if $0.level != $1.level { return $0.level > $1.level }
      return $0.title.localizedStandardCompare($1.title) == .orderedAscending
    }
  }

  private func rowContext(
    library: LibraryStore, remoteBooks: [LibraryRemoteBookSnapshot]
  ) throws -> RowContext {
    let editionsByID = Dictionary(
      try library.scanEditions().editions.map { ($0.id, $0) },
      uniquingKeysWith: { first, _ in first })
    let provenanceByAsset = Dictionary(
      try (connectionID.map(library.latestProvenances(connectionID:)) ?? []).map {
        (AssetKey(bookID: $0.remoteBookID, assetID: $0.remoteAssetID), $0)
      },
      uniquingKeysWith: { first, _ in first })
    var requests: [LibraryStore.ReadAloudAuditApplicabilityRequest] = []
    for record in records {
      guard let edition = editionsByID[record.id],
        let product = edition.products.first(where: { $0.kind == .readAloudEPUB })
      else { continue }
      requests.append(
        .init(
          target: .localProduct(product.id), artifactSHA256: product.sha256,
          referenceSHA256: edition.source.sha256))
    }
    for remote in remoteBooks {
      guard let asset = remote.asset(.readaloud), let sha256 = asset.sha256 else { continue }
      requests.append(
        .init(
          target: .remote(
            connectionID: remote.connectionID, bookID: remote.remoteBookID,
            assetID: asset.assetID),
          artifactSHA256: sha256, referenceSHA256: nil))
    }
    return RowContext(
      editionsByID: editionsByID,
      provenanceByAsset: provenanceByAsset,
      auditsByTarget: try library.latestApplicableReadAloudAudits(
        requests, analyzerIdentity: "readaloud-quality-v1",
        policyVersion: ReadAloudQualityAuditor.policyVersion))
  }

  private func row(
    record: BookCatalogRecord?, remote: LibraryRemoteBookSnapshot?,
    suggested: LibraryRemoteBookSnapshot? = nil, context: RowContext
  ) throws -> StudioLibraryRow {
    guard record != nil || remote != nil else {
      throw BookJobError.corruptState("library row has neither a local nor remote edition")
    }
    let readAloud = remote?.asset(.readaloud)
    let assertion = remote.flatMap { remote in
      readAloud.flatMap { asset in
        context.provenanceByAsset[
          AssetKey(bookID: remote.remoteBookID, assetID: asset.assetID)]
      }
    }
    let link = record.flatMap { record in
      remote.map { remote in
        record.remoteLinks.first {
          $0.connectionID == remote.connectionID && $0.remoteBookID == remote.remoteBookID.uuidString.lowercased()
        }
      } ?? nil
    }
    let provenFormats = Set(link?.receipts.compactMap { receipt -> LibraryRemoteFormat? in
      guard let format = LibraryRemoteFormat(rawValue: receipt.format),
        let asset = remote?.asset(format), receipt.remoteSHA256 != nil,
        receipt.remoteAssetID == asset.assetID.uuidString.lowercased(),
        receipt.remoteSize == nil || receipt.remoteSize == asset.fileSize
      else { return nil }
      return format
    } ?? [])
    let deliveredTTS = provenFormats.contains(.audiobook) && provenFormats.contains(.readaloud)
    let narration = assertion?.provenance ?? (deliveredTTS ? .spokenFolioTTS : .unknown)
    let localEPUB = record?.product(.sourceEPUB).map(Self.localProductReady) == true
    let localAudio = record?.product(.m4b).map(Self.localProductReady) == true
    let localRA = record?.product(.readAloudEPUB).map(Self.localProductReady) == true
    let localEdition = record.flatMap { context.editionsByID[$0.id] }
    let localReadAloudProductID = localEdition?.products.first {
      $0.kind == .readAloudEPUB
    }?.id
    let localAudit = localReadAloudProductID.flatMap {
      context.auditsByTarget[.localProduct($0)]
    }
    let remoteAudit = remote.flatMap { remote in
      remote.asset(.readaloud).flatMap { asset in
        context.auditsByTarget[
          .remote(
            connectionID: remote.connectionID, bookID: remote.remoteBookID,
            assetID: asset.assetID)]
      }
    }
    let remoteEPUB = remote?.asset(.ebook)?.state == .ready
    let remoteAudio = remote?.asset(.audiobook)?.state == .ready
    let remoteRA = readAloud?.state == .ready
    // Mere co-location is not proof that three independently replaceable
    // assets describe the same edition. Coherence requires verified delivery
    // receipts or an explicit provenance assertion.
    let deliveredCoherence: PackageCoherence =
      Set(LibraryRemoteFormat.allCases).isSubset(of: provenFormats) ? .verified : .unknown
    let remoteCoherence = Self.qualityCoherence(
      base: assertion?.coherence ?? deliveredCoherence, audit: remoteAudit)
    let state = LibraryPackageState(
      localEPUBReady: localEPUB, localAudiobookReady: localAudio,
      localReadAloudReady: localRA,
      localCoherence: Self.qualityCoherence(
        base: Self.localCoherence(localEdition), audit: localAudit),
      remoteEPUBReady: remoteEPUB, remoteAudiobookReady: remoteAudio,
      remoteReadAloudReady: remoteRA,
      remoteCoherence: remoteCoherence, remoteNarration: narration)
    let presence: StudioLibraryRow.Presence = if record != nil && remote != nil {
      .both
    } else if record != nil { .local } else { .storyteller }
    let rowID = record.map { "local:\($0.id.uuidString)" }
      ?? remote.map { "remote:\($0.connectionID.uuidString):\($0.remoteBookID.uuidString)" }
      ?? "invalid"
    return StudioLibraryRow(
      id: rowID,
      title: record?.metadata.title ?? remote?.title ?? "Untitled",
      author: record?.metadata.author ?? remote?.authors.joined(separator: ", "),
      record: record, remote: remote, level: state.level, presence: presence,
      narration: narration, stale: snapshotStale, localEPUBReady: localEPUB,
      localAudiobookReady: localAudio, localReadAloudReady: localRA,
      localReadAloudProductID: localReadAloudProductID,
      ttsProvenance: record?.product(.m4b)?.narration.map(Self.ttsProvenance),
      localQualityVerdict: localAudit?.verdict, remoteQualityVerdict: remoteAudit?.verdict,
      updatedAt: record?.updatedAt ?? Self.remoteUpdatedAt(remote) ?? .distantPast,
      searchIndex: Self.searchIndex(record: record, remote: remote ?? suggested),
      suggestedRemote: suggested)
  }

  /// The remote book's own modification time; the snapshot's `observedAt`
  /// only records when this Mac last fetched the inventory.
  private static func remoteUpdatedAt(_ remote: LibraryRemoteBookSnapshot?) -> Date? {
    guard let remote else { return nil }
    guard let value = remote.updatedAt else { return remote.observedAt }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: value)
      ?? ISO8601DateFormatter().date(from: value)
      ?? remote.observedAt
  }

  private static func searchIndex(
    record: BookCatalogRecord?, remote: LibraryRemoteBookSnapshot?
  ) -> String {
    var values = [record?.metadata.title, record?.metadata.author, remote?.title]
      .compactMap { $0 }
    values.append(contentsOf: remote?.authors ?? [])
    values.append(contentsOf: record?.metadata.identifiers.map(\.value) ?? [])
    values.append(contentsOf: remote?.identifiers.map(\.value) ?? [])
    values.append(contentsOf: remote?.assets.flatMap { $0.identifiers.map(\.value) } ?? [])
    return values.joined(separator: " \u{1f}")
  }

  private static func ttsProvenance(_ narration: BookJobRequest.Narration) -> String {
    var values = [
      "\(narration.backendID)/\(narration.modelID)",
      "voice \(narration.voiceID)" + (narration.voiceRevision.map { " v\($0)" } ?? ""),
    ]
    if let runtime = narration.runtime {
      values.append("macOS \(runtime.macOSVersion) (\(runtime.macOSBuild))")
      values.append("SiriTTSService \(runtime.frameworkVersion)")
    } else if let revision = narration.modelRevision {
      values.append(revision)
    } else {
      values.append("runtime not recorded (legacy audiobook)")
    }
    return values.joined(separator: " • ")
  }

  private static func localCoherence(_ edition: LibraryEdition?) -> PackageCoherence {
    guard let edition,
      let m4b = edition.products.first(where: { $0.kind == .m4b }),
      let readAloud = edition.products.first(where: { $0.kind == .readAloudEPUB })
    else { return .unknown }
    let m4bDependencies = edition.dependencies.filter { $0.productID == m4b.id }
    let readAloudDependencies = edition.dependencies.filter { $0.productID == readAloud.id }
    guard m4bDependencies.contains(where: {
      $0.role == .source && $0.inputSHA256 == edition.source.sha256
    }),
      readAloudDependencies.contains(where: {
        $0.role == .source && $0.inputSHA256 == edition.source.sha256
      }),
      readAloudDependencies.contains(where: {
        $0.role == .alignmentAudio && $0.inputSHA256 == m4b.sha256
      })
    else { return .unknown }
    return .verified
  }

  private static func qualityCoherence(
    base: PackageCoherence, audit: LibraryReadAloudAuditRun?
  ) -> PackageCoherence {
    guard let audit else { return .unknown }
    if audit.verdict == ReadAloudAuditVerdict.broken.rawValue
      || audit.verdict == ReadAloudAuditVerdict.likelyBroken.rawValue
    {
      return .conflict
    }
    guard audit.verdict == ReadAloudAuditVerdict.likelyCorrect.rawValue,
      [
        ReadAloudEvidenceAdequacy.complete.rawValue,
        ReadAloudEvidenceAdequacy.sampled.rawValue,
      ].contains(audit.evidenceAdequacy ?? "")
    else { return .unknown }
    return base == .verified ? .verified : .unknown
  }

  private static func localProductReady(_ product: BookCatalogProduct) -> Bool {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: product.path),
      let type = attributes[.type] as? FileAttributeType, type == .typeRegular,
      let size = attributes[.size] as? NSNumber,
      let modificationDate = attributes[.modificationDate] as? Date
    else { return false }
    return size.uint64Value == product.size
      && modificationDate <= product.verifiedAt.addingTimeInterval(1)
  }

  private static func snapshot(
    _ book: StorytellerBook, connectionID: UUID
  ) -> LibraryRemoteBookSnapshot {
    var identifiers = book.identifiers.compactMap { identifier in
      identifier.effectiveValue.map { value in
        LibraryRemoteIdentifier(
          id: identifier.uuid, kind: identifier.kind, name: identifier.name, value: value)
      }
    }
    func asset(_ value: StorytellerAsset?, format: LibraryRemoteFormat)
      -> LibraryRemoteAssetSnapshot?
    {
      guard let value else { return nil }
      let scope: LibraryIdentifierScope = switch format {
      case .ebook: .ebook
      case .audiobook: .audiobook
      case .readaloud: .readaloud
      }
      let nested = value.identifiers.compactMap { identifier in
        identifier.effectiveValue.map { value in
          LibraryRemoteIdentifier(
            id: identifier.uuid, kind: identifier.kind, name: identifier.name,
            value: value, scope: scope)
        }
      }
      identifiers.append(contentsOf: nested)
      let status = value.status?.uppercased()
      let state: LibraryRemoteAssetState
      if value.missing == true {
        state = .missing
      } else if format != .readaloud {
        state = value.isAvailable ? .ready : .unknown
      } else {
        state = switch status {
        case "ALIGNED": value.isAvailable ? .ready : .unknown
        case "ERROR": .broken
        case "CREATED", "QUEUED", "PROCESSING": .processing
        case "STOPPED": .unknown
        default: .unknown
        }
      }
      return .init(
        format: format, assetID: value.uuid, filepath: value.filepath,
        fingerprint: value.fingerprint, fileSize: value.fileSize,
        updatedAt: value.updatedAt, state: state, status: value.status,
        currentStage: value.currentStage, stageProgress: value.stageProgress,
        identifiers: nested)
    }
    let assets = [
      asset(book.ebook, format: .ebook), asset(book.audiobook, format: .audiobook),
      asset(book.readaloud, format: .readaloud),
    ].compactMap { $0 }
    return .init(
      connectionID: connectionID, remoteBookID: book.uuid, title: book.title,
      subtitle: book.subtitle, authors: book.authors.map(\.name),
      narrators: book.narrators.map(\.name), identifiers: identifiers,
      assets: assets, updatedAt: book.updatedAt)
  }

  func beginMatch(_ record: BookCatalogRecord) {
    pendingRecord = record
    if !connections.contains(where: { $0.id == connectionID }) {
      connectionID = connections.first?.id
    }
    candidates = []
    selectedCandidateID = nil
    error = nil
  }

  func dismissMatch() {
    pendingRecord = nil
    candidates = []
    selectedCandidateID = nil
  }

  /// Link-only edition matching: resolves the identity, links automatically
  /// when the evidence is safe, and otherwise surfaces candidates to review.
  /// Nothing is uploaded; sending lives in the Process flow.
  func findMatch() {
    guard let record = pendingRecord, let connectionID,
      let connection = connections.first(where: { $0.id == connectionID })
    else { return }
    isBusy = true
    Task {
      defer { isBusy = false }
      do {
        let token = try await StorytellerConnectionStore.shared.token(connectionID)
        let client = try StorytellerClient(origin: connection.origin, tokenProvider: { token })
        let link = record.remoteLinks.first {
          $0.providerID == "storyteller" && $0.connectionID == connectionID
        }
        let localProducts = record.products.map { product in
          StorytellerLocalProductIdentity(
            format: Self.remoteFormat(product.kind), size: product.size, sha256: product.sha256)
        }
        let resolution = try await StorytellerIdentityResolver(client: client).resolve(
          local: .init(
            title: record.metadata.title, author: record.metadata.author,
            identifiers: record.metadata.identifiers, products: localProducts,
            excludedBookIDs: Set(
              link?.excludedRemoteBookIDs.compactMap(UUID.init(uuidString:)) ?? [])),
          linkedBookID: link.flatMap { UUID(uuidString: $0.remoteBookID) })
        switch resolution {
        case .linked(let id):
          _ = try await persistLink(record, remoteID: id, evidence: link?.evidence)
          dismissMatch()
          await reload()
        case .automatic(let id, let evidence):
          _ = try await persistLink(
            record, remoteID: id,
            evidence: evidence == .exactAssetHash ? .exactAssetHash : .validatedIdentifier)
          dismissMatch()
          await reload()
        case .create:
          let books = try await client.books()
          candidates = books.map { .init(book: $0, reasons: []) }
          selectedCandidateID = nil
          if candidates.isEmpty { error = "The selected Storyteller library is empty." }
        case .review(let values):
          let rankedIDs = Set(values.map(\.id))
          let remaining = try await client.books().filter { !rankedIDs.contains($0.uuid) }
            .map { StorytellerMatchCandidate(book: $0, reasons: []) }
          candidates = values + remaining
          selectedCandidateID = nil
        }
      } catch { self.error = error.localizedDescription }
    }
  }

  private static func remoteFormat(_ kind: BookProductKind) -> StorytellerFormat {
    switch kind {
    case .sourceEPUB: .ebook
    case .m4b: .audiobook
    case .readAloudEPUB: .readaloud
    }
  }

  /// The user confirmed a suggested match: link with user-confirmed evidence.
  func confirmSuggestedMatch(_ row: StudioLibraryRow) {
    guard let record = row.record, let suggested = row.suggestedRemote else { return }
    isBusy = true
    Task {
      defer { isBusy = false }
      do {
        _ = try await persistLink(
          record, remoteID: suggested.remoteBookID, evidence: .userConfirmed)
        await reload()
      } catch { self.error = error.localizedDescription }
    }
  }

  /// The user declared a suggested match a different edition: remember the
  /// exclusion so the suggestion never returns for this pair.
  func declineSuggestedMatch(_ row: StudioLibraryRow) {
    guard let record = row.record, let suggested = row.suggestedRemote else { return }
    isBusy = true
    Task {
      defer { isBusy = false }
      do {
        var updated = record
        let previous = updated.remoteLinks.first {
          $0.providerID == "storyteller" && $0.connectionID == suggested.connectionID
        }
        var exclusions = previous?.excludedRemoteBookIDs ?? []
        let excludedID = suggested.remoteBookID.uuidString.lowercased()
        if !exclusions.contains(excludedID) { exclusions.append(excludedID) }
        updated.upsertRemoteLink(
          .init(
            providerID: "storyteller", connectionID: suggested.connectionID,
            remoteBookID: previous?.remoteBookID
              ?? DeterministicBookID.make(catalogID: record.id).uuidString.lowercased(),
            evidence: previous?.evidence ?? .uploadCreated,
            linkedAt: previous?.linkedAt ?? Date(),
            lastObservedAt: previous?.lastObservedAt,
            remoteTitle: previous?.remoteTitle,
            remoteAuthors: previous?.remoteAuthors ?? [],
            receipts: previous?.receipts ?? [],
            excludedRemoteBookIDs: exclusions))
        try await catalogStore.update(updated, expectedRevision: record.revision)
        await reload()
      } catch { self.error = error.localizedDescription }
    }
  }

  func linkSelectedCandidate() {
    guard let record = pendingRecord, let selectedCandidateID else { return }
    isBusy = true
    Task {
      defer { isBusy = false }
      do {
        _ = try await persistLink(
          record, remoteID: selectedCandidateID, evidence: .userConfirmed)
        dismissMatch()
        await reload()
      } catch { self.error = error.localizedDescription }
    }
  }

  func forgetLink(_ record: BookCatalogRecord, connectionID: UUID) {
    Task {
      do {
        var updated = record
        updated.remoteLinks.removeAll {
          $0.providerID == "storyteller" && $0.connectionID == connectionID
        }
        updated.touch()
        try await catalogStore.update(updated, expectedRevision: record.revision)
        await reload()
      } catch { self.error = error.localizedDescription }
    }
  }

  private func persistLink(
    _ record: BookCatalogRecord, remoteID: UUID,
    evidence: BookCatalogRemoteLink.Evidence?
  ) async throws -> BookCatalogRecord {
    guard let connectionID else { throw StorytellerAPIError.authenticationRequired }
    var updated = record
    let previous = updated.remoteLinks.first {
      $0.providerID == "storyteller" && $0.connectionID == connectionID
    }
    updated.upsertRemoteLink(
      .init(
        providerID: "storyteller", connectionID: connectionID,
        remoteBookID: remoteID.uuidString.lowercased(),
        evidence: evidence ?? .userConfirmed,
        linkedAt: previous?.linkedAt ?? Date(),
        lastObservedAt: previous?.lastObservedAt,
        remoteTitle: previous?.remoteTitle,
        remoteAuthors: previous?.remoteAuthors ?? [],
        receipts: previous?.receipts ?? [],
        excludedRemoteBookIDs: previous?.excludedRemoteBookIDs ?? []))
    if updated != record {
      try await catalogStore.update(updated, expectedRevision: record.revision)
    }
    return updated
  }
}

struct StudioProcessingSheet: View {
  @Bindable var model: StudioLibraryModel
  let row: StudioLibraryRow

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Create Storyteller ReadAloud").font(.title2.bold())
      Text(row.title).font(.headline)
      Text(
        "Storyteller will align its existing ebook and human audiobook. This can be compute-intensive and runs on the Storyteller server. No audiobook is downloaded to this Mac. SpokenFolio automatically queues a quality check when processing finishes."
      ).foregroundStyle(.secondary)
      if let error = model.error { Text(error).font(.caption).foregroundStyle(.red) }
      HStack {
        Button("Cancel") { model.pendingProcessingRow = nil }
        Spacer()
        if model.isBusy { ProgressView().controlSize(.small) }
        Button("Start Processing") { model.startStorytellerReadAloud() }
          .keyboardShortcut(.defaultAction).disabled(model.isBusy)
      }
    }.padding(20).frame(idealWidth: 520)
  }
}

struct StudioIdentifierSheet: View {
  @Bindable var model: StudioLibraryModel
  let record: BookCatalogRecord

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Correct edition identifier").font(.title2.bold())
      Text(record.metadata.title).foregroundStyle(.secondary)
      TextField("ISBN-10 or ISBN-13", text: $model.identifierValue)
      Toggle("Also update the linked Storyteller edition", isOn: $model.pushIdentifierToStoryteller)
        .disabled(model.connectionID == nil)
      Text(
        "This changes SpokenFolio's edition assertion, not metadata inside the original EPUB. Storyteller changes use a reviewed, conditional update."
      ).font(.caption).foregroundStyle(.secondary)
      if let error = model.error { Text(error).font(.caption).foregroundStyle(.red) }
      HStack {
        Button("Cancel") { model.pendingIdentifierRecord = nil }
        Spacer()
        if model.isBusy { ProgressView().controlSize(.small) }
        Button("Save") { model.saveIdentifier() }
          .keyboardShortcut(.defaultAction).disabled(model.isBusy)
      }
    }.padding(20).frame(idealWidth: 500)
  }
}

struct StudioLibraryMatchSheet: View {
  @Bindable var model: StudioLibraryModel
  let record: BookCatalogRecord

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Match Storyteller Edition").font(.title2.bold())
      Text(record.metadata.title).foregroundStyle(.secondary)
      Picker("Server", selection: $model.connectionID) {
        ForEach(model.connections) { connection in
          Text("\(connection.displayName) — \(connection.username)")
            .tag(Optional(connection.id))
        }
      }
      Text("Link this edition to a Storyteller book without uploading any files. Sending products lives in the Process flow.")
        .font(.caption).foregroundStyle(.secondary)
      if !model.candidates.isEmpty {
        Text("Possible Storyteller editions").font(.headline)
        Text("Select a candidate only after comparing its title, author, and identifiers.")
          .font(.caption).foregroundStyle(.secondary)
        StorytellerCandidateList(
          candidates: model.candidates,
          selectedCandidateID: $model.selectedCandidateID)
        Button("Link Selected Edition") { model.linkSelectedCandidate() }
          .disabled(model.selectedCandidateID == nil || model.isBusy)
      }
      if let error = model.error { Text(error).font(.caption).foregroundStyle(.red) }
      Spacer(minLength: 0)
      HStack {
        Button("Cancel") { model.dismissMatch() }
        Spacer()
        if model.isBusy { ProgressView().controlSize(.small) }
        if model.candidates.isEmpty {
          Button("Find Match") { model.findMatch() }
            .keyboardShortcut(.defaultAction).disabled(model.isBusy)
        }
      }
    }.padding(20).frame(idealWidth: 640, idealHeight: 560)
  }
}

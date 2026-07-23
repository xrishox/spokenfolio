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

  private func buildRows(library: LibraryStore) throws -> [StudioLibraryRow] {
    let output = try LibraryRowBuilder.buildRows(
      library: library, records: records, connectionID: connectionID,
      snapshotStale: snapshotStale)
    editionGapCount = output.editionGapCount
    return output.rows
  }

  static func snapshot(
    _ book: StorytellerBook, connectionID: UUID
  ) -> LibraryRemoteBookSnapshot {
    LibraryRowBuilder.snapshot(book, connectionID: connectionID)
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

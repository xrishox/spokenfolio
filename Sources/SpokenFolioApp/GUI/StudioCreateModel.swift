import AppKit
import AudiobookKit
import BookJobKit
import EPUBKit
import Foundation
import Observation
import PublicationKit
import ReadAloudKit
import SiriTTSCore
import StorytellerKit
import TTSKit

@MainActor
@Observable
final class StudioBookDraft: Identifiable {
  enum Status: Equatable { case loading, ready, invalid(String), queued, skipped(String) }

  struct Section: Identifiable {
    let id: Int
    let title: String
    let role: String
    let characterCount: Int
    let initiallyIncluded: Bool
    var included: Bool
  }

  let id = UUID()
  let sourceURL: URL
  var status: Status = .loading
  var sourceSHA256 = ""
  var sourceSize: UInt64 = 0
  var title = ""
  var author = ""
  var language: String?
  var publisher: String?
  var publicationDate: String?
  var identifiers: [PublicationIdentifier] = []
  var coverImage: NSImage?
  var chapterCount = 0
  var sections: [Section] = []
  var catalogRecord: BookCatalogRecord?
  var usesBatchDefaults = true
  var voiceID = ""
  var bitrateKbps = 256
  var workers = AudiobookConfig.autoMaxWorkers
  var announceTitles = true
  var paragraphPause = 0.6
  var chapterPause = 1.75
  var createReadAloud = false
  var readAloudBitrateKbps = 32
  var readAloudASREngineID = "apple"
  var readAloudASRModelID = "large-v3-turbo"
  var outputDirectoryOverride: URL?
  var storytellerConnectionID: UUID?
  var sendSourceEPUB = false
  var sendM4B = false
  var sendReadAloud = false
  var warning: String?
  var reprocessExistingAudiobook = false

  init(sourceURL: URL) { self.sourceURL = sourceURL }
}

@MainActor
@Observable
final class StudioCreateModel {
  enum Phase: Equatable { case empty, importing, configure, queueing, queued }

  private struct ImportPayload: Sendable {
    let sha256: String
    let size: UInt64
    let metadata: PublicationMetadata
    let coverData: Data?
    let chapterCount: Int
    let sections: [(Int, String, String, Int, Bool)]
  }

  private(set) var phase: Phase = .empty
  private(set) var drafts: [StudioBookDraft] = []
  var selectedDraftID: UUID?
  var selectedDraftIDs: Set<UUID> = [] {
    didSet {
      if selectedDraftIDs.count == 1 { selectedDraftID = selectedDraftIDs.first }
      else if let selectedDraftID, !selectedDraftIDs.contains(selectedDraftID) {
        self.selectedDraftID = selectedDraftIDs.first
      }
    }
  }
  private(set) var voices: [VoiceDescriptor] = []
  private(set) var storytellerConnections: [StorytellerConnection] = []
  private(set) var permissionWarning: String?
  private(set) var error: String?
  private(set) var notice: String?
  private(set) var processedDirectory: URL

  var voiceID = "" { didSet { propagateDefaults() } }
  var bitrateKbps = 256 { didSet { propagateDefaults() } }
  var workers = AudiobookConfig.autoMaxWorkers { didSet { propagateDefaults() } }
  var announceTitles = true { didSet { propagateDefaults() } }
  var paragraphPause = 0.6 { didSet { propagateDefaults() } }
  var chapterPause = 1.75 { didSet { propagateDefaults() } }
  var createReadAloud = false { didSet { propagateDefaults() } }
  var readAloudBitrateKbps = 32 { didSet { propagateDefaults() } }
  var readAloudASREngineID = "apple" { didSet { propagateDefaults() } }
  var readAloudASRModelID = "large-v3-turbo" { didSet { propagateDefaults() } }
  var storytellerConnectionID: UUID? { didSet { propagateDefaults() } }
  var sendSourceEPUB = false { didSet { propagateDefaults() } }
  var sendM4B = false { didSet { propagateDefaults() } }
  var sendReadAloud = false { didSet { propagateDefaults() } }

  var presentOpenPanel: ((@escaping @MainActor ([URL]) -> Void) -> Void)?
  var presentDirectoryPanel: ((URL?, @escaping @MainActor (URL?) -> Void) -> Void)?
  var onQueued: (() -> Void)?

  @ObservationIgnored private let coordinator: StudioJobCoordinator
  @ObservationIgnored private let catalogStore: BookCatalogStore
  @ObservationIgnored private let settingsStore: StudioSettingsStore
  @ObservationIgnored private var configuredWorkDirectory: String?
  @ObservationIgnored private var isPropagating = false
  @ObservationIgnored private var didStart = false
  @ObservationIgnored private var importTask: Task<Void, Never>?
  @ObservationIgnored private var importGeneration = 0

  init(
    coordinator: StudioJobCoordinator,
    catalogStore: BookCatalogStore = BookCatalogStore(root: AppPaths.bookCatalogRoot),
    settingsStore: StudioSettingsStore = StudioSettingsStore(url: AppPaths.studioSettingsURL)
  ) {
    self.coordinator = coordinator
    self.catalogStore = catalogStore
    self.settingsStore = settingsStore
    processedDirectory = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Books/Processed", isDirectory: true)
  }

  var selectedDraft: StudioBookDraft? {
    drafts.first { $0.id == selectedDraftID }
  }

  var selectedDrafts: [StudioBookDraft] {
    drafts.filter { selectedDraftIDs.contains($0.id) }
  }

  var hasUnqueuedDrafts: Bool { unqueuedDraftCount > 0 }

  var unqueuedDraftCount: Int {
    drafts.count { draft in
      if case .queued = draft.status { return false }
      return true
    }
  }

  var readyCount: Int { drafts.filter { $0.status == .ready }.count }
  var loadingCount: Int { drafts.filter { $0.status == .loading }.count }

  func start() async {
    guard !didStart else { return }
    didStart = true
    do {
      let settings = try await settingsStore.load()
      processedDirectory = settings.resolvedProcessedDirectory(
        home: FileManager.default.homeDirectoryForCurrentUser)
      let appConfig = try AppConfig.load()
      configuredWorkDirectory = appConfig.audiobook.workDirectory
      bitrateKbps = appConfig.audiobook.defaultBitrateKbps
      workers = appConfig.audiobook.resolvedMaxWorkers
      announceTitles = appConfig.audiobook.announceTitles
      paragraphPause = appConfig.audiobook.paragraphPauseSeconds
      chapterPause = appConfig.audiobook.chapterPauseSeconds
      let configuredVoice = appConfig.audiobook.defaultVoice ?? appConfig.server.defaultVoice
      let inventory = try await SiriVoiceInventory.load(configuredVoice: configuredVoice)
      voices = inventory.voices
      voiceID = inventory.defaultVoiceID
      permissionWarning = inventory.permissionWarning
      try await refreshStorytellerConnections()
    } catch { self.error = error.localizedDescription }
  }

  func requestBooks() {
    presentOpenPanel? { [weak self] urls in self?.addBooks(urls) }
  }

  func refreshSettings() async {
    do {
      processedDirectory = try await settingsStore.load().resolvedProcessedDirectory(
        home: FileManager.default.homeDirectoryForCurrentUser)
    } catch { self.error = error.localizedDescription }
  }

  func useProcessedDirectory(_ directory: URL) {
    processedDirectory = directory.standardizedFileURL
  }

  func addBooks(_ urls: [URL], reprocessExistingAudiobook: Bool = false) {
    if reprocessExistingAudiobook {
      let paths = Set(urls.map { $0.standardizedFileURL.path })
      let matches = drafts.filter { paths.contains($0.sourceURL.standardizedFileURL.path) }
      for draft in matches {
        draft.reprocessExistingAudiobook = true
        if !draft.sourceSHA256.isEmpty { draft.status = .ready }
      }
      if let last = matches.last {
        selectedDraftID = last.id
        selectedDraftIDs = [last.id]
      }
    }
    let existing = Set(drafts.map { $0.sourceURL.standardizedFileURL.path })
    var seen = Set<String>()
    var duplicates = 0
    var unsupported = 0
    var unique: [URL] = []
    for url in urls {
      guard url.pathExtension.lowercased() == "epub" else {
        unsupported += 1
        continue
      }
      let path = url.standardizedFileURL.path
      guard !existing.contains(path), seen.insert(path).inserted else {
        duplicates += 1
        continue
      }
      unique.append(url)
    }
    if !reprocessExistingAudiobook {
      notice = Self.additionNotice(duplicates: duplicates, unsupported: unsupported)
    }
    guard !unique.isEmpty else {
      if reprocessExistingAudiobook {
        phase = drafts.isEmpty
          ? .empty
          : drafts.contains(where: { $0.sourceSHA256.isEmpty }) ? .importing : .configure
      }
      return
    }
    let additions = unique.map { url in
      let draft = StudioBookDraft(sourceURL: url)
      draft.reprocessExistingAudiobook = reprocessExistingAudiobook
      return draft
    }
    drafts.append(contentsOf: additions)
    if selectedDraftID == nil {
      selectedDraftID = additions.first?.id
      selectedDraftIDs = Set(additions.prefix(1).map(\.id))
    }
    phase = .importing
    scheduleImport(additions)
  }

  /// Serializes import batches so a pile of drops never fans out into
  /// unbounded concurrent hashing. Cancellation runs on a generation counter
  /// because Task.cancel() on the newest link cannot reach earlier links of
  /// the await chain that are still hashing.
  private func scheduleImport(_ additions: [StudioBookDraft]) {
    let generation = importGeneration
    let previous = importTask
    importTask = Task { [weak self] in
      await previous?.value
      guard let self, self.importGeneration == generation, !Task.isCancelled else { return }
      await self.importDrafts(additions, generation: generation)
    }
  }

  static func additionNotice(duplicates: Int, unsupported: Int) -> String? {
    var parts: [String] = []
    if duplicates > 0 {
      parts.append("\(duplicates) already-imported EPUB\(duplicates == 1 ? "" : "s")")
    }
    if unsupported > 0 {
      parts.append("\(unsupported) file\(unsupported == 1 ? "" : "s") without an .epub extension")
    }
    guard !parts.isEmpty else { return nil }
    return "Skipped \(parts.joined(separator: " and "))."
  }

  func removeDraft(_ id: UUID) {
    drafts.removeAll { $0.id == id }
    selectedDraftIDs.remove(id)
    if selectedDraftID == id { selectedDraftID = drafts.first?.id }
    if selectedDraftIDs.isEmpty, let selectedDraftID { selectedDraftIDs = [selectedDraftID] }
    if drafts.isEmpty { phase = .empty }
  }

  func removeDrafts(_ ids: Set<UUID>) {
    guard !ids.isEmpty else { return }
    drafts.removeAll { ids.contains($0.id) }
    selectedDraftIDs.subtract(ids)
    if let selectedDraftID, ids.contains(selectedDraftID) {
      self.selectedDraftID = selectedDraftIDs.first ?? drafts.first?.id
    }
    if selectedDraftIDs.isEmpty, let selectedDraftID { selectedDraftIDs = [selectedDraftID] }
    if drafts.isEmpty { phase = .empty }
  }

  func retryImports(_ ids: Set<UUID>) {
    let retrying = drafts.filter { draft in
      guard ids.contains(draft.id) else { return false }
      switch draft.status {
      case .invalid, .skipped: return true
      default: return false
      }
    }
    guard !retrying.isEmpty else { return }
    retrying.forEach { $0.status = .loading }
    phase = .importing
    scheduleImport(retrying)
  }

  func moveDrafts(fromOffsets offsets: IndexSet, toOffset destination: Int) {
    guard !offsets.isEmpty else { return }
    let moving = offsets.sorted().map { drafts[$0] }
    for index in offsets.sorted(by: >) { drafts.remove(at: index) }
    let removedBeforeDestination = offsets.filter { $0 < destination }.count
    let insertion = max(0, min(drafts.count, destination - removedBeforeDestination))
    drafts.insert(contentsOf: moving, at: insertion)
  }

  func customize(_ draft: StudioBookDraft) { draft.usesBatchDefaults = false }

  func resetToBatchDefaults(_ draft: StudioBookDraft) {
    draft.usesBatchDefaults = true
    applyDefaults(to: draft)
  }

  func chooseDirectory(for draft: StudioBookDraft) {
    presentDirectoryPanel?(draft.outputDirectoryOverride ?? processedDirectory) { value in
      guard let value else { return }
      draft.outputDirectoryOverride = value.standardizedFileURL
      draft.usesBatchDefaults = false
    }
  }

  func queueReadyBooks() {
    guard loadingCount == 0, readyCount > 0, phase != .queueing else { return }
    phase = .queueing
    error = nil
    Task {
      let ready = drafts.filter { $0.status == .ready }
      let batchID = UUID()
      var requests: [BookJobRequest] = []
      var requestDrafts: [UUID: StudioBookDraft] = [:]
      for (ordinal, draft) in ready.enumerated() {
        do {
          guard let request = try await makeRequest(
            for: draft, batchID: batchID, ordinal: ordinal, count: ready.count)
          else { continue }
          requests.append(request)
          requestDrafts[request.id] = draft
        } catch {
          draft.status = .invalid(error.localizedDescription)
        }
      }
      for index in requests.indices {
        requests[index].batchOrdinal = index
        requests[index].batchCount = requests.count
      }
      let failures = await coordinator.enqueue(requests)
      for request in requests {
        if let message = failures[request.id] {
          requestDrafts[request.id]?.status = .invalid(message)
        } else {
          requestDrafts[request.id]?.status = .queued
        }
      }
      let queuedIDs = Set(requests.filter { failures[$0.id] == nil }.compactMap {
        requestDrafts[$0.id]?.id
      })
      drafts.removeAll { queuedIDs.contains($0.id) }
      selectedDraftIDs.subtract(queuedIDs)
      selectedDraftID = selectedDraftIDs.first ?? drafts.first?.id
      if selectedDraftIDs.isEmpty, let selectedDraftID { selectedDraftIDs = [selectedDraftID] }
      phase = drafts.isEmpty ? .empty : .configure
      onQueued?()
    }
  }

  func reset() {
    importGeneration += 1
    importTask?.cancel()
    importTask = nil
    drafts = []
    selectedDraftID = nil
    selectedDraftIDs = []
    error = nil
    notice = nil
    phase = .empty
  }

  private func refreshStorytellerConnections() async throws {
    storytellerConnections = try await StorytellerConnectionStore.shared.authenticatedConnections()
    if !storytellerConnections.contains(where: { $0.id == storytellerConnectionID }) {
      storytellerConnectionID = storytellerConnections.first?.id
    }
  }

  private func importDrafts(_ additions: [StudioBookDraft], generation: Int) async {
    var nextIndex = 0
    await withTaskGroup(of: (UUID, Result<ImportPayload, Error>).self) { group in
      func submit(_ draft: StudioBookDraft) {
        let id = draft.id
        let url = draft.sourceURL
        group.addTask {
          do {
            let hashBeforeImport = try BookFileDigest.sha256(url)
            let sizeBeforeImport = try BookFileDigest.size(url)
            let publication = try EPUBImporter().load(url: url)
            let plan = try AudiobookPlanner.plan(publication: publication)
            let hashAfterImport = try BookFileDigest.sha256(url)
            let sizeAfterImport = try BookFileDigest.size(url)
            guard hashBeforeImport == hashAfterImport, sizeBeforeImport == sizeAfterImport else {
              throw BookJobError.io(
                "the EPUB changed while it was being imported; retry with a stable source file")
            }
            let payload = ImportPayload(
              sha256: hashAfterImport, size: sizeAfterImport,
              metadata: plan.metadata, coverData: plan.cover?.data,
              chapterCount: plan.chapters.count,
              sections: plan.sections.map {
                ($0.index, $0.title, $0.role.rawValue, $0.characterCount, $0.included)
              })
            return (id, .success(payload))
          } catch { return (id, .failure(error)) }
        }
      }
      while nextIndex < min(2, additions.count) {
        submit(additions[nextIndex])
        nextIndex += 1
      }
      while let (id, result) = await group.next() {
        guard importGeneration == generation, !Task.isCancelled else { continue }
        if let draft = drafts.first(where: { $0.id == id }) {
          switch result {
          case .success(let payload):
            if let duplicate = drafts.first(where: {
              guard $0.id != draft.id, !$0.sourceSHA256.isEmpty,
                $0.sourceSHA256 == payload.sha256
              else { return false }
              switch $0.status {
              case .invalid, .skipped: return false
              default: return true
              }
            }) {
              draft.status = .skipped("Same edition as \(duplicate.sourceURL.lastPathComponent)")
            } else {
              apply(payload, to: draft)
              do {
                draft.catalogRecord = try await catalogStore.find(sourceSHA256: payload.sha256)
                applyDefaults(to: draft)
                draft.status = .ready
              } catch {
                draft.status = .invalid("Library lookup failed: \(error.localizedDescription)")
              }
            }
          case .failure(let error): draft.status = .invalid(error.localizedDescription)
          }
        }
        if nextIndex < additions.count, importGeneration == generation, !Task.isCancelled {
          submit(additions[nextIndex])
          nextIndex += 1
        }
      }
    }
    guard importGeneration == generation, !Task.isCancelled else { return }
    phase = drafts.isEmpty ? .empty : .configure
    let failures = drafts.count { draft in
      if case .invalid = draft.status { return true }
      return false
    }
    if failures > 0 {
      notice = "\(failures) import\(failures == 1 ? "" : "s") failed. Select a failed book for details."
    }
  }

  private func apply(_ payload: ImportPayload, to draft: StudioBookDraft) {
    draft.sourceSHA256 = payload.sha256
    draft.sourceSize = payload.size
    draft.title = payload.metadata.title
    draft.author = payload.metadata.author ?? ""
    draft.language = payload.metadata.language
    draft.publisher = payload.metadata.publisher
    draft.publicationDate = payload.metadata.date
    draft.identifiers = payload.metadata.identifiers
    draft.coverImage = payload.coverData.flatMap(NSImage.init(data:))
    draft.chapterCount = payload.chapterCount
    draft.sections = payload.sections.map {
      .init(
        id: $0.0, title: $0.1, role: $0.2, characterCount: $0.3,
        initiallyIncluded: $0.4, included: $0.4)
    }
  }

  private func propagateDefaults() {
    guard !isPropagating else { return }
    isPropagating = true
    defer { isPropagating = false }
    drafts.filter(\.usesBatchDefaults).forEach(applyDefaults)
  }

  private func applyDefaults(to draft: StudioBookDraft) {
    draft.voiceID = voiceID
    draft.bitrateKbps = bitrateKbps
    draft.workers = workers
    draft.announceTitles = announceTitles
    draft.paragraphPause = paragraphPause
    draft.chapterPause = chapterPause
    draft.createReadAloud = createReadAloud
    draft.readAloudBitrateKbps = readAloudBitrateKbps
    draft.readAloudASREngineID = readAloudASREngineID
    draft.readAloudASRModelID = readAloudASRModelID
    draft.storytellerConnectionID = storytellerConnectionID
    draft.sendSourceEPUB = sendSourceEPUB
    draft.sendM4B = sendM4B
    draft.sendReadAloud = sendReadAloud
  }

  private func resolveCatalog(for draft: StudioBookDraft) async throws -> BookCatalogRecord {
    let record = try await BookProcessRequestBuilder.resolveCatalog(
      store: catalogStore, sourceURL: draft.sourceURL,
      sourceSHA256: draft.sourceSHA256, sourceSize: draft.sourceSize,
      title: draft.title, author: draft.author.isEmpty ? nil : draft.author,
      language: draft.language, publisher: draft.publisher,
      publicationDate: draft.publicationDate, identifiers: draft.identifiers,
      outputDirectory: draft.outputDirectoryOverride ?? processedDirectory)
    draft.catalogRecord = record
    return record
  }

  private func makeRequest(
    for draft: StudioBookDraft, batchID: UUID, ordinal: Int, count: Int
  ) async throws -> BookJobRequest? {
    let catalog = try await resolveCatalog(for: draft)
    guard let selectedVoice = voices.first(where: { $0.key.voiceID == draft.voiceID }) else {
      throw BookJobError.invalidRequest("selected Siri voice is unavailable")
    }
    let settings = BookProcessSettings(
      voiceID: draft.voiceID,
      voiceModelRevision: selectedVoice.modelRevision,
      voiceRevision: selectedVoice.voiceRevision,
      bitrateKbps: draft.bitrateKbps, workers: draft.workers,
      announceTitles: draft.announceTitles,
      paragraphPauseSeconds: draft.paragraphPause,
      chapterPauseSeconds: draft.chapterPause,
      includedSectionIDs: draft.sections
        .filter { $0.included && !$0.initiallyIncluded }.map { String($0.id) },
      excludedSectionIDs: draft.sections
        .filter { !$0.included && $0.initiallyIncluded }.map { String($0.id) },
      createReadAloud: draft.createReadAloud,
      reprocessAudiobook: draft.reprocessExistingAudiobook,
      readAloudBitrateKbps: draft.readAloudBitrateKbps,
      readAloudASREngineID: draft.readAloudASREngineID,
      readAloudASRModelID: draft.readAloudASRModelID,
      language: draft.language, workDirectory: configuredWorkDirectory)

    var selectedProducts = Set<BookProductKind>()
    if draft.sendSourceEPUB { selectedProducts.insert(.sourceEPUB) }
    if draft.sendM4B { selectedProducts.insert(.m4b) }
    if draft.sendReadAloud, draft.createReadAloud { selectedProducts.insert(.readAloudEPUB) }
    let delivery = try await makeDelivery(
      catalog: catalog, draft: draft, products: selectedProducts)
    do {
      return try BookProcessRequestBuilder.request(
        catalog: catalog, settings: settings, delivery: delivery,
        batchID: batchID, batchOrdinal: ordinal, batchCount: count)
    } catch BookProcessRequestBuilder.PlanError.nothingToDo {
      draft.status = .skipped("Requested local products already exist")
      return nil
    }
  }

  private func makeDelivery(
    catalog: BookCatalogRecord, draft: StudioBookDraft, products: Set<BookProductKind>
  ) async throws -> BookProcessSettings.Delivery? {
    guard !products.isEmpty, let connectionID = draft.storytellerConnectionID,
      let connection = storytellerConnections.first(where: { $0.id == connectionID })
    else { return nil }
    switch try await BookProcessRequestBuilder.resolveDelivery(
      catalog: catalog, catalogStore: catalogStore, connection: connection, products: products)
    {
    case .resolved(let delivery, let updatedCatalog):
      if let updatedCatalog { draft.catalogRecord = updatedCatalog }
      return delivery
    case .review(let candidates):
      draft.warning =
        "Storyteller found \(candidates.count) possible matches. Local products will be created; send this book from Library after reviewing the match."
      return nil
    }
  }
}

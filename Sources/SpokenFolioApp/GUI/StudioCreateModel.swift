import AppKit
import AudiobookKit
import BookJobKit
import EPUBKit
import Foundation
import Observation
import PublicationKit
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
  var outputDirectoryOverride: URL?
  var storytellerConnectionID: UUID?
  var sendSourceEPUB = false
  var sendM4B = false
  var sendReadAloud = false
  var warning: String?

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
  private(set) var voices: [VoiceDescriptor] = []
  private(set) var storytellerConnections: [StorytellerConnection] = []
  private(set) var permissionWarning: String?
  private(set) var error: String?
  private(set) var processedDirectory: URL

  var voiceID = "" { didSet { propagateDefaults() } }
  var bitrateKbps = 256 { didSet { propagateDefaults() } }
  var workers = AudiobookConfig.autoMaxWorkers { didSet { propagateDefaults() } }
  var announceTitles = true { didSet { propagateDefaults() } }
  var paragraphPause = 0.6 { didSet { propagateDefaults() } }
  var chapterPause = 1.75 { didSet { propagateDefaults() } }
  var createReadAloud = false { didSet { propagateDefaults() } }
  var readAloudBitrateKbps = 32 { didSet { propagateDefaults() } }
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

  var hasUnqueuedDrafts: Bool {
    drafts.contains { draft in
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
      let voiceResult = try await Task.detached { () -> ([VoiceDescriptor], VoiceKey, String?) in
        let backend = try SiriTTSBackend(defaultVoice: configuredVoice)
        let warning: String?
        do {
          try SiriPermissionPreflight.verifyModelAccess()
          warning = nil
        } catch {
          warning = "Full Disk Access is required to read Apple's Siri voice models."
        }
        return (backend.voices, backend.defaultVoice, warning)
      }.value
      voices = voiceResult.0
      voiceID = voiceResult.1.voiceID
      permissionWarning = voiceResult.2
      await refreshStorytellerConnections()
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

  func addBooks(_ urls: [URL]) {
    let existing = Set(drafts.map { $0.sourceURL.standardizedFileURL.path })
    let unique = urls.filter { url in
      url.pathExtension.lowercased() == "epub" && !existing.contains(url.standardizedFileURL.path)
    }
    guard !unique.isEmpty else { return }
    let additions = unique.map(StudioBookDraft.init)
    drafts.append(contentsOf: additions)
    if selectedDraftID == nil { selectedDraftID = additions.first?.id }
    phase = .importing
    Task { await importDrafts(additions) }
  }

  func removeDraft(_ id: UUID) {
    drafts.removeAll { $0.id == id }
    if selectedDraftID == id { selectedDraftID = drafts.first?.id }
    if drafts.isEmpty { phase = .empty }
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
      let failures = await coordinator.enqueue(requests)
      for request in requests {
        if let message = failures[request.id] {
          requestDrafts[request.id]?.status = .invalid(message)
        } else {
          requestDrafts[request.id]?.status = .queued
        }
      }
      phase = .queued
      onQueued?()
    }
  }

  func reset() {
    drafts = []
    selectedDraftID = nil
    error = nil
    phase = .empty
  }

  private func refreshStorytellerConnections() async {
    storytellerConnections = await StorytellerConnectionStore.shared.authenticatedConnections()
    if !storytellerConnections.contains(where: { $0.id == storytellerConnectionID }) {
      storytellerConnectionID = storytellerConnections.first?.id
    }
  }

  private func importDrafts(_ additions: [StudioBookDraft]) async {
    var nextIndex = 0
    await withTaskGroup(of: (UUID, Result<ImportPayload, Error>).self) { group in
      func submit(_ draft: StudioBookDraft) {
        let id = draft.id
        let url = draft.sourceURL
        group.addTask {
          do {
            let publication = try EPUBImporter().load(url: url)
            let plan = try AudiobookPlanner.plan(publication: publication)
            let payload = ImportPayload(
              sha256: try BookFileDigest.sha256(url), size: try BookFileDigest.size(url),
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
        if let draft = drafts.first(where: { $0.id == id }) {
          switch result {
          case .success(let payload):
            if let duplicate = drafts.first(where: {
              $0.id != draft.id && !$0.sourceSHA256.isEmpty
                && $0.sourceSHA256 == payload.sha256 && $0.status != .invalid("duplicate")
            }) {
              draft.status = .skipped("Same edition as \(duplicate.sourceURL.lastPathComponent)")
            } else {
              apply(payload, to: draft)
              draft.catalogRecord = try? await catalogStore.find(sourceSHA256: payload.sha256)
              applyDefaults(to: draft)
              draft.status = .ready
            }
          case .failure(let error): draft.status = .invalid(error.localizedDescription)
          }
        }
        if nextIndex < additions.count {
          submit(additions[nextIndex])
          nextIndex += 1
        }
      }
    }
    phase = .configure
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
    draft.storytellerConnectionID = storytellerConnectionID
    draft.sendSourceEPUB = sendSourceEPUB
    draft.sendM4B = sendM4B
    draft.sendReadAloud = sendReadAloud
  }

  private func resolveCatalog(for draft: StudioBookDraft) async throws -> BookCatalogRecord {
    if let existing = try await catalogStore.find(sourceSHA256: draft.sourceSHA256) {
      draft.catalogRecord = existing
      return existing
    }
    let directory = draft.outputDirectoryOverride ?? processedDirectory
    let records = try await catalogStore.scan().records
    let ordinary = ManagedBookLayout(
      directory: directory, title: draft.title, author: draft.author.isEmpty ? nil : draft.author)
    let conflicts = records.contains {
      $0.outputDirectory == ordinary.directory.path && $0.outputBaseName == ordinary.baseName
    } || [ordinary.sourceEPUB, ordinary.audiobook, ordinary.readAloud].contains {
      FileManager.default.fileExists(atPath: $0.path)
    }
    let layout = conflicts
      ? ManagedBookLayout(
        directory: directory, title: draft.title, author: draft.author.isEmpty ? nil : draft.author,
        collisionHash: draft.sourceSHA256)
      : ordinary
    try layout.stageSource(from: draft.sourceURL, expectedSHA256: draft.sourceSHA256)
    let sourceProduct = BookCatalogProduct(
      kind: .sourceEPUB, path: layout.sourceEPUB.path, size: draft.sourceSize,
      sha256: draft.sourceSHA256, verifiedAt: Date())
    let record = BookCatalogRecord(
      source: .init(
        format: "epub", importerVersion: 1, sha256: draft.sourceSHA256,
        size: draft.sourceSize),
      metadata: .init(
        title: draft.title, author: draft.author.isEmpty ? nil : draft.author,
        language: draft.language, publisher: draft.publisher,
        publicationDate: draft.publicationDate, identifiers: draft.identifiers),
      outputDirectory: layout.directory.path, outputBaseName: layout.baseName,
      products: [sourceProduct])
    do { try await catalogStore.create(record) } catch {
      if let raced = try await catalogStore.find(sourceSHA256: draft.sourceSHA256) {
        draft.catalogRecord = raced
        return raced
      }
      throw error
    }
    draft.catalogRecord = record
    return record
  }

  private func makeRequest(
    for draft: StudioBookDraft, batchID: UUID, ordinal: Int, count: Int
  ) async throws -> BookJobRequest? {
    let catalog = try await resolveCatalog(for: draft)
    let layout = catalog.layout
    let selectedVoice = voices.first { $0.key.voiceID == draft.voiceID }
    guard selectedVoice != nil else {
      throw BookJobError.invalidRequest("selected Siri voice is unavailable")
    }
    let includes = draft.sections.filter { $0.included && !$0.initiallyIncluded }.map {
      String($0.id)
    }
    let excludes = draft.sections.filter { !$0.included && $0.initiallyIncluded }.map {
      String($0.id)
    }
    let narration = BookJobRequest.Narration(
      backendID: "siri", modelID: "siri-private",
      modelRevision: selectedVoice?.modelRevision, voiceID: draft.voiceID,
      voiceRevision: selectedVoice?.voiceRevision,
      includedSectionIDs: includes, excludedSectionIDs: excludes,
      bitrateKbps: draft.bitrateKbps, workers: max(1, min(16, draft.workers)),
      paragraphPauseSeconds: draft.paragraphPause,
      chapterPauseSeconds: draft.chapterPause,
      announceTitles: draft.createReadAloud ? false : draft.announceTitles)
    let readAloud = draft.createReadAloud
      ? BookJobRequest.ReadAloud(
        outputPath: layout.readAloud.path, opusBitrateKbps: draft.readAloudBitrateKbps)
      : nil

    let operation: BookJobRequest.Operation
    let alignmentAudio: BookJobRequest.AlignmentAudio?
    if catalog.product(.m4b) != nil, draft.createReadAloud,
      catalog.product(.readAloudEPUB) == nil, let audiobook = catalog.product(.m4b)
    {
      operation = .readAloud
      alignmentAudio = audiobook.narration?.announceTitles == false
        ? .init(
          mode: .existingM4B, path: audiobook.path, size: audiobook.size,
          sha256: audiobook.sha256)
        : .init(mode: .temporaryResynthesis)
    } else if catalog.product(.m4b) == nil {
      operation = .production
      alignmentAudio = nil
    } else {
      operation = .storytellerDelivery
      alignmentAudio = nil
    }

    var selectedProducts = Set<BookProductKind>()
    if draft.sendSourceEPUB { selectedProducts.insert(.sourceEPUB) }
    if draft.sendM4B { selectedProducts.insert(.m4b) }
    if draft.sendReadAloud, draft.createReadAloud { selectedProducts.insert(.readAloudEPUB) }
    let delivery = try await makeDelivery(
      catalog: catalog, draft: draft, products: selectedProducts)
    if operation == .storytellerDelivery, delivery == nil {
      draft.status = .skipped("Requested local products already exist")
      return nil
    }
    return BookJobRequest(
      catalogID: catalog.id, batchID: batchID, batchOrdinal: ordinal, batchCount: count,
      managedByStudio: true, title: draft.title,
      author: draft.author.isEmpty ? nil : draft.author,
      source: .init(
        path: layout.sourceEPUB.path, sha256: draft.sourceSHA256, format: "epub",
        importerVersion: 1, identifiers: draft.identifiers.map(\.value),
        typedIdentifiers: draft.identifiers),
      narration: narration, m4bOutputPath: layout.audiobook.path,
      m4bWorkDirectory: configuredWorkDirectory, allowOverwrite: false,
      readAloud: readAloud ?? catalog.product(.readAloudEPUB).map {
        .init(outputPath: $0.path, opusBitrateKbps: $0.readAloud?.opusBitrateKbps ?? 32)
      },
      alignmentAudio: alignmentAudio, storyteller: delivery, operation: operation)
  }

  private func makeDelivery(
    catalog: BookCatalogRecord, draft: StudioBookDraft, products: Set<BookProductKind>
  ) async throws -> BookJobRequest.StorytellerDelivery? {
    guard !products.isEmpty, let connectionID = draft.storytellerConnectionID,
      let connection = storytellerConnections.first(where: { $0.id == connectionID })
    else { return nil }
    let token = try StorytellerConnectionStore.shared.token(connectionID)
    let client = try StorytellerClient(origin: connection.origin, tokenProvider: { token })
    let existingLink = catalog.remoteLinks.first {
      $0.providerID == "storyteller" && $0.connectionID == connectionID
    }
    let localProducts = catalog.products.compactMap { product -> StorytellerLocalProductIdentity? in
      let format: StorytellerFormat = switch product.kind {
      case .sourceEPUB: .ebook
      case .m4b: .audiobook
      case .readAloudEPUB: .readaloud
      }
      return .init(format: format, size: product.size, sha256: product.sha256)
    }
    let excluded = Set(existingLink?.excludedRemoteBookIDs.compactMap(UUID.init(uuidString:)) ?? [])
    let resolution = try await StorytellerIdentityResolver(client: client).resolve(
      local: .init(
        title: catalog.metadata.title, author: catalog.metadata.author,
        identifiers: catalog.metadata.identifiers, products: localProducts,
        excludedBookIDs: excluded),
      linkedBookID: existingLink.flatMap { UUID(uuidString: $0.remoteBookID) })
    let remoteID: UUID
    switch resolution {
    case .linked(let id): remoteID = id
    case .automatic(let id, let evidence):
      remoteID = id
      var updated = catalog
      updated.upsertRemoteLink(
        .init(
          providerID: "storyteller", connectionID: connectionID,
          remoteBookID: id.uuidString.lowercased(),
          evidence: evidence == .exactAssetHash ? .exactAssetHash : .validatedIdentifier))
      try await catalogStore.update(updated, expectedRevision: catalog.revision)
      draft.catalogRecord = updated
    case .create: remoteID = DeterministicBookID.make(catalogID: catalog.id)
    case .review(let candidates):
      draft.warning =
        "Storyteller found \(candidates.count) possible matches. Local products will be created; send this book from Library after reviewing the match."
      return nil
    }
    return .init(connectionID: connectionID, remoteBookID: remoteID, products: products)
  }
}

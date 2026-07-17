import AppKit
import AudiobookKit
import BookJobKit
import EPUBKit
import Foundation
import LibraryKit
import Observation
import StorytellerKit
import SwiftUI
import TTSKit

/// One goal-oriented flow for everything the Library can do to a book:
/// create the audiobook, create or recreate the ReadAloud (with explicit
/// Apple-vs-Whisper choice), and send products to Storyteller — including
/// downloading the EPUB from Storyteller first when no local copy exists.
/// Queues durable jobs directly; never bounces through the Create page.
@MainActor @Observable
final class LibraryProcessModel: Identifiable {
  enum Intent {
    /// Fill the local gaps (default entry point).
    case process
    /// Only the delivery step, for sending already-processed products later.
    case sendOnly
    /// The ReadAloud step, preset for creating or recreating.
    case readAloud
  }

  struct Book: Identifiable {
    enum Source {
      case cataloged(BookCatalogRecord)
      case download(LibraryRemoteBookSnapshot)
    }
    let id: String
    let title: String
    let author: String?
    let source: Source
    let hasAudiobook: Bool
    let hasReadAloud: Bool
    let audiobookNarration: BookJobRequest.Narration?
    let audiobookAlignsDirectly: Bool
    let row: StudioLibraryRow
  }

  enum Phase: Equatable {
    case configuring
    case working(String)
    case queued(Int)
  }

  let id = UUID()
  let books: [Book]
  let skipped: [(title: String, reason: String)]
  let connections: [StorytellerConnection]
  let intent: Intent

  // Step toggles. "Missing" toggles apply to books lacking the product;
  // "recreate" toggles apply digest-guarded replacement to books having it.
  var createMissingAudiobooks: Bool
  var recreateExistingAudiobooks = false
  var createMissingReadAlouds: Bool
  var recreateExistingReadAlouds = false
  var sendToStoryteller: Bool
  var deliveryConnectionID: UUID?
  var sendEPUB = true
  var sendM4B = true
  var sendReadAloud = true

  // Shared synthesis settings (defaults from AppConfig, like the Create page).
  var voiceID = ""
  var bitrateKbps = 256
  var workers = AudiobookConfig.autoMaxWorkers
  var announceTitles = true
  var paragraphPause = 0.6
  var chapterPause = 1.75
  var readAloudBitrateKbps = 32
  var readAloudASREngineID = "apple"
  var readAloudASRModelID = "large-v3-turbo"

  private(set) var voices: [VoiceDescriptor] = []
  private(set) var permissionWarning: String?
  private(set) var phase: Phase = .configuring
  private(set) var bookFailures: [(title: String, reason: String)] = []
  private(set) var error: String?

  // Manual edition review (single book): candidates offered by the resolver.
  private(set) var reviewCandidates: [StorytellerMatchCandidate] = []
  var selectedCandidateID: UUID?

  var onViewQueue: (() -> Void)?

  @ObservationIgnored private let coordinator: StudioJobCoordinator
  @ObservationIgnored private let catalogStore: BookCatalogStore
  @ObservationIgnored private let processedDirectory: URL
  @ObservationIgnored private var configuredWorkDirectory: String?
  @ObservationIgnored private var didLoadDefaults = false
  @ObservationIgnored private var confirmedRemoteBookID: UUID?

  init(
    rows: [StudioLibraryRow], intent: Intent,
    connections: [StorytellerConnection], preferredConnectionID: UUID?,
    coordinator: StudioJobCoordinator,
    catalogStore: BookCatalogStore = BookCatalogStore(root: AppPaths.bookCatalogRoot),
    processedDirectory: URL
  ) {
    self.intent = intent
    self.connections = connections
    self.coordinator = coordinator
    self.catalogStore = catalogStore
    self.processedDirectory = processedDirectory
    deliveryConnectionID = preferredConnectionID ?? connections.first?.id

    var books: [Book] = []
    var skipped: [(String, String)] = []
    for row in rows {
      if let record = row.record {
        let audiobook = record.product(.m4b)
        books.append(
          Book(
            id: row.id, title: row.title, author: row.author,
            source: .cataloged(record),
            hasAudiobook: audiobook != nil,
            hasReadAloud: record.product(.readAloudEPUB) != nil,
            audiobookNarration: audiobook?.narration,
            audiobookAlignsDirectly: audiobook?.narration?.announceTitles == false,
            row: row))
      } else if let remote = row.remote, remote.asset(.ebook)?.state == .ready {
        books.append(
          Book(
            id: row.id, title: row.title, author: row.author,
            source: .download(remote),
            hasAudiobook: false, hasReadAloud: false,
            audiobookNarration: nil, audiobookAlignsDirectly: false, row: row))
      } else {
        skipped.append((row.title, "No local EPUB, and Storyteller has no ready ebook to download."))
      }
    }
    self.books = books
    self.skipped = skipped

    let anyMissingAudiobook = books.contains { !$0.hasAudiobook }
    let anyMissingReadAloud = books.contains { !$0.hasReadAloud }
    let allHaveReadAloud = !books.isEmpty && books.allSatisfy(\.hasReadAloud)
    switch intent {
    case .process:
      createMissingAudiobooks = anyMissingAudiobook
      createMissingReadAlouds = anyMissingReadAloud
      sendToStoryteller = false
    case .sendOnly:
      createMissingAudiobooks = false
      createMissingReadAlouds = false
      sendToStoryteller = true
    case .readAloud:
      createMissingAudiobooks = false
      createMissingReadAlouds = anyMissingReadAloud
      recreateExistingReadAlouds = allHaveReadAloud
      sendToStoryteller = false
    }
  }

  var singleBook: Book? { books.count == 1 ? books.first : nil }

  var downloadCount: Int {
    books.count { if case .download = $0.source { return true }; return false }
  }

  /// Whether the chosen steps will synthesize any new audio (which needs the
  /// voice inventory and the audiobook settings to be meaningful).
  var willSynthesize: Bool {
    books.contains { book in
      let wantsReadAloud = (createMissingReadAlouds && !book.hasReadAloud)
        || (recreateExistingReadAlouds && book.hasReadAloud)
      if !book.hasAudiobook {
        return (createMissingAudiobooks || wantsReadAloud)
      }
      if recreateExistingAudiobooks { return true }
      return wantsReadAloud && !book.audiobookAlignsDirectly
    }
  }

  var willCreateReadAlouds: Bool {
    books.contains { book in
      (createMissingReadAlouds && !book.hasReadAloud)
        || (recreateExistingReadAlouds && book.hasReadAloud)
    }
  }

  /// Best-case completeness after the selected steps, for the single-book
  /// header ("Level 3 → up to 5"). Jobs verify their products, so a full
  /// local package predicts verified coherence.
  var predictedLevel: LibraryLevel? {
    guard let book = singleBook else { return nil }
    let localAudiobook = book.hasAudiobook || createMissingAudiobooks || willCreateReadAlouds
    let localReadAloud = book.hasReadAloud || willCreateReadAlouds
    let remote = book.row.remote
    let sendsAll = sendToStoryteller && sendEPUB && sendM4B && sendReadAloud
    let state = LibraryPackageState(
      localEPUBReady: true,
      localAudiobookReady: localAudiobook,
      localReadAloudReady: localReadAloud,
      localCoherence: localAudiobook && localReadAloud ? .verified : .unknown,
      remoteEPUBReady: remote?.asset(.ebook)?.state == .ready || sendsAll,
      remoteAudiobookReady: remote?.asset(.audiobook)?.state == .ready || sendsAll,
      remoteReadAloudReady: remote?.asset(.readaloud)?.state == .ready
        || (sendToStoryteller && sendReadAloud && localReadAloud),
      remoteCoherence: sendsAll ? .verified : .unknown,
      remoteNarration: sendsAll ? .spokenFolioTTS : book.row.narration)
    return state.level
  }

  var summary: String {
    guard case .configuring = phase else { return "" }
    var parts: [String] = []
    let audiobookCount = books.count {
      (!$0.hasAudiobook && (createMissingAudiobooks || willCreateReadAlouds))
        || ($0.hasAudiobook && recreateExistingAudiobooks)
    }
    if audiobookCount > 0 { parts.append("\(audiobookCount) audiobook\(audiobookCount == 1 ? "" : "s")") }
    let readAloudCount = books.count {
      (createMissingReadAlouds && !$0.hasReadAloud)
        || (recreateExistingReadAlouds && $0.hasReadAloud)
    }
    if readAloudCount > 0 { parts.append("\(readAloudCount) ReadAloud\(readAloudCount == 1 ? "" : "s")") }
    if downloadCount > 0, audiobookCount + readAloudCount > 0 {
      parts.append("\(downloadCount) download\(downloadCount == 1 ? "" : "s")")
    }
    if sendToStoryteller,
      let connection = connections.first(where: { $0.id == deliveryConnectionID })
    {
      parts.append("delivery to \(connection.displayName)")
    }
    guard !parts.isEmpty else { return "Nothing selected yet." }
    return "Queues \(books.count) job\(books.count == 1 ? "" : "s"): " + parts.joined(separator: " + ")
  }

  func loadDefaults() async {
    guard !didLoadDefaults else { return }
    didLoadDefaults = true
    do {
      let appConfig = try AppConfig.load()
      configuredWorkDirectory = appConfig.audiobook.workDirectory
      bitrateKbps = appConfig.audiobook.defaultBitrateKbps
      workers = appConfig.audiobook.resolvedMaxWorkers
      announceTitles = appConfig.audiobook.announceTitles
      paragraphPause = appConfig.audiobook.paragraphPauseSeconds
      chapterPause = appConfig.audiobook.chapterPauseSeconds
      let inventory = try await SiriVoiceInventory.load(
        configuredVoice: appConfig.audiobook.defaultVoice ?? appConfig.server.defaultVoice)
      voices = inventory.voices
      voiceID = inventory.defaultVoiceID
      permissionWarning = inventory.permissionWarning
    } catch { self.error = error.localizedDescription }
  }

  func confirmCandidate() {
    guard let selectedCandidateID else { return }
    confirmedRemoteBookID = selectedCandidateID
    reviewCandidates = []
    queue()
  }

  func queue() {
    guard case .configuring = phase else { return }
    error = nil
    bookFailures = []
    phase = .working("Preparing…")
    Task { await performQueue() }
  }

  private func performQueue() async {
    var requests: [BookJobRequest] = []
    var failures: [(String, String)] = []
    var requestTitles: [UUID: String] = [:]
    let batchID = books.count > 1 ? UUID() : nil
    defer {
      bookFailures = failures
      if case .working = phase { phase = .configuring }
    }

    let deliveryConnection = sendToStoryteller
      ? connections.first(where: { $0.id == deliveryConnectionID })
      : nil
    if sendToStoryteller, deliveryConnection == nil {
      error = "Select a Storyteller connection for delivery."
      return
    }

    for book in books {
      do {
        phase = .working("Preparing \(book.title)…")
        let catalog = try await resolveSource(for: book)
        let settings = makeSettings(for: book)
        var delivery: BookProcessSettings.Delivery?
        var workingCatalog = catalog
        if let connection = deliveryConnection {
          var products = Set<BookProductKind>()
          if sendEPUB { products.insert(.sourceEPUB) }
          if sendM4B, book.hasAudiobook || settings.createReadAloud || createMissingAudiobooks {
            products.insert(.m4b)
          }
          if sendReadAloud, book.hasReadAloud || settings.createReadAloud {
            products.insert(.readAloudEPUB)
          }
          if products.isEmpty {
            failures.append((book.title, "No products selected for delivery."))
            continue
          }
          if let confirmedRemoteBookID, books.count == 1 {
            delivery = .init(
              connectionID: connection.id, remoteBookID: confirmedRemoteBookID,
              products: products)
            try await persistConfirmedLink(
              catalog: workingCatalog, connectionID: connection.id,
              remoteBookID: confirmedRemoteBookID)
          } else {
            phase = .working("Matching \(book.title) on \(connection.displayName)…")
            switch try await BookProcessRequestBuilder.resolveDelivery(
              catalog: workingCatalog, catalogStore: catalogStore,
              connection: connection, products: products)
            {
            case .resolved(let value, let updated):
              delivery = value
              if let updated { workingCatalog = updated }
            case .review(let candidates):
              if books.count == 1 {
                reviewCandidates = candidates
                phase = .configuring
                return
              }
              failures.append(
                (book.title, "Storyteller has similar editions; review the match individually."))
              continue
            }
          }
        }

        let narrationOverride = !bookNeedsSynthesis(book) ? book.audiobookNarration : nil
        let request = try BookProcessRequestBuilder.request(
          catalog: workingCatalog, settings: settings, delivery: delivery,
          narrationOverride: narrationOverride, batchID: batchID)
        requestTitles[request.id] = book.title
        requests.append(request)
      } catch {
        failures.append((book.title, error.localizedDescription))
      }
    }

    guard !requests.isEmpty else {
      if failures.isEmpty { error = "Nothing to queue." }
      return
    }
    for index in requests.indices {
      requests[index].batchOrdinal = batchID == nil ? nil : index
      requests[index].batchCount = batchID == nil ? nil : requests.count
    }
    phase = .working("Adding to the durable queue…")
    let enqueueFailures = await coordinator.enqueue(requests)
    for request in requests {
      if let message = enqueueFailures[request.id] {
        failures.append((requestTitles[request.id] ?? "Book", message))
      }
    }
    let queued = requests.count { enqueueFailures[$0.id] == nil }
    if queued > 0 {
      phase = .queued(queued)
      bookFailures = failures
    }
  }

  private func bookNeedsSynthesis(_ book: Book) -> Bool {
    let wantsReadAloud = (createMissingReadAlouds && !book.hasReadAloud)
      || (recreateExistingReadAlouds && book.hasReadAloud)
    if !book.hasAudiobook { return createMissingAudiobooks || wantsReadAloud }
    if recreateExistingAudiobooks { return true }
    return wantsReadAloud && !book.audiobookAlignsDirectly
  }

  private func makeSettings(for book: Book) -> BookProcessSettings {
    let selectedVoice = voices.first { $0.key.voiceID == voiceID }
    let wantsReadAloud = (createMissingReadAlouds && !book.hasReadAloud)
      || (recreateExistingReadAlouds && book.hasReadAloud)
    return BookProcessSettings(
      voiceID: voiceID,
      voiceModelRevision: selectedVoice?.modelRevision,
      voiceRevision: selectedVoice?.voiceRevision,
      bitrateKbps: bitrateKbps, workers: workers, announceTitles: announceTitles,
      paragraphPauseSeconds: paragraphPause, chapterPauseSeconds: chapterPause,
      createReadAloud: wantsReadAloud,
      recreateReadAloud: recreateExistingReadAlouds && book.hasReadAloud,
      reprocessAudiobook: recreateExistingAudiobooks && book.hasAudiobook,
      readAloudBitrateKbps: readAloudBitrateKbps,
      readAloudASREngineID: readAloudASREngineID,
      readAloudASRModelID: readAloudASRModelID,
      language: nil, workDirectory: configuredWorkDirectory)
  }

  private func resolveSource(for book: Book) async throws -> BookCatalogRecord {
    switch book.source {
    case .cataloged(let record):
      return record
    case .download(let remote):
      guard let connection = connections.first(where: { $0.id == remote.connectionID }) else {
        throw BookJobError.invalidRequest("the Storyteller connection for this book is gone")
      }
      guard connection.permissions.bookDownload else {
        throw BookJobError.invalidRequest(
          "the \(connection.displayName) account cannot download ebook sources")
      }
      phase = .working("Downloading \(book.title)…")
      let token = try await StorytellerConnectionStore.shared.token(connection.id)
      let client = try StorytellerClient(origin: connection.origin, tokenProvider: { token })
      let staging = FileManager.default.temporaryDirectory
        .appendingPathComponent("spokenfolio-download-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: staging) }
      let downloaded = staging.appendingPathComponent("source.epub")
      try await client.downloadEbook(bookID: remote.remoteBookID, to: downloaded)

      phase = .working("Importing \(book.title)…")
      let imported = try await Task.detached {
        let sha256 = try BookFileDigest.sha256(downloaded)
        let size = try BookFileDigest.size(downloaded)
        let publication = try EPUBImporter().load(url: downloaded)
        let plan = try AudiobookPlanner.plan(publication: publication)
        return (sha256, size, plan.metadata)
      }.value
      return try await BookProcessRequestBuilder.resolveCatalog(
        store: catalogStore, sourceURL: downloaded,
        sourceSHA256: imported.0, sourceSize: imported.1,
        title: imported.2.title, author: imported.2.author,
        language: imported.2.language, publisher: imported.2.publisher,
        publicationDate: imported.2.date, identifiers: imported.2.identifiers,
        outputDirectory: processedDirectory)
    }
  }

  private func persistConfirmedLink(
    catalog: BookCatalogRecord, connectionID: UUID, remoteBookID: UUID
  ) async throws {
    var updated = catalog
    let previous = updated.remoteLinks.first {
      $0.providerID == "storyteller" && $0.connectionID == connectionID
    }
    updated.upsertRemoteLink(
      .init(
        providerID: "storyteller", connectionID: connectionID,
        remoteBookID: remoteBookID.uuidString.lowercased(),
        evidence: .userConfirmed,
        linkedAt: previous?.linkedAt ?? Date(),
        lastObservedAt: previous?.lastObservedAt,
        remoteTitle: previous?.remoteTitle,
        remoteAuthors: previous?.remoteAuthors ?? [],
        receipts: previous?.receipts ?? [],
        excludedRemoteBookIDs: previous?.excludedRemoteBookIDs ?? []))
    if updated != catalog {
      try await catalogStore.update(updated, expectedRevision: catalog.revision)
    }
  }
}

struct LibraryProcessSheet: View {
  @Bindable var model: LibraryProcessModel
  @Environment(\.dismiss) private var dismiss

  private var isWorking: Bool {
    if case .working = model.phase { return true }
    return false
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
        .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 12)
      Divider()
      if case .queued(let count) = model.phase {
        queuedConfirmation(count)
      } else {
        Form {
          skippedSection
          sourceSection
          audiobookSection
          readAloudSection
          deliverySection
          failureSection
        }
        .formStyle(.grouped)
        Divider()
        footer
          .padding(.horizontal, 20).padding(.vertical, 14)
      }
    }
    .frame(minWidth: 560, idealWidth: 640, minHeight: 460, idealHeight: 640)
    .task { await model.loadDefaults() }
  }

  @ViewBuilder private var header: some View {
    if let book = model.singleBook {
      VStack(alignment: .leading, spacing: 3) {
        Text(book.title).font(.title2.bold())
        if let author = book.author, !author.isEmpty {
          Text(author).foregroundStyle(.secondary)
        }
        HStack(spacing: 10) {
          Text("Level \(book.row.level.rawValue) · \(book.row.level.label)")
            .font(.callout.weight(.medium))
          if let predicted = model.predictedLevel, predicted.rawValue > book.row.level.rawValue {
            Label("up to Level \(predicted.rawValue) · \(predicted.label)", systemImage: "arrow.up.right")
              .font(.callout).foregroundStyle(.secondary)
          }
        }
      }
    } else {
      VStack(alignment: .leading, spacing: 3) {
        Text("Process \(model.books.count) Books").font(.title2.bold())
        Text(
          "\(model.books.count { !$0.hasAudiobook }) without an audiobook · \(model.books.count { !$0.hasReadAloud }) without a ReadAloud")
          .font(.callout).foregroundStyle(.secondary)
      }
    }
  }

  @ViewBuilder private var skippedSection: some View {
    if !model.skipped.isEmpty {
      Section {
        ForEach(Array(model.skipped.enumerated()), id: \.offset) { _, entry in
          Label {
            Text("\(entry.title): \(entry.reason)")
          } icon: {
            Image(systemName: "minus.circle").foregroundStyle(.secondary)
          }
          .font(.callout)
        }
      } header: {
        Text("Skipped")
      }
    }
  }

  @ViewBuilder private var sourceSection: some View {
    Section("Source") {
      if let book = model.singleBook {
        switch book.source {
        case .cataloged:
          Label("Local EPUB, cataloged", systemImage: "checkmark.circle.fill")
        case .download(let remote):
          Label {
            VStack(alignment: .leading, spacing: 2) {
              Text("Download EPUB from Storyteller")
              if let size = remote.asset(.ebook)?.fileSize {
                Text(ByteCountFormatter.string(
                  fromByteCount: Int64(clamping: size), countStyle: .file))
                  .font(.caption).foregroundStyle(.secondary)
              }
            }
          } icon: {
            Image(systemName: "arrow.down.circle")
          }
        }
      } else {
        let downloads = model.downloadCount
        Label(
          downloads == 0
            ? "All \(model.books.count) books have a cataloged local EPUB."
            : "\(model.books.count - downloads) cataloged locally · \(downloads) will download from Storyteller.",
          systemImage: downloads == 0 ? "checkmark.circle.fill" : "arrow.down.circle")
      }
    }
  }

  @ViewBuilder private var audiobookSection: some View {
    let missing = model.books.count { !$0.hasAudiobook }
    let existing = model.books.count - missing
    Section("Audiobook (M4B)") {
      if missing > 0 {
        Toggle(
          model.singleBook != nil
            ? "Create audiobook" : "Create for \(missing) book\(missing == 1 ? "" : "s") without one",
          isOn: $model.createMissingAudiobooks)
      }
      if existing > 0 {
        Toggle(
          model.singleBook != nil
            ? "Recreate existing audiobook (replaces the current file)"
            : "Recreate \(existing) existing audiobook\(existing == 1 ? "" : "s")",
          isOn: $model.recreateExistingAudiobooks)
      }
      if model.singleBook != nil, existing > 0, !model.recreateExistingAudiobooks {
        Label("Already created", systemImage: "checkmark.circle.fill")
          .font(.callout).foregroundStyle(.secondary)
      }
      if model.willSynthesize {
        if let warning = model.permissionWarning {
          Label(warning, systemImage: "exclamationmark.triangle.fill")
            .font(.callout).foregroundStyle(.orange)
        }
        AudiobookSettingsFields(
          voices: model.voices, voiceID: $model.voiceID,
          bitrateKbps: $model.bitrateKbps, workers: $model.workers,
          announceTitles: $model.announceTitles,
          paragraphPause: $model.paragraphPause, chapterPause: $model.chapterPause,
          announceTitlesLocked: model.willCreateReadAlouds)
      }
    }
  }

  @ViewBuilder private var readAloudSection: some View {
    let missing = model.books.count { !$0.hasReadAloud }
    let existing = model.books.count - missing
    Section("ReadAloud EPUB") {
      if missing > 0 {
        Toggle(
          model.singleBook != nil
            ? "Create synchronized ReadAloud"
            : "Create for \(missing) book\(missing == 1 ? "" : "s") without one",
          isOn: $model.createMissingReadAlouds)
      }
      if existing > 0 {
        Toggle(
          model.singleBook != nil
            ? "Recreate with the settings below (replaces the current file)"
            : "Recreate \(existing) existing ReadAloud\(existing == 1 ? "" : "s")",
          isOn: $model.recreateExistingReadAlouds)
      }
      if model.willCreateReadAlouds {
        ReadAloudSettingsFields(
          opusBitrateKbps: $model.readAloudBitrateKbps,
          asrEngineID: $model.readAloudASREngineID,
          asrModelID: $model.readAloudASRModelID)
        if let book = model.singleBook, book.hasAudiobook {
          Label(
            book.audiobookAlignsDirectly
              ? "Aligns against the existing audiobook."
              : "The existing audiobook announced chapter titles, so alignment audio is resynthesized temporarily.",
            systemImage: book.audiobookAlignsDirectly ? "waveform.badge.checkmark" : "waveform.badge.exclamationmark")
            .font(.callout).foregroundStyle(.secondary)
        }
      }
    }
  }

  @ViewBuilder private var deliverySection: some View {
    Section("Send to Storyteller") {
      if model.connections.isEmpty {
        Text("No Storyteller connection. Add one in Settings → Storyteller.")
          .foregroundStyle(.secondary)
      } else {
        Toggle("Send finished products to Storyteller", isOn: $model.sendToStoryteller)
        if model.sendToStoryteller {
          Picker("Connection", selection: $model.deliveryConnectionID) {
            ForEach(model.connections) { connection in
              Text("\(connection.displayName) — \(connection.username)")
                .tag(Optional(connection.id))
            }
          }
          Toggle("Source EPUB", isOn: $model.sendEPUB)
          Toggle("M4B audiobook", isOn: $model.sendM4B)
          Toggle("ReadAloud EPUB", isOn: $model.sendReadAloud)
          if !model.reviewCandidates.isEmpty {
            Text("Storyteller has similar editions. Confirm the match before anything uploads:")
              .font(.callout)
            StorytellerCandidateList(
              candidates: model.reviewCandidates,
              selectedCandidateID: $model.selectedCandidateID)
            Button("Use Selected Edition") { model.confirmCandidate() }
              .disabled(model.selectedCandidateID == nil)
          }
        }
      }
    }
  }

  @ViewBuilder private var failureSection: some View {
    if !model.bookFailures.isEmpty {
      Section("Not Queued") {
        ForEach(Array(model.bookFailures.enumerated()), id: \.offset) { _, failure in
          Label {
            Text("\(failure.title): \(failure.reason)").textSelection(.enabled)
          } icon: {
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
          }
          .font(.callout)
        }
      }
    }
    if let error = model.error {
      Section {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.red).textSelection(.enabled)
      }
    }
  }

  private var footer: some View {
    HStack(spacing: 12) {
      Button("Cancel") { dismiss() }
        .keyboardShortcut(.cancelAction)
      if case .working(let message) = model.phase {
        ProgressView().controlSize(.small)
        Text(message).font(.callout).foregroundStyle(.secondary).lineLimit(1)
      } else {
        Text(model.summary).font(.callout).foregroundStyle(.secondary).lineLimit(2)
      }
      Spacer()
      Button("Add to Queue") { model.queue() }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
        .disabled(isWorking || model.books.isEmpty)
    }
  }

  private func queuedConfirmation(_ count: Int) -> some View {
    VStack(spacing: 14) {
      ContentUnavailableView {
        Label("\(count) Job\(count == 1 ? "" : "s") Queued", systemImage: "checkmark.circle.fill")
      } description: {
        Text(
          model.bookFailures.isEmpty
            ? "The durable production queue processes books in order."
            : "\(model.bookFailures.count) book\(model.bookFailures.count == 1 ? " was" : "s were") not queued — details below.")
      } actions: {
        Button("View Queue") {
          dismiss()
          model.onViewQueue?()
        }
        .buttonStyle(.borderedProminent)
        Button("Done") { dismiss() }
      }
      if !model.bookFailures.isEmpty {
        ScrollView {
          VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(model.bookFailures.enumerated()), id: \.offset) { _, failure in
              Label("\(failure.title): \(failure.reason)", systemImage: "xmark.octagon")
                .font(.callout).foregroundStyle(.secondary)
            }
          }
          .padding(.horizontal, 20)
        }
        .frame(maxHeight: 140)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

/// Candidate rows for manual Storyteller edition review, shared with the
/// Match Edition sheet.
struct StorytellerCandidateList: View {
  let candidates: [StorytellerMatchCandidate]
  @Binding var selectedCandidateID: UUID?

  var body: some View {
    ScrollView {
      LazyVStack(spacing: 6) {
        ForEach(candidates) { candidate in
          Button {
            selectedCandidateID = candidate.id
          } label: {
            HStack(alignment: .top, spacing: 10) {
              Image(
                systemName: selectedCandidateID == candidate.id
                  ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(
                  selectedCandidateID == candidate.id ? Color.accentColor : .secondary)
              VStack(alignment: .leading, spacing: 3) {
                Text(candidate.book.title).font(.headline).foregroundStyle(.primary)
                Text(candidate.book.authors.map(\.name).joined(separator: ", "))
                  .font(.caption).foregroundStyle(.secondary)
                if !candidate.reasons.isEmpty {
                  Text(candidate.reasons.map(reasonLabel).sorted().joined(separator: " • "))
                    .font(.caption2).foregroundStyle(.secondary)
                }
                let identifiers = candidate.book.identifiers.compactMap(\.effectiveValue)
                if !identifiers.isEmpty {
                  Text(identifiers.joined(separator: " • "))
                    .font(.caption2.monospaced()).foregroundStyle(.tertiary)
                }
              }
              Spacer()
            }
            .padding(9)
            .contentShape(Rectangle())
            .background(
              selectedCandidateID == candidate.id
                ? Color.accentColor.opacity(0.13) : Color.secondary.opacity(0.07),
              in: RoundedRectangle(cornerRadius: 8))
          }
          .buttonStyle(.plain)
        }
      }
    }
    .frame(idealHeight: 200, maxHeight: 260)
  }

  private func reasonLabel(_ reason: StorytellerMatchCandidate.Reason) -> String {
    switch reason {
    case .exactHash: "Exact file hash"
    case .identifier: "Matching identifier"
    case .exactMetadata: "Exact title and author"
    case .similarMetadata: "Similar title and author"
    }
  }
}

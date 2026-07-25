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

  /// A processable row: the planner's book (the queueing authority) plus the
  /// source row for presentation-only facts (level, remote snapshot, narration).
  struct Book: Identifiable {
    let planner: LibraryProcessPlanner.Book
    let row: StudioLibraryRow

    var id: String { planner.id }
    var title: String { planner.title }
    var author: String? { planner.author }
    var source: LibraryProcessPlanner.Book.Source { planner.source }
    var hasAudiobook: Bool { planner.hasAudiobook }
    var hasReadAloud: Bool { planner.hasReadAloud }
    var audiobookAlignsDirectly: Bool { planner.audiobookAlignsDirectly }
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
  // Storyteller replacement safety: when a delivery targets occupied remote
  // slots with different content, the loss manifest must be acknowledged
  // before anything queues.
  var replaceAcknowledged = false
  /// Declared provenance of the delivered ReadAloud ("spokenFolioTTS" | "human").
  var sentNarration = "spokenFolioTTS"

  // Shared synthesis settings (defaults from AppConfig, like the Create page).
  var voiceID = ""
  var bitrateKbps = 256
  var workers = AudiobookConfig.autoMaxWorkers
  var announceTitles = true
  var paragraphPause = 0.6
  var chapterPause = 1.75
  var readAloudBitrateKbps = 32
  var readAloudASREngineID = "synthesis"
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

    let plan = LibraryProcessPlanner.plan(rows: rows)
    let rowsByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
    books = plan.books.compactMap { book in
      rowsByID[book.id].map { Book(planner: book, row: $0) }
    }
    skipped = plan.skipped

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

  /// The current switches as the planner sees them, minus the acknowledgment
  /// fields (those are derived from the impacts below, so deriving them here
  /// would recurse). One authority for preview and queueing.
  private var baseToggles: LibraryProcessPlanner.Toggles {
    .init(
      createMissingAudiobooks: createMissingAudiobooks,
      recreateExistingAudiobooks: recreateExistingAudiobooks,
      createMissingReadAlouds: createMissingReadAlouds,
      recreateExistingReadAlouds: recreateExistingReadAlouds,
      sendToStoryteller: sendToStoryteller,
      deliveryConnectionID: deliveryConnectionID,
      sendEPUB: sendEPUB, sendM4B: sendM4B, sendReadAloud: sendReadAloud,
      confirmedRemoteBookID: confirmedRemoteBookID)
  }

  /// Loss manifests for books whose Storyteller delivery target holds content
  /// that is not provably identical. Pure and cheap, so it simply recomputes
  /// whenever any send/create toggle or the connection changes.
  var replacementImpacts: [LibraryProcessPlanner.ReplacementImpact] {
    books.compactMap {
      LibraryProcessPlanner.replacementImpact(book: $0.planner, toggles: baseToggles)
    }
  }

  /// Whether any queued delivery carries the ReadAloud product — the artifact
  /// the sent-narration assertion describes.
  var sendsReadAloudProduct: Bool {
    books.contains {
      LibraryProcessPlanner.plannedProducts(book: $0.planner, toggles: baseToggles)
        .contains(.readAloudEPUB)
    }
  }

  /// True while loss manifests exist and remain unacknowledged; the Queue
  /// button stays disabled until the user checks the acknowledgment.
  var needsReplaceAcknowledgment: Bool {
    !replacementImpacts.isEmpty && !replaceAcknowledged
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

  /// Delegates to the shared planner — the same engine the web API uses — so
  /// source resolution, delivery matching, the replacement guard, and the
  /// narration assertion can never diverge between interfaces.
  private func performQueue() async {
    defer { if case .working = phase { phase = .configuring } }

    // The acknowledgment covers exactly the manifests currently on screen;
    // execute re-derives each book's impact and refuses anything unlisted.
    var toggles = baseToggles
    toggles.replaceAcknowledgedRowIDs =
      replaceAcknowledged ? Set(replacementImpacts.map(\.rowID)) : []
    toggles.assertNarration = sendsReadAloudProduct ? sentNarration : nil

    do {
      let outcome = try await LibraryProcessPlanner.execute(
        books: books.map(\.planner), toggles: toggles,
        settings: .init(
          voiceID: voiceID, bitrateKbps: bitrateKbps, workers: workers,
          announceTitles: announceTitles,
          paragraphPause: paragraphPause, chapterPause: chapterPause,
          readAloudBitrateKbps: readAloudBitrateKbps,
          readAloudASREngineID: readAloudASREngineID,
          readAloudASRModelID: readAloudASRModelID),
        connections: connections, catalogStore: catalogStore,
        voices: voices.map {
          .init(
            voiceID: $0.key.voiceID, modelRevision: $0.modelRevision,
            voiceRevision: $0.voiceRevision)
        },
        processedDirectory: processedDirectory,
        configuredWorkDirectory: configuredWorkDirectory,
        scheduler: coordinator.service,
        progress: { [weak self] message in
          Task { @MainActor in
            guard let self, case .working = self.phase else { return }
            self.phase = .working(message)
          }
        })
      switch outcome {
      case .review(let candidates):
        reviewCandidates = candidates
      case .queued(let count, let failures):
        bookFailures = failures
        if count > 0 {
          phase = .queued(count)
          await coordinator.reload()
        } else if failures.isEmpty {
          error = "Nothing to queue."
        }
      }
    } catch {
      self.error = error.localizedDescription
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
          if model.sendsReadAloudProduct {
            VStack(alignment: .leading, spacing: 3) {
              Picker("Sent narration", selection: $model.sentNarration) {
                Text("SpokenFolio TTS").tag("spokenFolioTTS")
                Text("Human").tag("human")
              }
              Text("Declares how the sent ReadAloud narration was produced.")
                .font(.caption).foregroundStyle(.secondary)
            }
          }
          replacementWarnings
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

  /// The per-book loss manifest for deliveries whose Storyteller target is
  /// occupied with different content, plus the required acknowledgment.
  /// Recomputed by the model whenever any send/create toggle or the
  /// connection changes, so it always matches what would actually be queued.
  @ViewBuilder private var replacementWarnings: some View {
    let impacts = model.replacementImpacts
    if !impacts.isEmpty {
      ForEach(impacts, id: \.rowID) { impact in
        VStack(alignment: .leading, spacing: 5) {
          Label {
            Text(
              model.singleBook != nil
                ? "Storyteller already has different content for this book:"
                : "\(impact.title) — Storyteller already has different content:")
              .font(.callout.weight(.semibold))
          } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
          }
          if impact.losesHumanAudio {
            Label(
              "This replaces a HUMAN-narrated audiobook with your local TTS version.",
              systemImage: "xmark.octagon.fill")
              .font(.callout.weight(.bold)).foregroundStyle(.red)
          }
          ForEach(impact.assets, id: \.assetID) { asset in
            assetFate(asset)
          }
        }
      }
      Toggle(isOn: $model.replaceAcknowledged) {
        Text(
          "Replace the listed Storyteller files for \(impacts.count) book\(impacts.count == 1 ? "" : "s") — I understand the old versions are overwritten")
          .font(.callout.weight(.medium))
      }
    }
  }

  /// One remote asset the planned send replaces (per-asset, through
  /// Storyteller's own replace API — nothing else on the book is touched).
  private func assetFate(_ asset: LibraryProcessPlanner.ReplacementImpact.Asset) -> some View {
    let name = formatLabel(asset.format) + (asset.humanNarration ? " (human-narrated)" : "")
    let size = asset.size.map {
      " · " + ByteCountFormatter.string(fromByteCount: Int64(clamping: $0), countStyle: .file)
    } ?? ""
    return Label {
      Text("\(name)\(size): replaced with your local version")
        .foregroundStyle(asset.humanNarration ? Color.red : Color.primary)
    } icon: {
      Image(systemName: asset.humanNarration ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
        .foregroundStyle(asset.humanNarration ? Color.red : Color.orange)
    }
    .font(.callout)
  }

  private func formatLabel(_ format: String) -> String {
    switch format {
    case "ebook": "EPUB"
    case "audiobook": "Audiobook"
    case "readaloud": "ReadAloud"
    default: format
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
        .disabled(isWorking || model.books.isEmpty || model.needsReplaceAcknowledgment)
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

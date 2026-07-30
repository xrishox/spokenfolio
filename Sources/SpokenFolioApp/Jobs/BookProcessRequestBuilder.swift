import AudiobookKit
import BookJobKit
import EPUBKit
import Foundation
import PublicationKit
import StorytellerKit

/// The processing choices a caller makes for one book. The Create page fills
/// this from a draft; the Library's Process sheet fills it from its steps.
struct BookProcessSettings: Sendable {
  var backendID: String = "siri"
  var modelID: String = "siri-private"
  var pacePreset: Int? = nil
  var expressivityPreset: Int? = nil
  var voiceID: String
  var voiceModelRevision: String?
  var voiceRevision: String?
  var bitrateKbps: Int
  var workers: Int
  var unitGranularityID: String = "paragraph"
  var announceTitles: Bool
  var paragraphPauseSeconds: Double
  var chapterPauseSeconds: Double
  var includedSectionIDs: [String] = []
  var excludedSectionIDs: [String] = []
  var createReadAloud: Bool
  /// Digest-guarded in-place recreation of an existing ReadAloud (for example
  /// with the current synthesis-timing policy). Only meaningful when the
  /// catalog already has a ReadAloud product.
  var recreateReadAloud: Bool = false
  /// Digest-guarded replacement of an existing M4B (the Library's Reprocess).
  var reprocessAudiobook: Bool = false
  var readAloudBitrateKbps: Int
  var readAloudASREngineID: String
  var readAloudASRModelID: String
  var language: String?
  var workDirectory: String?

  struct Delivery: Sendable {
    var connectionID: UUID
    var remoteBookID: UUID
    var products: Set<BookProductKind>
    /// Remote formats the user acknowledged replacing, each carrying its
    /// confirmed snapshot in `expectedRemoteAssets` (see docs/STORYTELLER.md).
    var replaceFormats: [String] = []
    var expectedRemoteAssets: [BookJobRequest.StorytellerDelivery.ExpectedRemoteAsset] = []
    /// Declared provenance of the delivered ReadAloud ("human"/"spokenFolioTTS").
    var assertNarration: String? = nil
  }
}

/// One authority for turning a cataloged edition plus processing choices into
/// a durable `BookJobRequest`. The Create page and the Library Process sheet
/// both build through here so the operation semantics can never drift.
enum BookProcessRequestBuilder {
  struct Plan: Equatable {
    var operation: BookJobRequest.Operation
    var alignmentAudio: BookJobRequest.AlignmentAudio?
    var allowOverwrite: Bool
    var replacements: [BookJobRequest.ProductReplacement]
    var includesReadAloudCreation: Bool
  }

  enum PlanError: Error, LocalizedError, Equatable {
    case reprocessTargetMissing
    case recreateTargetMissing
    case nothingToDo

    var errorDescription: String? {
      switch self {
      case .reprocessTargetMissing:
        "the audiobook selected for reprocessing no longer exists"
      case .recreateTargetMissing:
        "the ReadAloud selected for recreation no longer exists"
      case .nothingToDo:
        "every requested product already exists; nothing would be created or sent"
      }
    }
  }

  /// The operation matrix. Pure so every branch is unit-testable:
  /// - no M4B → production (optionally with ReadAloud and delivery),
  /// - reprocess → production with digest-guarded replacements,
  /// - M4B exists and a ReadAloud is wanted → ReadAloud-only with an
  ///   alignment plan (the existing M4B only aligns when it was synthesized
  ///   without chapter announcements),
  /// - recreate → ReadAloud-only with a digest-guarded ReadAloud replacement,
  /// - otherwise → delivery-only (requires a delivery).
  static func plan(
    catalog: BookCatalogRecord, settings: BookProcessSettings, hasDelivery: Bool
  ) throws -> Plan {
    let audiobook = catalog.product(.m4b)
    let readAloudProduct = catalog.product(.readAloudEPUB)

    if settings.reprocessAudiobook {
      guard let audiobook else { throw PlanError.reprocessTargetMissing }
      var replacements: [BookJobRequest.ProductReplacement] = [
        .init(kind: .m4b, expectedSHA256: audiobook.sha256)
      ]
      if settings.createReadAloud, let readAloudProduct {
        replacements.append(
          .init(kind: .readAloudEPUB, expectedSHA256: readAloudProduct.sha256))
      }
      return Plan(
        operation: .production, alignmentAudio: nil, allowOverwrite: true,
        replacements: replacements,
        includesReadAloudCreation: settings.createReadAloud)
    }

    if let audiobook {
      if settings.createReadAloud, settings.recreateReadAloud {
        guard let readAloudProduct else { throw PlanError.recreateTargetMissing }
        return Plan(
          operation: .readAloud,
          alignmentAudio: alignment(for: audiobook),
          allowOverwrite: true,
          replacements: [
            .init(kind: .readAloudEPUB, expectedSHA256: readAloudProduct.sha256)
          ],
          includesReadAloudCreation: true)
      }
      if settings.createReadAloud, readAloudProduct == nil {
        return Plan(
          operation: .readAloud,
          alignmentAudio: alignment(for: audiobook),
          allowOverwrite: false, replacements: [],
          includesReadAloudCreation: true)
      }
      guard hasDelivery else { throw PlanError.nothingToDo }
      return Plan(
        operation: .storytellerDelivery, alignmentAudio: nil,
        allowOverwrite: false, replacements: [], includesReadAloudCreation: false)
    }

    return Plan(
      operation: .production, alignmentAudio: nil, allowOverwrite: false,
      replacements: [], includesReadAloudCreation: settings.createReadAloud)
  }

  /// Cataloged M4Bs predate exact request-unit provenance. A new exact-timing
  /// ReadAloud therefore resynthesizes temporary audio with the selected
  /// unit granularity instead of guessing that an existing M4B has a
  /// compatible timeline.
  private static func alignment(
    for audiobook: BookCatalogProduct
  ) -> BookJobRequest.AlignmentAudio {
    _ = audiobook
    return .init(mode: .temporaryResynthesis)
  }

  /// Assembles the full durable request for one cataloged edition.
  /// `narrationOverride` lets callers reuse a specific narration identity —
  /// the Library passes the cataloged M4B's own narration for jobs that will
  /// not synthesize new audio (alignment against the existing M4B, delivery).
  static func request(
    catalog: BookCatalogRecord,
    settings: BookProcessSettings,
    delivery: BookProcessSettings.Delivery?,
    narrationOverride: BookJobRequest.Narration? = nil,
    batchID: UUID? = nil, batchOrdinal: Int? = nil, batchCount: Int? = nil
  ) throws -> BookJobRequest {
    let plan = try plan(catalog: catalog, settings: settings, hasDelivery: delivery != nil)
    let layout = catalog.layout

    let createdReadAloud: BookJobRequest.ReadAloud? = plan.includesReadAloudCreation
      ? .init(
        outputPath: layout.readAloud.path,
        opusBitrateKbps: settings.readAloudBitrateKbps,
        language: settings.language,
        asrEngineID: "synthesis",
        asrModelID: nil)
      : nil
    // A delivery that sends an existing ReadAloud must describe it even when
    // this job creates nothing (request validation requires it). A reprocess
    // never inherits the catalog descriptor: its ReadAloud becomes stale the
    // moment the M4B is replaced.
    let readAloud = createdReadAloud
      ?? (settings.reprocessAudiobook
        ? nil
        : catalog.product(.readAloudEPUB).map {
          BookJobRequest.ReadAloud(
            outputPath: $0.path, opusBitrateKbps: $0.readAloud?.opusBitrateKbps ?? 32)
        })

    var narration = narrationOverride
      ?? BookJobRequest.Narration(
        backendID: settings.backendID, modelID: settings.modelID,
        modelRevision: settings.voiceModelRevision, voiceID: settings.voiceID,
        voiceRevision: settings.voiceRevision,
        pacePreset: settings.pacePreset, expressivityPreset: settings.expressivityPreset,
        includedSectionIDs: settings.includedSectionIDs,
        excludedSectionIDs: settings.excludedSectionIDs,
        bitrateKbps: settings.bitrateKbps,
        workers: ProductionWorkerPolicy.resolved(
          settings.workers, backendID: settings.backendID, modelID: settings.modelID),
        paragraphPauseSeconds: settings.paragraphPauseSeconds,
        chapterPauseSeconds: settings.chapterPauseSeconds,
        announceTitles: settings.announceTitles,
        unitGranularityID: settings.unitGranularityID)
    // Any request carrying a ReadAloud descriptor must disable synthetic
    // announcements (request validation enforces it) — including
    // delivery-only jobs, which synthesize nothing anyway.
    if readAloud != nil { narration.announceTitles = false }

    return BookJobRequest(
      catalogID: catalog.id, batchID: batchID, batchOrdinal: batchOrdinal,
      batchCount: batchCount, managedByStudio: true,
      title: catalog.metadata.title, author: catalog.metadata.author,
      source: .init(
        path: layout.sourceEPUB.path, sha256: catalog.source.sha256, format: "epub",
        importerVersion: catalog.source.importerVersion,
        identifiers: catalog.metadata.identifiers.map(\.value),
        typedIdentifiers: catalog.metadata.identifiers),
      narration: narration, m4bOutputPath: layout.audiobook.path,
      m4bWorkDirectory: settings.workDirectory,
      allowOverwrite: plan.allowOverwrite,
      readAloud: readAloud,
      alignmentAudio: plan.alignmentAudio,
      storyteller: delivery.map {
        .init(
          connectionID: $0.connectionID, remoteBookID: $0.remoteBookID,
          products: $0.products,
          replaceFormats: $0.replaceFormats.isEmpty ? nil : $0.replaceFormats,
          expectedRemoteAssets: $0.expectedRemoteAssets.isEmpty
            ? nil : $0.expectedRemoteAssets,
          assertNarration: $0.assertNarration)
      },
      operation: plan.operation,
      productReplacements: plan.replacements)
  }

  enum DeliveryResolution: Sendable {
    /// A safe destination exists (or will be created). When the resolver
    /// linked automatically, the updated catalog carries the new remote link.
    case resolved(BookProcessSettings.Delivery, updatedCatalog: BookCatalogRecord?)
    /// The server has plausible matches that a person must review.
    case review([StorytellerMatchCandidate])
  }

  /// Resolves where on Storyteller a catalog's products may safely go —
  /// shared by the Create page and the Library so linking semantics and
  /// evidence handling can never drift.
  static func resolveDelivery(
    catalog: BookCatalogRecord, catalogStore: BookCatalogStore,
    connection: StorytellerConnection, products: Set<BookProductKind>
  ) async throws -> DeliveryResolution {
    let token = try await StorytellerConnectionStore.shared.token(connection.id)
    let client = try StorytellerClient(origin: connection.origin, tokenProvider: { token })
    let existingLink = catalog.remoteLinks.first {
      $0.providerID == "storyteller" && $0.connectionID == connection.id
    }
    let localProducts = catalog.products.map { product in
      StorytellerLocalProductIdentity(
        format: remoteFormat(product.kind), size: product.size, sha256: product.sha256)
    }
    let excluded = Set(
      existingLink?.excludedRemoteBookIDs.compactMap(UUID.init(uuidString:)) ?? [])
    let resolution = try await StorytellerIdentityResolver(client: client).resolve(
      local: .init(
        title: catalog.metadata.title, author: catalog.metadata.author,
        identifiers: catalog.metadata.identifiers, products: localProducts,
        excludedBookIDs: excluded),
      linkedBookID: existingLink.flatMap { UUID(uuidString: $0.remoteBookID) })
    switch resolution {
    case .linked(let id):
      return .resolved(
        .init(connectionID: connection.id, remoteBookID: id, products: products),
        updatedCatalog: nil)
    case .automatic(let id, let evidence):
      var updated = catalog
      updated.upsertRemoteLink(
        .init(
          providerID: "storyteller", connectionID: connection.id,
          remoteBookID: id.uuidString.lowercased(),
          evidence: evidence == .exactAssetHash ? .exactAssetHash : .validatedIdentifier))
      try await catalogStore.update(updated, expectedRevision: catalog.revision)
      return .resolved(
        .init(connectionID: connection.id, remoteBookID: id, products: products),
        updatedCatalog: updated)
    case .create:
      return .resolved(
        .init(
          connectionID: connection.id,
          remoteBookID: DeterministicBookID.make(catalogID: catalog.id),
          products: products),
        updatedCatalog: nil)
    case .review(let candidates):
      return .review(candidates)
    }
  }

  private static func remoteFormat(_ kind: BookProductKind) -> StorytellerFormat {
    switch kind {
    case .sourceEPUB: .ebook
    case .m4b, .humanAudiobook: .audiobook
    case .readAloudEPUB, .humanReadAloudEPUB: .readaloud
    }
  }

  /// Finds or creates the catalog record for a source EPUB, staging the file
  /// into the managed layout with collision handling. The compliance boundary
  /// runs before metadata extraction: EPUB 3 is independently checked, while
  /// EPUB 2 is converted by Calibre and then checked. Concurrent creation is
  /// tolerated: a racing record for the same normalized source wins.
  static func resolveCatalog(
    store: BookCatalogStore, sourceURL: URL, outputDirectory: URL
  ) async throws -> BookCatalogRecord {
    let prepared = try await EPUBCompliance.prepare(source: sourceURL)
    defer { prepared.cleanup() }
    let normalized = try await Task.detached {
      let sha256 = try BookFileDigest.sha256(prepared.url)
      let size = try BookFileDigest.size(prepared.url)
      let publication = try EPUBImporter().load(url: prepared.url)
      let plan = try AudiobookPlanner.plan(publication: publication)
      return (sha256, size, plan.metadata)
    }.value
    let sourceSHA256 = normalized.0
    let sourceSize = normalized.1
    let title = normalized.2.title
    let author = normalized.2.author
    let language = normalized.2.language
    let publisher = normalized.2.publisher
    let publicationDate = normalized.2.date
    let identifiers = normalized.2.identifiers
    if let existing = try await store.find(sourceSHA256: sourceSHA256) {
      return existing
    }
    let records = try await store.scan().records
    let ordinary = ManagedBookLayout(
      directory: outputDirectory, title: title, author: author?.isEmpty == true ? nil : author)
    // Another edition owning the folder, or any pre-existing folder of the
    // same name, pushes this book to a collision-suffixed folder: a book
    // folder belongs to exactly one edition. The one exception is our own
    // staged EPUB left by a crash between staging and cataloging — that
    // folder is reclaimed rather than duplicated.
    let conflicts: Bool
    if records.contains(where: {
      $0.outputDirectory == ordinary.directory.path && $0.outputBaseName == ordinary.baseName
    }) {
      conflicts = true
    } else if FileManager.default.fileExists(atPath: ordinary.directory.path) {
      conflicts = (try? BookFileDigest.sha256(ordinary.sourceEPUB)) != sourceSHA256
    } else {
      conflicts = false
    }
    let layout = conflicts
      ? ManagedBookLayout(
        directory: outputDirectory, title: title,
        author: author?.isEmpty == true ? nil : author,
        collisionHash: sourceSHA256)
      : ordinary
    try layout.stageSource(from: prepared.url, expectedSHA256: sourceSHA256)
    let sourceProduct = BookCatalogProduct(
      kind: .sourceEPUB, path: layout.sourceEPUB.path, size: sourceSize,
      sha256: sourceSHA256, verifiedAt: Date())
    let record = BookCatalogRecord(
      source: .init(
        format: "epub", importerVersion: EPUBImporter().importerVersion,
        sha256: sourceSHA256, size: sourceSize),
      metadata: .init(
        title: title, author: author?.isEmpty == true ? nil : author,
        language: language, publisher: publisher,
        publicationDate: publicationDate, identifiers: identifiers),
      outputDirectory: layout.directory.path, outputBaseName: layout.baseName,
      products: [sourceProduct])
    do { try await store.create(record) } catch {
      if let raced = try await store.find(sourceSHA256: sourceSHA256) { return raced }
      throw error
    }
    return record
  }

  /// Upgrades a legacy managed source in place before an immutable production
  /// request is assembled. The original managed bytes are retained as a
  /// rollback file until both the atomic file swap and SQLite transaction
  /// succeed; the user's external import file is never modified.
  static func ensureCompliantCatalog(
    _ catalog: BookCatalogRecord, store: BookCatalogStore
  ) async throws -> BookCatalogRecord {
    guard let sourceProduct = catalog.product(.sourceEPUB) else {
      throw BookJobError.corruptState("catalog has no managed source EPUB")
    }
    let sourceURL = URL(fileURLWithPath: sourceProduct.path)
    guard try BookFileDigest.sha256(sourceURL) == catalog.source.sha256 else {
      throw BookJobError.invalidRequest("cataloged source EPUB changed on disk")
    }
    let prepared = try await EPUBCompliance.prepare(source: sourceURL)
    defer { prepared.cleanup() }
    guard prepared.wasConverted else { return catalog }

    let newSHA256 = try BookFileDigest.sha256(prepared.url)
    let newSize = try BookFileDigest.size(prepared.url)
    let directory = sourceURL.deletingLastPathComponent()
    let token = UUID().uuidString
    let staged = directory.appendingPathComponent(".epub3-\(token).partial")
    let backup = directory.appendingPathComponent(".epub2-\(token).rollback")
    defer { try? FileManager.default.removeItem(at: staged) }
    try FileManager.default.copyItem(at: prepared.url, to: staged)
    guard try BookFileDigest.sha256(staged) == newSHA256 else {
      throw BookJobError.io("normalized EPUB changed while it was staged")
    }
    try FileManager.default.moveItem(at: sourceURL, to: backup)
    do {
      try FileManager.default.moveItem(at: staged, to: sourceURL)
      let product = BookCatalogProduct(
        kind: .sourceEPUB, path: sourceURL.path, size: newSize,
        sha256: newSHA256, verifiedAt: Date())
      let updated = try await store.replaceSource(
        catalogID: catalog.id, product: product,
        expectedCurrentSHA256: catalog.source.sha256,
        importerVersion: EPUBImporter().importerVersion)
      try FileManager.default.removeItem(at: backup)
      return updated
    } catch {
      try? FileManager.default.removeItem(at: sourceURL)
      do {
        try FileManager.default.moveItem(at: backup, to: sourceURL)
      } catch let rollbackError {
        throw BookJobError.io(
          "source normalization failed and its rollback could not be restored; "
            + "the original remains at \(backup.path): \(rollbackError.localizedDescription)")
      }
      throw error
    }
  }
}

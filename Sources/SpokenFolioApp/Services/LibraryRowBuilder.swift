import BookJobKit
import Foundation
import LibraryKit
import ReadAloudKit
import StorytellerKit

/// Stateless assembly of library rows: merges the local catalog, the selected
/// connection's remote snapshot, provenance assertions, quality audits, and
/// completeness evaluation into presentation-ready rows. Extracted from the
/// GUI model so the web API produces byte-identical rows.
enum LibraryRowBuilder {
  struct AssetKey: Hashable {
    let bookID: UUID
    let assetID: UUID
  }

  /// Everything row construction needs, loaded up front. Querying per row
  /// turns a large library reload into thousands of database round trips.
  struct RowContext {
    let editionsByID: [UUID: LibraryEdition]
    let provenanceByAsset: [AssetKey: LibraryProvenanceAssertion]
    let auditsByTarget: [LibraryReadAloudAuditTarget: LibraryReadAloudAuditRun]
  }

  /// Everything the library table needs, computed in one pass.
  struct Output {
    var rows: [StudioLibraryRow] = []
    var editionGapCount = 0
  }

  static func buildRows(
    library: LibraryStore, records: [BookCatalogRecord], connectionID: UUID?,
    snapshotStale: Bool
  ) throws -> Output {
    var output = Output()
    let remoteBooks = try connectionID.map {
      try library.remoteBooks(connectionID: $0, includeMissing: false)
    } ?? []
    let remoteByID = Dictionary(uniqueKeysWithValues: remoteBooks.map { ($0.remoteBookID, $0) })
    let context = try rowContext(
      library: library, records: records, connectionID: connectionID,
      remoteBooks: remoteBooks)
    output.editionGapCount = records.count { context.editionsByID[$0.id] == nil }
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
      result.append(
        try row(
          record: record, remote: remote, context: context, snapshotStale: snapshotStale))
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
          record: existing.record, remote: nil, suggested: remote, context: context,
          snapshotStale: snapshotStale)
      } else {
        result.append(
          try row(record: nil, remote: remote, context: context, snapshotStale: snapshotStale))
      }
    }
    output.rows = result.sorted {
      if $0.level != $1.level { return $0.level > $1.level }
      return $0.title.localizedStandardCompare($1.title) == .orderedAscending
    }
    return output
  }

  private static func rowContext(
    library: LibraryStore, records: [BookCatalogRecord], connectionID: UUID?,
    remoteBooks: [LibraryRemoteBookSnapshot]
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

  private static func row(
    record: BookCatalogRecord?, remote: LibraryRemoteBookSnapshot?,
    suggested: LibraryRemoteBookSnapshot? = nil, context: RowContext,
    snapshotStale: Bool
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
      suggestedRemote: suggested,
      serverSlots: Self.serverSlots(
        record: record, remote: remote, link: link,
        provenFormats: provenFormats, narration: narration))
  }

  /// What is KNOWN to live on the linked Storyteller book, per slot.
  /// Rules, in order of honesty:
  /// - Only a confirmed link counts; suggestions prove nothing.
  /// - A slot is `verifiedCurrent` when a receipt proves the server copy is
  ///   byte-identical to the CURRENT local product: the receipt already
  ///   re-validated against the live asset (identity, size, recorded hash —
  ///   `provenFormats`), its fingerprint still matches when both sides have
  ///   one, and its local hash equals the product on disk today.
  /// - Otherwise a ready server asset is `present`, but ONLY when the slot
  ///   attribution is certain: the ebook always is; audiobook/readaloud
  ///   attribute to the TTS or Human slot only when narration is known.
  ///   Unknown narration displays nothing rather than a guess.
  static func serverSlots(
    record: BookCatalogRecord?, remote: LibraryRemoteBookSnapshot?,
    link: BookCatalogRemoteLink?, provenFormats: Set<LibraryRemoteFormat>,
    narration: NarrationProvenance
  ) -> StudioLibraryRow.ServerSlots {
    guard let remote else { return .init() }
    func productKind(_ format: LibraryRemoteFormat) -> BookProductKind {
      switch format {
      case .ebook: .sourceEPUB
      case .audiobook: .m4b
      case .readaloud: .readAloudEPUB
      }
    }
    func state(_ format: LibraryRemoteFormat) -> StudioLibraryRow.SlotServerState? {
      guard let asset = remote.asset(format), asset.state == .ready else { return nil }
      guard provenFormats.contains(format),
        let receipt = link?.receipts.first(where: { $0.format == format.rawValue }),
        receipt.localSHA256 == record?.product(productKind(format))?.sha256,
        receipt.remoteFingerprint == nil || asset.fingerprint == nil
          || receipt.remoteFingerprint == asset.fingerprint
      else { return .present }
      return .verifiedCurrent
    }
    let tts = narration == .spokenFolioTTS || narration == .otherTTS
    let human = narration == .human
    return .init(
      epub: state(.ebook),
      ttsAudiobook: tts ? state(.audiobook) : nil,
      ttsReadAloud: tts ? state(.readaloud) : nil,
      humanAudiobook: human ? state(.audiobook) : nil,
      humanReadAloud: human ? state(.readaloud) : nil)
  }

  /// The remote book's own modification time; the snapshot's `observedAt`
  /// only records when this Mac last fetched the inventory.
  static func remoteUpdatedAt(_ remote: LibraryRemoteBookSnapshot?) -> Date? {
    guard let remote else { return nil }
    guard let value = remote.updatedAt else { return remote.observedAt }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: value)
      ?? ISO8601DateFormatter().date(from: value)
      ?? remote.observedAt
  }

  static func searchIndex(
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

  static func ttsProvenance(_ narration: BookJobRequest.Narration) -> String {
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

  static func localCoherence(_ edition: LibraryEdition?) -> PackageCoherence {
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

  static func qualityCoherence(
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

  static func localProductReady(_ product: BookCatalogProduct) -> Bool {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: product.path),
      let type = attributes[.type] as? FileAttributeType, type == .typeRegular,
      let size = attributes[.size] as? NSNumber,
      let modificationDate = attributes[.modificationDate] as? Date
    else { return false }
    return size.uint64Value == product.size
      && modificationDate <= product.verifiedAt.addingTimeInterval(1)
  }

  static func snapshot(
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
}

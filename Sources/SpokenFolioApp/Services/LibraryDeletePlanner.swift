import BookJobKit
import Foundation
import LibraryKit
import StorytellerKit

/// The Library "Delete" engine, extracted from the GUI sheet so the web API
/// computes an identical manifest and executes identical deletions. It is a
/// pure, per-book function of what the user selected — no I/O — mirroring
/// `LibraryProcessPlanner.replacementImpact`. The service and both UI surfaces
/// share it so the confirmation manifest can never diverge from what is
/// actually deleted.
///
/// Scope is one global choice applied to every selected slot; per book we act
/// only where a slot actually exists in that scope, and books with nothing to
/// do are surfaced as skipped, never blocked. Deleting the source EPUB is a
/// whole-LOCAL-book delete (the edition cannot exist without its source);
/// remote deletion is ALWAYS per-asset and never deletes a whole remote book.
enum LibraryDeletePlanner {
  enum Scope: String, Sendable, Codable, CaseIterable {
    case local, storyteller, both
    var deletesLocal: Bool { self == .local || self == .both }
    var deletesRemote: Bool { self == .storyteller || self == .both }
  }

  struct Selection: Sendable {
    var slots: Set<BookProductKind>
    var scope: Scope
  }

  /// Pure per-book input — the catalog record supplies local products and the
  /// source digest; the remote snapshot (already scoped to the linked
  /// connection by the row builder) supplies deletable assets.
  struct Book: Sendable {
    let id: String
    let title: String
    let record: BookCatalogRecord?
    let remote: LibraryRemoteBookSnapshot?
    let remoteNarration: NarrationProvenance
  }

  struct DeletionImpact: Sendable, Equatable {
    struct LocalSlot: Sendable, Equatable {
      let kind: BookProductKind
      let path: String
      let sha256: String
    }
    struct RemoteSlot: Sendable, Equatable {
      let format: LibraryRemoteFormat
      let assetID: UUID
      let size: UInt64?
      let sha256: String?
      let fingerprint: String?
      /// Audiobook/readaloud slot whose remote narration is asserted human —
      /// the UI flags these in red before deletion.
      let humanNarration: Bool
    }
    let rowID: String
    let title: String
    /// The cataloged edition id — local deletes and the scheduler active-work
    /// guard key on it. Nil for a Storyteller-only row (nothing local to
    /// delete).
    let catalogID: UUID?
    /// Source digest guarding a whole-book delete; nil when not cataloged.
    let sourceSHA256: String?
    /// Per-book folder removed after a whole-book delete.
    let outputDirectory: String?
    /// Digests of local M4B products, so their Application-Support synthesis
    /// timeline sidecars are removed too (they live outside the book folder).
    let audiobookSHA256s: [String]
    /// The source slot was selected in local scope → delete the entire local
    /// book (all products, the record, and the folder), not just one product.
    let wholeBookLocal: Bool
    /// Non-source local products to remove individually (empty when
    /// `wholeBookLocal`, which supersedes them).
    let localSlots: [LocalSlot]
    let connectionID: UUID?
    let remoteBookID: UUID?
    let remoteSlots: [RemoteSlot]

    /// The confirmation snapshots the deletion carries: each remote asset
    /// re-verifies against its snapshot (ceiling semantics) immediately before
    /// it is deleted, exactly like an acknowledged replacement.
    var expectedRemoteAssets: [BookJobRequest.StorytellerDelivery.ExpectedRemoteAsset] {
      remoteSlots.map {
        .init(
          format: $0.format.rawValue, assetID: $0.assetID, size: $0.size, sha256: $0.sha256,
          fingerprint: $0.fingerprint)
      }
    }

    /// True when the deletion destroys human-narrated content — a downloaded
    /// human local product, a whole-book delete that includes one, or a
    /// human-narrated remote asset. Drives the escalated warning copy.
    var losesHumanContent: Bool {
      remoteSlots.contains(where: \.humanNarration)
        || localSlots.contains { $0.kind == .humanAudiobook || $0.kind == .humanReadAloudEPUB }
        || (wholeBookLocal && wholeBookLosesHuman)
    }

    /// Nothing to do — the book is skipped rather than listed.
    var isEmpty: Bool { !wholeBookLocal && localSlots.isEmpty && remoteSlots.isEmpty }

    /// A whole-book delete doesn't enumerate individual local slots, so whether
    /// it destroys downloaded human products is recorded here by the planner.
    let wholeBookLosesHuman: Bool

    init(
      rowID: String, title: String, catalogID: UUID?, sourceSHA256: String?,
      outputDirectory: String?, audiobookSHA256s: [String], wholeBookLocal: Bool,
      wholeBookLosesHuman: Bool, localSlots: [LocalSlot], connectionID: UUID?,
      remoteBookID: UUID?, remoteSlots: [RemoteSlot]
    ) {
      self.rowID = rowID
      self.title = title
      self.catalogID = catalogID
      self.sourceSHA256 = sourceSHA256
      self.outputDirectory = outputDirectory
      self.audiobookSHA256s = audiobookSHA256s
      self.wholeBookLocal = wholeBookLocal
      self.wholeBookLosesHuman = wholeBookLosesHuman
      self.localSlots = localSlots
      self.connectionID = connectionID
      self.remoteBookID = remoteBookID
      self.remoteSlots = remoteSlots
    }
  }

  struct Plan: Sendable {
    var impacts: [DeletionImpact] = []
    var skipped: [(rowID: String, title: String, reason: String)] = []
  }

  /// The remote format a selected local slot maps to. The two audiobook slots
  /// (TTS + human) and the two readaloud slots collapse onto one remote asset
  /// each — Storyteller has three formats, the local library has five.
  static func remoteFormat(for kind: BookProductKind) -> LibraryRemoteFormat {
    switch kind {
    case .sourceEPUB: .ebook
    case .m4b, .humanAudiobook: .audiobook
    case .readAloudEPUB, .humanReadAloudEPUB: .readaloud
    }
  }

  /// Computes the deletion manifest for one book, or nil when nothing the user
  /// selected exists for this book in the chosen scope.
  static func deletionImpact(book: Book, selection: Selection) -> DeletionImpact? {
    var wholeBookLocal = false
    var wholeBookLosesHuman = false
    var localSlots: [DeletionImpact.LocalSlot] = []
    if selection.scope.deletesLocal, let record = book.record {
      if selection.slots.contains(.sourceEPUB) {
        wholeBookLocal = true
        wholeBookLosesHuman = record.products.contains {
          $0.kind == .humanAudiobook || $0.kind == .humanReadAloudEPUB
        }
      }
      // Individual non-source products are moot under a whole-book delete.
      if !wholeBookLocal {
        for kind in selection.slots where kind != .sourceEPUB {
          if let product = record.product(kind) {
            localSlots.append(.init(kind: kind, path: product.path, sha256: product.sha256))
          }
        }
      }
    }

    var remoteSlots: [DeletionImpact.RemoteSlot] = []
    if selection.scope.deletesRemote, let remote = book.remote {
      let formats = Set(selection.slots.map(remoteFormat(for:)))
      for format in LibraryRemoteFormat.allCases where formats.contains(format) {
        // Only a READY asset occupies a deletable slot — a broken or
        // still-processing server-side asset is nothing to delete.
        guard let asset = remote.assets.first(where: { $0.format == format && $0.state == .ready })
        else { continue }
        remoteSlots.append(
          .init(
            format: format, assetID: asset.assetID, size: asset.fileSize, sha256: asset.sha256,
            fingerprint: asset.fingerprint,
            humanNarration: format != .ebook && book.remoteNarration == .human))
      }
    }

    let impact = DeletionImpact(
      rowID: book.id, title: book.title, catalogID: book.record?.id,
      sourceSHA256: book.record?.source.sha256, outputDirectory: book.record?.outputDirectory,
      audiobookSHA256s: book.record?.products.filter { $0.kind == .m4b }.map(\.sha256) ?? [],
      wholeBookLocal: wholeBookLocal, wholeBookLosesHuman: wholeBookLosesHuman,
      localSlots: localSlots, connectionID: book.remote?.connectionID,
      remoteBookID: book.remote?.remoteBookID, remoteSlots: remoteSlots)
    return impact.isEmpty ? nil : impact
  }

  /// Aggregates the manifest across a multi-selection; books with nothing to
  /// delete in scope are surfaced as skipped rather than silently dropped.
  static func plan(rows: [StudioLibraryRow], selection: Selection) -> Plan {
    var plan = Plan()
    for row in rows {
      let book = Book(
        id: row.id, title: row.title, record: row.record, remote: row.remote,
        remoteNarration: row.narration)
      if let impact = deletionImpact(book: book, selection: selection) {
        plan.impacts.append(impact)
      } else {
        plan.skipped.append(
          (rowID: row.id, title: row.title,
            reason: "none of the selected slots exist for this book in the chosen scope"))
      }
    }
    return plan
  }
}

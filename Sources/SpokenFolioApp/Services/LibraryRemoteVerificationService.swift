import BookJobKit
import Foundation
import LibraryKit
import StorytellerKit

/// The on-demand "recheck what is really on Storyteller" pass, shared by the
/// desktop inspector and the web API. For every selected linked book it
/// fetches the live remote book and runs the one-byte hash probe per asset,
/// then rewrites the delivery receipts to match reality: proven-identical
/// assets get fresh receipts, anything that no longer matches loses its
/// receipt. The row builder re-derives the displayed per-slot state from
/// these receipts, so display can never outrun the evidence.
enum LibraryRemoteVerificationService {
  struct Outcome: Sendable {
    var checkedBooks = 0
    var verifiedAssets = 0
    var droppedReceipts = 0
    var failures: [(title: String, reason: String)] = []
  }

  enum ReceiptDecision: Equatable, Sendable {
    /// Proven identical right now: write/refresh the receipt.
    case write(BookCatalogRemoteReceipt)
    /// Proven different, asset gone, or no local counterpart: drop it.
    case drop
    /// Nothing provable either way: keep whatever is recorded, but only if
    /// it still matches the live asset identity.
    case keepIfStillValid
  }

  /// The pure per-format decision. `localHashes` are the sha256s of every
  /// local product for this format family (a TTS product and/or a
  /// downloaded human product); the receipt records whichever the server
  /// hash matches. `probeHash` is the server's full-asset sha256 from the
  /// one-byte probe (nil when the server could not provide one).
  static func decide(
    liveAsset: StorytellerAsset?, localHashes: [String], probeHash: String?,
    format: LibraryRemoteFormat
  ) -> ReceiptDecision {
    guard let liveAsset else { return .drop }
    guard !localHashes.isEmpty else { return .drop }
    guard let probeHash else { return .keepIfStillValid }
    guard localHashes.contains(probeHash) else { return .drop }
    return .write(
      BookCatalogRemoteReceipt(
        format: format.rawValue,
        localSHA256: probeHash,
        remoteAssetID: liveAsset.uuid.uuidString.lowercased(),
        remoteSize: liveAsset.fileSize,
        remoteFingerprint: liveAsset.fingerprint,
        remoteSHA256: probeHash))
  }

  static func verify(
    rows: [StudioLibraryRow], connection: StorytellerConnection,
    catalogStore: BookCatalogStore
  ) async -> Outcome {
    var outcome = Outcome()
    let client: StorytellerClient
    do {
      let connectionID = connection.id
      client = try StorytellerClient(origin: connection.origin) {
        try await StorytellerConnectionStore.shared.token(connectionID)
      }
    } catch {
      outcome.failures.append(("Connection", error.localizedDescription))
      return outcome
    }
    for row in rows {
      guard let record = row.record, let remote = row.remote,
        remote.connectionID == connection.id
      else { continue }
      do {
        guard let live = try await client.book(remote.remoteBookID) else {
          // The whole remote book is gone; every receipt is stale.
          try await rewriteReceipts(
            record: record, connectionID: connection.id, remoteBookID: remote.remoteBookID,
            receipts: [:], catalogStore: catalogStore)
          outcome.checkedBooks += 1
          continue
        }
        let link = record.remoteLinks.first {
          $0.providerID == "storyteller" && $0.connectionID == connection.id
        }
        var receipts = Dictionary(
          uniqueKeysWithValues: (link?.receipts ?? []).map { ($0.format, $0) })
        for format in LibraryRemoteFormat.allCases {
          let asset = live.asset(storytellerFormat(format))
          let localHashes = localProductHashes(format, record: record)
          var probeHash: String? = nil
          if let asset, let size = asset.fileSize, !localHashes.isEmpty {
            probeHash = try await client.assetHash(
              bookID: live.uuid, format: storytellerFormat(format), expectedSize: size)
          }
          switch Self.decide(
            liveAsset: asset, localHashes: localHashes, probeHash: probeHash, format: format)
          {
          case .write(let receipt):
            receipts[format.rawValue] = receipt
            outcome.verifiedAssets += 1
          case .drop:
            if receipts.removeValue(forKey: format.rawValue) != nil {
              outcome.droppedReceipts += 1
            }
          case .keepIfStillValid:
            if let existing = receipts[format.rawValue],
              existing.remoteAssetID != asset?.uuid.uuidString.lowercased()
            {
              receipts.removeValue(forKey: format.rawValue)
              outcome.droppedReceipts += 1
            }
          }
        }
        try await rewriteReceipts(
          record: record, connectionID: connection.id, remoteBookID: remote.remoteBookID,
          receipts: receipts, catalogStore: catalogStore)
        outcome.checkedBooks += 1
      } catch {
        outcome.failures.append((row.title, error.localizedDescription))
      }
    }
    return outcome
  }

  private static func rewriteReceipts(
    record: BookCatalogRecord, connectionID: UUID, remoteBookID: UUID,
    receipts: [String: BookCatalogRemoteReceipt], catalogStore: BookCatalogStore
  ) async throws {
    // Reload for a fresh revision: verification can run concurrently with
    // other library mutations.
    guard
      let current = try await catalogStore.scan().records.first(where: { $0.id == record.id })
    else { return }
    var updated = current
    guard
      let link = updated.remoteLinks.first(where: {
        $0.providerID == "storyteller" && $0.connectionID == connectionID
      })
    else { return }
    var replacement = link
    replacement.receipts = receipts.values.sorted { $0.format < $1.format }
    replacement.lastObservedAt = Date()
    updated.upsertRemoteLink(replacement)
    if updated != current {
      try await catalogStore.update(updated, expectedRevision: current.revision)
    }
  }

  /// Every local product hash that could match this remote format: the
  /// synthesized product and/or the downloaded human product.
  private static func localProductHashes(
    _ format: LibraryRemoteFormat, record: BookCatalogRecord
  ) -> [String] {
    let kinds: [BookProductKind]
    switch format {
    case .ebook: kinds = [.sourceEPUB]
    case .audiobook: kinds = [.m4b, .humanAudiobook]
    case .readaloud: kinds = [.readAloudEPUB, .humanReadAloudEPUB]
    }
    return kinds.compactMap { record.product($0)?.sha256 }
  }

  private static func storytellerFormat(_ format: LibraryRemoteFormat) -> StorytellerFormat {
    switch format {
    case .ebook: .ebook
    case .audiobook: .audiobook
    case .readaloud: .readaloud
    }
  }
}

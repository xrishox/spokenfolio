import BookJobKit
import Foundation
import StorytellerKit

/// The one gate every destructive Storyteller mutation passes through:
/// acknowledged replacement and per-asset deletion both re-verify the asset
/// against the snapshot the user actually confirmed, immediately before the
/// request goes out.
///
/// Stock Storyteller has no `If-Match`, no hash precondition, and no
/// compare-and-set of any kind, so this is a client-side check with a real
/// window: it proves the asset was unchanged a moment ago, not that it stays
/// unchanged during the mutation. It assumes no concurrent Storyteller
/// writer, and that assumption is presented to the user rather than hidden.
///
/// Ceiling semantics: an asset that APPEARED or CHANGED since the
/// confirmation aborts, because the user never agreed to destroy it. An asset
/// that VANISHED destroys nothing extra, so the caller proceeds without
/// reaching this check.
enum StorytellerMutationVerifier {
  enum Action: String {
    case replacement, deletion

    var verb: String { self == .replacement ? "replacement" : "deletion" }
  }

  /// What the live hash probe produced. `unavailable` and `failed` are kept
  /// apart from `value` because neither may be read as "unchanged".
  enum LiveHash: Sendable {
    /// The server returned a comparable hash for the source asset.
    case value(String)
    /// The server has no comparable hash — it is missing, forbidden, or the
    /// route served a representation it generated for the request.
    case unavailable
    /// The probe itself failed. Never silently downgraded to `unavailable`.
    case failed(String)
  }

  /// Runs a hash probe without letting an error become "no hash". The
  /// distinction is the whole point: `try?` here would turn a failed identity
  /// check into a passed one.
  static func liveHash(_ probe: () async throws -> String?) async -> LiveHash {
    do {
      guard let value = try await probe() else { return .unavailable }
      return .value(value)
    } catch {
      return .failed((error as? LocalizedError)?.errorDescription ?? "\(error)")
    }
  }

  /// Verifies one asset against its confirmation snapshot. Throws
  /// `StorytellerAPIError.conflict` with a user-facing reason on any drift.
  static func verify(
    format: StorytellerFormat,
    asset: StorytellerAsset,
    liveHash: LiveHash,
    expected: [BookJobRequest.StorytellerDelivery.ExpectedRemoteAsset],
    action: Action
  ) throws {
    func abort(_ reason: String) -> StorytellerAPIError {
      .conflict("\(action.verb) aborted: \(reason)")
    }

    guard let confirmed = expected.first(where: { $0.format == format.rawValue }) else {
      throw abort(
        "a remote \(format.rawValue) asset appeared after the confirmation; "
          + "review the book again")
    }
    guard asset.uuid == confirmed.assetID else {
      throw abort("the remote \(format.rawValue) asset changed since the confirmation")
    }
    if let size = confirmed.size {
      guard asset.fileSize == size else {
        throw abort("the remote \(format.rawValue) asset size changed since the confirmation")
      }
    }
    // Storyteller keeps the format-row UUID across a replacement, so identity
    // and size can both match content that was swapped underneath us. The
    // fingerprint is the extra signal when both sides have one.
    if let fingerprint = confirmed.fingerprint, let live = asset.fingerprint {
      guard fingerprint == live else {
        throw abort(
          "the remote \(format.rawValue) asset fingerprint changed since the confirmation")
      }
    }
    guard let confirmedHash = confirmed.sha256 else { return }
    // A confirmed hash must be re-proved. Anything short of a matching live
    // hash fails closed: the user acknowledged destroying specific content,
    // and we can no longer show that this is that content.
    switch liveHash {
    case .value(let live):
      guard live == confirmedHash else {
        throw abort("the remote \(format.rawValue) asset content changed since the confirmation")
      }
    case .unavailable:
      throw abort(
        "the remote \(format.rawValue) asset content could not be re-verified "
          + "(Storyteller returned no comparable hash)")
    case .failed(let reason):
      throw abort(
        "the remote \(format.rawValue) asset content could not be re-verified (\(reason))")
    }
  }
}

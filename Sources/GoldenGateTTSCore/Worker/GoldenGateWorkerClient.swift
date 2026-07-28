import LocalTTSWorkerKit
import TTSKit

/// Golden Gate's backend-specific identity check and worker-mode arguments;
/// process lifecycle, framing, cancellation, and deadlines are shared.
package final class GoldenGateWorkerClient: LocalTTSWorkerTransport, @unchecked Sendable {
  private let client: LocalTTSProcessWorkerClient

  package init(voice: VoiceKey) throws {
    guard voice.backendID == GoldenGateTTSBackend.backendID,
      voice.modelID == GoldenGateTTSBackend.modelID
    else { throw TTSBackendError.voiceNotFound(voice) }
    client = try LocalTTSProcessWorkerClient(
      arguments: ["--golden-gate-worker", voice.voiceID])
  }

  package func synthesize(
    request: TTSSynthesisRequest, deadline: ContinuousClock.Instant
  ) async throws -> LocalTTSWorkerResult {
    try await client.synthesize(request: request, deadline: deadline)
  }

  package func terminateHard() { client.terminateHard() }
}

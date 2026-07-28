import Foundation
import LocalTTSWorkerKit
import TTSKit

package final class SiriWorkerClient: LocalTTSWorkerTransport, @unchecked Sendable {
  private let client: LocalTTSProcessWorkerClient

  package init(voiceID: String) throws {
    client = try LocalTTSProcessWorkerClient(arguments: ["--siri-worker", voiceID])
  }

  package func synthesize(
    request: TTSSynthesisRequest, deadline: ContinuousClock.Instant
  ) async throws -> LocalTTSWorkerResult {
    try await client.synthesize(request: request, deadline: deadline)
  }

  package func terminateHard() { client.terminateHard() }
}

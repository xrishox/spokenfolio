import TTSKit

/// A backend whose synthesis workers are same-binary child processes managed by
/// `LocalTTSWorkerPool`. Audiobook sessions own isolated pools; HTTP sessions
/// may borrow one process-wide pool shared across every local backend.
package protocol LocalTTSWorkerBackendFactory: TTSBackendFactory {
  func makeWorkerClient(for voice: VoiceKey) throws -> any LocalTTSWorkerTransport
  func makeSession(
    configuration: TTSWorkloadConfiguration,
    sharedWorkerPool: LocalTTSWorkerPool
  ) throws -> any TTSSession
}

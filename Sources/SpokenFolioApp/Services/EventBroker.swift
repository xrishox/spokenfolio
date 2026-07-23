import Foundation

/// Fan-out for the web API's single SSE stream. Services push complete
/// per-topic JSON snapshots; every subscriber receives the latest snapshot
/// of each topic on subscribe and each change afterward. Snapshots carry a
/// monotonic sequence, so there is no replay and reconnect is trivially
/// correct: one event per topic restores full client state.
actor EventBroker {
  enum Topic: String, CaseIterable, Sendable {
    case server
    case queue
    case jobs
    case drafts
    case quality
    case tools
  }

  struct Event: Sendable {
    let topic: Topic
    let payload: Data
  }

  static let maximumSubscribers = 16

  private var latest: [Topic: Data] = [:]
  private var subscribers: [UUID: AsyncStream<Event>.Continuation] = [:]

  var subscriberCount: Int { subscribers.count }

  /// Publishes a topic snapshot to every subscriber and retains it for
  /// future subscribers.
  func publish(_ topic: Topic, payload: Data) {
    latest[topic] = payload
    let event = Event(topic: topic, payload: payload)
    for continuation in subscribers.values { continuation.yield(event) }
  }

  /// Returns nil when the subscriber cap is reached. The stream first
  /// yields the retained snapshot of every topic, then live events.
  func subscribe() -> AsyncStream<Event>? {
    guard subscribers.count < Self.maximumSubscribers else { return nil }
    let id = UUID()
    let retained = latest
    return AsyncStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
      subscribers[id] = continuation
      for (topic, payload) in retained {
        continuation.yield(Event(topic: topic, payload: payload))
      }
      continuation.onTermination = { _ in
        Task { [weak self] in await self?.remove(id) }
      }
    }
  }

  private func remove(_ id: UUID) {
    subscribers[id] = nil
  }
}

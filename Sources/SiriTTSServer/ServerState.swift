import Foundation
import Vapor

final class ServerHealth: @unchecked Sendable {
  enum State: String, Sendable {
    case starting
    case ready
    case permissionRequired = "permission_required"
    case unavailable
  }

  private let lock = NSLock()
  private var value: State = .starting

  var state: State {
    lock.lock()
    defer { lock.unlock() }
    return value
  }

  func set(_ state: State) {
    lock.lock()
    value = state
    lock.unlock()
  }
}

struct ServerHealthKey: StorageKey { typealias Value = ServerHealth }
struct RateLimiterKey: StorageKey { typealias Value = IPRateLimiter }
struct TTSImplementationKey: StorageKey { typealias Value = WorkerBackedTTSService }

extension Application {
  var serverHealth: ServerHealth {
    get { storage[ServerHealthKey.self]! }
    set { storage[ServerHealthKey.self] = newValue }
  }

  var rateLimiter: IPRateLimiter {
    get { storage[RateLimiterKey.self]! }
    set { storage[RateLimiterKey.self] = newValue }
  }

  var ttsImplementation: WorkerBackedTTSService {
    get { storage[TTSImplementationKey.self]! }
    set { storage[TTSImplementationKey.self] = newValue }
  }
}

actor IPRateLimiter {
  private struct Bucket {
    var tokens: Double
    var updatedAt: ContinuousClock.Instant
    var outstanding: Int
  }

  private let capacity = 20.0
  private let refillPerSecond = 2.0
  private let maxOutstanding = 12
  private let clock = ContinuousClock()
  private var buckets: [String: Bucket] = [:]

  func acquire(_ client: String) -> Bool {
    let now = clock.now
    var bucket = buckets[client] ?? Bucket(tokens: capacity, updatedAt: now, outstanding: 0)
    let elapsed = bucket.updatedAt.duration(to: now)
    let seconds =
      Double(elapsed.components.seconds)
      + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000_000
    bucket.tokens = min(capacity, bucket.tokens + max(0, seconds) * refillPerSecond)
    bucket.updatedAt = now

    guard bucket.tokens >= 1, bucket.outstanding < maxOutstanding else {
      buckets[client] = bucket
      return false
    }
    bucket.tokens -= 1
    bucket.outstanding += 1
    buckets[client] = bucket
    return true
  }

  func release(_ client: String) {
    guard var bucket = buckets[client] else { return }
    bucket.outstanding = max(0, bucket.outstanding - 1)
    buckets[client] = bucket
  }
}

struct RateLimitMiddleware: AsyncMiddleware {
  func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
    guard request.method == .POST, request.url.path.hasSuffix("/audio/speech") else {
      return try await next.respond(to: request)
    }
    let client = request.peerAddress?.ipAddress ?? "unknown"
    guard await request.application.rateLimiter.acquire(client) else {
      throw ServiceError.rateLimited
    }
    do {
      let response = try await next.respond(to: request)
      await request.application.rateLimiter.release(client)
      return response
    } catch {
      await request.application.rateLimiter.release(client)
      throw error
    }
  }
}

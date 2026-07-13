import Foundation
import SiriTTSCore
import Vapor

struct RateLimiterKey: StorageKey { typealias Value = IPRateLimiter }

extension Application {
  var rateLimiter: IPRateLimiter {
    get { storage[RateLimiterKey.self]! }
    set { storage[RateLimiterKey.self] = newValue }
  }
}
actor IPRateLimiter {
  private struct Bucket {
    var tokens: Double
    var updatedAt: ContinuousClock.Instant
    var lastSeen: ContinuousClock.Instant
    var outstanding: Int
  }

  private let capacity = 20.0
  private let refillPerSecond = 2.0
  private let maxOutstanding = 12
  private let maxTrackedClients = 4_096
  private let idleLifetime: Duration = .seconds(600)
  private let clock = ContinuousClock()
  private var buckets: [String: Bucket] = [:]

  func acquire(_ client: String) -> Bool {
    let now = clock.now
    if buckets[client] == nil {
      pruneIdle(now: now)
      if buckets.count >= maxTrackedClients {
        guard let victim = buckets
          .filter({ $0.value.outstanding == 0 })
          .min(by: { $0.value.lastSeen < $1.value.lastSeen })?.key
        else { return false }
        buckets.removeValue(forKey: victim)
      }
    }
    var bucket = buckets[client]
      ?? Bucket(tokens: capacity, updatedAt: now, lastSeen: now, outstanding: 0)
    let elapsed = bucket.updatedAt.duration(to: now)
    let seconds =
      Double(elapsed.components.seconds)
      + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000_000
    bucket.tokens = min(capacity, bucket.tokens + max(0, seconds) * refillPerSecond)
    bucket.updatedAt = now
    bucket.lastSeen = now

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
    bucket.lastSeen = clock.now
    buckets[client] = bucket
  }

  var trackedClientCount: Int { buckets.count }

  private func pruneIdle(now: ContinuousClock.Instant) {
    buckets = buckets.filter { _, bucket in
      bucket.outstanding > 0 || bucket.lastSeen.duration(to: now) < idleLifetime
    }
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

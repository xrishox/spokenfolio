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
  private var startupFailure: ServiceError?

  var state: State {
    lock.lock()
    defer { lock.unlock() }
    return value
  }

  func set(_ state: State) {
    lock.lock()
    value = state
    if state == .ready { startupFailure = nil }
    lock.unlock()
  }

  func setFailure(_ error: ServiceError) {
    lock.lock()
    startupFailure = error
    value = error.code == "siri_permission_required" ? .permissionRequired : .unavailable
    lock.unlock()
  }

  func requireReady() throws {
    lock.lock()
    let state = value
    let failure = startupFailure
    lock.unlock()
    guard state == .ready else { throw failure ?? ServiceError.engineUnavailable }
  }
}
struct ServerHealthKey: StorageKey { typealias Value = ServerHealth }


extension Application {
  var serverHealth: ServerHealth {
    get { storage[ServerHealthKey.self]! }
    set { storage[ServerHealthKey.self] = newValue }
  }
}

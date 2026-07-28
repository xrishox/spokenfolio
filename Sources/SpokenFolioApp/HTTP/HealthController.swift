import Vapor

struct HealthController: RouteCollection {
  struct HealthResponse: Content { let status: String }

  func boot(routes: any RoutesBuilder) throws {
    routes.get("health", "live", use: live)
    routes.get("health", "ready", use: ready)
  }

  @Sendable func live(req: Request) -> HealthResponse { HealthResponse(status: "live") }
  @Sendable func ready(req: Request) throws -> HealthResponse {
    try req.application.serverHealth.requireReady()
    return HealthResponse(status: ServerHealth.State.ready.rawValue)
  }
}

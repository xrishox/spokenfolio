import SiriTTSCore
import Vapor

func makeServerApplication(
  config: ServerConfig, studio: StudioServices? = nil
) async throws -> Application {
  var environment = try Environment.detect()
  environment.arguments = [environment.arguments.first ?? "spokenfolio", "serve"]
  let app = try await Application.make(environment)
  app.http.server.configuration.hostname = config.host
  app.http.server.configuration.port = config.port
  app.routes.defaultMaxBodySize = "64kb"

  let health = ServerHealth()
  app.serverHealth = health
  app.rateLimiter = IPRateLimiter()
  app.webServerConfig = config
  if let studio {
    app.studioServices = studio
    let pump = WebAPIEventPump()
    pump.start(services: studio)
    pump.startDrafts(services: studio)
    app.lifecycle.use(pump)
  }

  app.middleware = Middlewares()
  app.middleware.use(RequestLoggingMiddleware())
  app.middleware.use(OpenAIErrorMiddleware())
  app.middleware.use(RateLimitMiddleware())

  do {
    let service = try WorkerBackedTTSService(config: config)
    app.ttsService = service
    app.lifecycle.use(WorkerShutdownLifecycle(service: service))
    do {
      try await service.initialize()
      health.set(.ready)
    } catch let error as ServiceError {
      health.setFailure(error)
      app.logger.error("Siri service started in degraded state: \(error.code)")
    }
  } catch let error as ServiceError {
    guard case .engineUnavailable = error else {
      try? await app.asyncShutdown()
      throw error
    }
    app.ttsService = UnavailableTTSService(failure: error)
    health.setFailure(error)
    app.logger.error("Siri service started without a usable voice catalog")
  }

  let speech = SpeechController()
  let voices = VoicesController()
  try app.register(collection: speech)
  try app.register(collection: voices)
  let v1 = app.grouped("v1")
  try v1.register(collection: speech)
  try v1.register(collection: voices)
  try app.register(collection: HealthController())
  try app.register(collection: WebAPIController())
  try app.register(collection: DraftsAPIController())
  try app.register(collection: LibraryAPIController())
  try app.register(collection: WebUIController())
  return app
}

private struct WorkerShutdownLifecycle: LifecycleHandler {
  let service: WorkerBackedTTSService
  func shutdownAsync(_ application: Application) async { await service.shutdown() }
}

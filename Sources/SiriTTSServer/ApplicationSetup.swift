import Vapor

func makeServerApplication(config: ServerConfig) async throws -> Application {
  var environment = try Environment.detect()
  environment.arguments = [environment.arguments.first ?? "siri-tts-server", "serve"]
  let app = try await Application.make(environment)
  app.http.server.configuration.hostname = config.host
  app.http.server.configuration.port = config.port
  app.routes.defaultMaxBodySize = "64kb"

  let health = ServerHealth()
  app.serverHealth = health
  app.rateLimiter = IPRateLimiter()

  app.middleware = Middlewares()
  app.middleware.use(OpenAIErrorMiddleware())
  app.middleware.use(RequestLoggingMiddleware())
  app.middleware.use(RateLimitMiddleware())

  let service = try WorkerBackedTTSService(config: config)
  app.ttsService = service
  app.ttsImplementation = service
  app.lifecycle.use(WorkerShutdownLifecycle(service: service))

  do {
    try await service.initialize()
    health.set(.ready)
  } catch let error as ServiceError {
    if case .permissionRequired = error {
      health.set(.permissionRequired)
    } else {
      health.set(.unavailable)
    }
    try? await app.asyncShutdown()
    throw error
  }

  let speech = SpeechController()
  let voices = VoicesController()
  try app.register(collection: speech)
  try app.register(collection: voices)
  let v1 = app.grouped("v1")
  try v1.register(collection: speech)
  try v1.register(collection: voices)
  try app.register(collection: HealthController())
  return app
}

private struct WorkerShutdownLifecycle: LifecycleHandler {
  let service: WorkerBackedTTSService
  func shutdownAsync(_ application: Application) async { await service.shutdown() }
}

import TTSKit
import Vapor

struct VoicesController: RouteCollection {
  struct VoiceIdsResponse: Content { let voices: [String] }
  struct VoiceCatalogResponse: Content { let voices: [VoiceInfo] }
  struct ModelObject: Content {
    let id: String
    let object = "model"
    let created = 0
    let ownedBy = "spokenfolio"
    enum CodingKeys: String, CodingKey {
      case id, object, created
      case ownedBy = "owned_by"
    }
  }
  struct ModelListResponse: Content {
    let object: String
    let data: [ModelObject]

    init(data: [ModelObject]) {
      object = "list"
      self.data = data
    }
  }

  func boot(routes: any RoutesBuilder) throws {
    routes.get("audio", "voices", use: listVoiceIds)
    routes.get("audio", "voices", "all", use: listVoiceCatalog)
    routes.get("models", use: listModels)
  }

  @Sendable func listVoiceIds(req: Request) -> VoiceIdsResponse {
    VoiceIdsResponse(voices: req.ttsService.voiceCatalog.map(\.id))
  }
  @Sendable func listVoiceCatalog(req: Request) -> VoiceCatalogResponse {
    VoiceCatalogResponse(voices: req.ttsService.allVoiceCatalog)
  }
  @Sendable func listModels(req: Request) throws -> ModelListResponse {
    try req.application.serverHealth.requireReady()
    return ModelListResponse(
      data: req.ttsService.modelCatalog.map { ModelObject(id: $0.id) })
  }
}

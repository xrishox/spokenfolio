import Vapor

/// The web API's error envelope: `{"error":{"code","message"}}` with
/// `no-store`. Grouped middleware on `/api` only, so it catches API errors
/// before the OpenAI-envelope middleware sees them and never touches the
/// TTS contract or HTML routes.
struct WebAPIError: Error {
  let status: HTTPResponseStatus
  let code: String
  let message: String

  static func badRequest(_ code: String, _ message: String) -> WebAPIError {
    WebAPIError(status: .badRequest, code: code, message: message)
  }

  static func notFound(_ message: String) -> WebAPIError {
    WebAPIError(status: .notFound, code: "not_found", message: message)
  }

  static let studioUnavailable = WebAPIError(
    status: .serviceUnavailable, code: "studio_unavailable",
    message: "Studio services are not hosted by this server process. "
      + "Run the desktop app or `spokenfolio serve --studio`.")
}

struct WebAPIErrorMiddleware: AsyncMiddleware {
  struct Envelope: Content {
    struct Detail: Content {
      let code: String
      let message: String
    }
    let error: Detail
  }

  func respond(
    to request: Request, chainingTo next: any AsyncResponder
  ) async throws -> Response {
    do {
      return try await next.respond(to: request)
    } catch {
      let status: HTTPResponseStatus
      let code: String
      let message: String
      switch error {
      case let apiError as WebAPIError:
        status = apiError.status
        code = apiError.code
        message = apiError.message
      case let abort as any AbortError:
        status = abort.status
        code = "invalid_request"
        message = abort.reason
      default:
        status = .internalServerError
        code = "internal_error"
        message = error.localizedDescription
      }
      let response = Response(status: status)
      let payload = Envelope(error: .init(code: code, message: message))
      response.body = .init(data: (try? JSONEncoder().encode(payload)) ?? Data())
      response.headers.contentType = .json
      response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
      return response
    }
  }
}

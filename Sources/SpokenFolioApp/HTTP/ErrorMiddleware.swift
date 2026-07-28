import Vapor

struct OpenAIErrorMiddleware: AsyncMiddleware {
  func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
    do {
      return try await next.respond(to: request)
    } catch let error as ServiceError {
      let status: HTTPResponseStatus =
        switch error {
        case .invalidInput, .voiceNotFound: .badRequest
        case .queueFull, .rateLimited: .tooManyRequests
        case .permissionRequired, .engineUnavailable, .workerCrashed: .serviceUnavailable
        case .timeout: .gatewayTimeout
        case .synthesisFailed: .unprocessableEntity
        }
      return makeErrorResponse(
        status: status,
        message: error.message,
        type: status.code >= 500 ? "server_error" : "invalid_request_error",
        code: error.code)
    } catch let abort as AbortError {
      return makeErrorResponse(
        status: abort.status,
        message: abort.reason,
        type: "invalid_request_error",
        code: "invalid_request")
    } catch {
      request.logger.error("Unhandled request failure")
      return makeErrorResponse(
        status: .internalServerError,
        message: "Internal Server Error",
        type: "server_error",
        code: "internal_error")
    }
  }

  private func makeErrorResponse(
    status: HTTPResponseStatus,
    message: String,
    type: String,
    code: String
  ) -> Response {
    let response = Response(status: status)
    let body = OpenAIErrorResponse(
      error: OpenAIErrorDetail(message: message, type: type, param: nil, code: code))
    let data = (try? JSONEncoder().encode(body))
      ?? Data(
        "{\"error\":{\"message\":\"Internal Server Error\",\"type\":\"server_error\",\"param\":null,\"code\":\"internal_error\"}}"
          .utf8)
    response.body = .init(data: data)
    response.headers.contentType = .json
    response.headers.replaceOrAdd(name: .contentLength, value: String(data.count))
    response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
    return response
  }
}

struct RequestLoggingMiddleware: AsyncMiddleware {
  func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
    let response = try await next.respond(to: request)
    request.logger.notice("\(request.method) \(request.url.path) \(response.status.code)")
    return response
  }
}

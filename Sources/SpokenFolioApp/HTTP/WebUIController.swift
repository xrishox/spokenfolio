import Vapor

/// Serves the built WebUI bundle at `/ui` with an SPA fallback, plus the
/// `/` redirect. Never gates on engine readiness (the UI must load in
/// degraded startup) and never throws for expected misses, so the OpenAI
/// error envelope never renders where a page belongs. Hashed assets are
/// immutable-cacheable; the HTML shell is always revalidated.
struct WebUIController: RouteCollection {
  private let root: URL?

  init(root: URL? = WebUIController.bundledRoot()) {
    self.root = root
  }

  static func bundledRoot() -> URL? {
    Bundle.module.url(forResource: "dist", withExtension: nil)
  }

  func boot(routes: any RoutesBuilder) throws {
    routes.get { req -> Response in
      req.redirect(to: "/ui/", redirectType: .normal)
    }
    routes.get("ui", use: serve)
    routes.get("ui", "**", use: serve)
  }

  @Sendable func serve(req: Request) -> Response {
    guard let root else {
      return page(
        status: .notFound,
        html: "<h1>WebUI not bundled</h1><p>Build webui/ and rebuild the app.</p>")
    }
    let components = req.url.path.split(separator: "/").dropFirst().map(String.init)
    guard components.allSatisfy({ !$0.isEmpty && $0 != ".." && !$0.contains("\0") })
    else {
      return page(status: .badRequest, html: "<h1>Bad request</h1>")
    }
    var target = root
    for component in components {
      target.appendPathComponent(component)
    }
    let standardized = target.standardizedFileURL
    guard standardized.path.hasPrefix(root.standardizedFileURL.path) else {
      return page(status: .badRequest, html: "<h1>Bad request</h1>")
    }
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(
      atPath: standardized.path, isDirectory: &isDirectory)
    // SPA fallback: extensionless paths (client routes) serve the shell.
    let resolved: URL
    if exists && !isDirectory.boolValue {
      resolved = standardized
    } else if standardized.pathExtension.isEmpty {
      resolved = root.appendingPathComponent("index.html")
    } else {
      return page(status: .notFound, html: "<h1>Not found</h1>")
    }
    guard let data = try? Data(contentsOf: resolved) else {
      return page(status: .notFound, html: "<h1>Not found</h1>")
    }
    let response = Response(status: .ok, body: .init(data: data))
    response.headers.contentType = Self.mediaType(for: resolved.pathExtension)
    response.headers.replaceOrAdd(
      name: .contentLength, value: String(data.count))
    // Vite emits content-hashed filenames under assets/; everything else
    // (the shell, favicon) must revalidate so deploys take effect.
    let cache = resolved.path.contains("/assets/")
      ? "public, max-age=31536000, immutable" : "no-cache"
    response.headers.replaceOrAdd(name: .cacheControl, value: cache)
    return response
  }

  private func page(status: HTTPResponseStatus, html: String) -> Response {
    let response = Response(status: status, body: .init(string: html))
    response.headers.contentType = .html
    response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
    return response
  }

  static func mediaType(for pathExtension: String) -> HTTPMediaType {
    switch pathExtension.lowercased() {
    case "html": return .html
    case "js", "mjs": return HTTPMediaType(type: "text", subType: "javascript")
    case "css": return HTTPMediaType(type: "text", subType: "css")
    case "json", "map": return .json
    case "svg": return HTTPMediaType(type: "image", subType: "svg+xml")
    case "png": return .png
    case "ico": return HTTPMediaType(type: "image", subType: "x-icon")
    case "woff2": return HTTPMediaType(type: "font", subType: "woff2")
    case "txt": return .plainText
    default: return HTTPMediaType(type: "application", subType: "octet-stream")
    }
  }
}

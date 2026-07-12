import Foundation

/// Resolves EPUB-internal hrefs to normalized zip paths.
///
/// Every href in an OPF, nav, or NCX document is relative to the directory of
/// the document that declares it. Zip paths use forward slashes and no leading
/// slash.
enum EPUBHref {
  /// Split an href into its percent-decoded path and optional fragment,
  /// resolved against the declaring document's zip path. An empty path
  /// (`#fragment`) refers to the declaring document itself. Returns nil for
  /// external URLs (scheme present) and paths that escape the archive root.
  static func resolve(
    _ href: String, relativeTo declaringDocument: String
  ) -> (path: String, fragment: String?)? {
    let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let fragmentSplit = trimmed.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
    let rawPath = String(fragmentSplit[0])
    let fragment = fragmentSplit.count > 1 ? String(fragmentSplit[1]) : nil
    let decodedFragment = fragment?.removingPercentEncoding ?? fragment

    if rawPath.isEmpty {
      return (declaringDocument, decodedFragment)
    }
    // External references (https:, mailto:, …) are not archive members.
    if rawPath.contains(":") { return nil }

    guard let decodedPath = rawPath.removingPercentEncoding else { return nil }

    let baseDirectory = declaringDocument.contains("/")
      ? String(declaringDocument[..<declaringDocument.lastIndex(of: "/")!])
      : ""
    guard let normalized = normalize(baseDirectory: baseDirectory, path: decodedPath) else {
      return nil
    }
    return (normalized, decodedFragment)
  }

  /// Join and normalize `.`/`..` segments; nil when the path would escape the
  /// archive root.
  private static func normalize(baseDirectory: String, path: String) -> String? {
    var segments: [Substring] =
      path.hasPrefix("/") ? [] : baseDirectory.split(separator: "/")
    for segment in path.split(separator: "/") {
      switch segment {
      case ".":
        continue
      case "..":
        guard !segments.isEmpty else { return nil }
        segments.removeLast()
      default:
        segments.append(segment)
      }
    }
    guard !segments.isEmpty else { return nil }
    return segments.joined(separator: "/")
  }
}

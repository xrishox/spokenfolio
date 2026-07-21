import DocumentIOKit
import Foundation

/// Keeps stalign's chapter search away from spine documents the audiobook
/// provably never narrates.
///
/// stalign searches the concatenated transcript for every spine document's
/// text. A never-narrated apparatus document (printed TOC, endnotes,
/// copyright) has no true match, so any match it finds is a false anchor
/// inside real narration — observed displacing an entire chapter to a
/// zero-width span. When the synthesis timeline sidecar proves which
/// documents are narrated, the align stage runs against a copy whose
/// never-narrated documents have empty bodies (stalign reports them
/// "no-text" and claims nothing), and the aligned output then gets the
/// original marked-up documents restored byte-for-byte. Only stalign's
/// *search input* changes; the published EPUB text never does.
package enum AlignmentSearchNeutralizer {
  /// Spine XHTML paths in the marked-up EPUB that the audiobook does not
  /// narrate. Document paths use the same archive-resolution rules the
  /// importer used when recording `narratedDocuments`.
  package static func neutralizationTargets(
    markedup: URL, narratedDocuments: Set<String>
  ) throws -> [String] {
    let archive = try ZIPArchive(url: markedup, limits: .publication)
    return try spinePaths(in: archive).filter { path in
      !narratedDocuments.contains(path)
    }
  }

  /// Writes a copy of the marked-up EPUB in which each target document's
  /// body is empty. Everything else is byte-identical.
  package static func writeNeutralized(
    markedup: URL, targets: [String], to destination: URL
  ) throws {
    let archive = try ZIPArchive(url: markedup, limits: .publication)
    var replacements: [String: Data] = [:]
    for path in targets {
      guard let entry = archive.entry(at: path) else {
        throw ReadAloudError.invalidArtifact(
          "marked-up EPUB is missing spine document \(path)")
      }
      let document = try BoundedXMLDocument.parse(archive.data(for: entry))
      guard
        let body = try document.nodes(forXPath: "//*[local-name()='body']")
          .compactMap({ $0 as? XMLElement }).first
      else {
        throw ReadAloudError.invalidArtifact(
          "spine document \(path) has no body element")
      }
      while body.childCount > 0 { body.removeChild(at: 0) }
      replacements[path] = document.xmlData
    }
    try ZIPArchiveRewriter.rewrite(archive, replacing: replacements, to: destination)
  }

  /// Restores each target document in the aligned output from the original
  /// marked-up EPUB, byte-for-byte. Fails rather than restore if any Media
  /// Overlay references a neutralized document — that would mean the
  /// document was narrated after all and neutralization was wrong.
  package static func restore(
    targets: [String], markedup: URL, staged: URL
  ) throws {
    guard !targets.isEmpty else { return }
    let source = try ZIPArchive(url: markedup, limits: .publication)
    let aligned = try ZIPArchive(url: staged, limits: .readAloud)
    let basenames = targets.map { ($0 as NSString).lastPathComponent }
    for entry in aligned.entries where entry.path.lowercased().hasSuffix(".smil") {
      let smil = String(decoding: try aligned.data(for: entry), as: UTF8.self)
      for basename in basenames where smil.contains(basename) {
        throw ReadAloudError.invalidArtifact(
          "aligned overlay \(entry.path) references neutralized document \(basename)")
      }
    }
    var replacements: [String: Data] = [:]
    for path in targets {
      guard let original = source.entry(at: path) else {
        throw ReadAloudError.invalidArtifact(
          "marked-up EPUB is missing spine document \(path)")
      }
      guard aligned.entry(at: path) != nil else {
        throw ReadAloudError.invalidArtifact(
          "aligned EPUB is missing spine document \(path)")
      }
      replacements[path] = try source.data(for: original)
    }
    let restored = staged.deletingLastPathComponent()
      .appendingPathComponent(".\(staged.lastPathComponent).restore")
    try ZIPArchiveRewriter.rewrite(aligned, replacing: replacements, to: restored)
    _ = try FileManager.default.replaceItemAt(staged, withItemAt: restored)
  }

  /// Spine XHTML document paths from container.xml → OPF, resolved the same
  /// way the publication importer resolves them.
  static func spinePaths(in archive: ZIPArchive) throws -> [String] {
    guard let container = archive.entry(at: "META-INF/container.xml") else {
      throw ReadAloudError.invalidArtifact("EPUB container.xml is missing")
    }
    let containerDocument = try BoundedXMLDocument.parse(
      archive.data(for: container), allowTidy: false)
    guard
      let rootfile = try containerDocument.nodes(
        forXPath: "//*[local-name()='rootfile']"
      ).compactMap({ $0 as? XMLElement }).first,
      let opfPath = rootfile.attribute(forName: "full-path")?.stringValue,
      let opfEntry = archive.entry(at: opfPath)
    else { throw ReadAloudError.invalidArtifact("EPUB package document is missing") }
    let opf = try BoundedXMLDocument.parse(archive.data(for: opfEntry), allowTidy: false)
    var pathsByID: [String: String] = [:]
    for case let node as XMLElement in try opf.nodes(
      forXPath: "//*[local-name()='manifest']/*[local-name()='item']")
    {
      guard let id = node.attribute(forName: "id")?.stringValue,
        let href = node.attribute(forName: "href")?.stringValue,
        let mediaType = node.attribute(forName: "media-type")?.stringValue,
        mediaType == "application/xhtml+xml",
        let path = resolve(href, relativeTo: opfPath),
        pathsByID[id] == nil
      else { continue }
      pathsByID[id] = path
    }
    var paths: [String] = []
    for case let node as XMLElement in try opf.nodes(
      forXPath: "//*[local-name()='spine']/*[local-name()='itemref']")
    {
      guard let idref = node.attribute(forName: "idref")?.stringValue,
        let path = pathsByID[idref]
      else { continue }
      paths.append(path)
    }
    return paths
  }

  private static func resolve(_ reference: String, relativeTo document: String) -> String? {
    let raw = reference.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
    guard let first = raw.first, let decoded = String(first).removingPercentEncoding,
      !decoded.isEmpty, !decoded.hasPrefix("/"), !decoded.contains(":")
    else { return nil }
    var components = (document as NSString).deletingLastPathComponent
      .split(separator: "/").map(String.init)
    for component in decoded.split(separator: "/", omittingEmptySubsequences: true) {
      if component == "." { continue }
      if component == ".." {
        guard !components.isEmpty else { return nil }
        components.removeLast()
      } else {
        components.append(String(component))
      }
    }
    return components.joined(separator: "/").precomposedStringWithCanonicalMapping
  }
}

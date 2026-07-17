import DocumentIOKit
import Foundation

/// A parsed EPUB: metadata, reading order, table of contents, landmarks, and
/// cover, with on-demand access to member documents.
package struct EPUBBook {
  package let sourceURL: URL
  package let version: String
  package let metadata: EPUBMetadata
  package let spine: [SpineItem]
  package let toc: [TOCEntry]
  package let tocSource: TOCSource
  package let landmarks: [EPUBLandmark]
  package let cover: EPUBCover?
  package let warnings: [String]

  private let archive: ZIPArchive

  package static func load(
    url: URL, archiveLimits: ZIPArchive.Limits = .publication
  ) throws -> EPUBBook {
    let archive: ZIPArchive
    do {
      archive = try ZIPArchive(url: url, limits: archiveLimits)
    } catch {
      throw EPUBError.notAZipArchive(error.localizedDescription)
    }

    var warnings: [String] = []
    if let mimetype = archive.entry(at: "mimetype"),
      let data = try? archive.data(for: mimetype)
    {
      let value = String(decoding: data, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if value != "application/epub+zip" {
        warnings.append("mimetype entry is '\(value)', expected 'application/epub+zip'")
      }
    } else {
      warnings.append("archive has no readable mimetype entry")
    }

    guard let containerEntry = archive.entry(at: EPUBContainer.containerPath) else {
      throw EPUBError.missingContainerXML
    }
    let opfPath = try EPUBContainer.packagePath(containerXML: archive.data(for: containerEntry))
    guard let opfEntry = archive.entry(at: opfPath) else {
      throw EPUBError.missingPackageDocument(opfPath)
    }
    let opf = try OPFDocument.parse(archive.data(for: opfEntry), opfPath: opfPath)

    let navigation = EPUBNavigation.load(opf: opf) { path in
      guard let entry = archive.entry(at: path) else { throw EPUBError.missingDocument(path) }
      return try archive.data(for: entry)
    }
    if navigation.tocSource == .none {
      warnings.append("no usable table of contents (nav or NCX); using spine order")
    }

    var cover: EPUBCover?
    if let coverPath = opf.coverImagePath {
      if let entry = archive.entry(at: coverPath), let data = try? archive.data(for: entry) {
        cover = EPUBCover(data: data)
        if cover == nil {
          warnings.append("cover image '\(coverPath)' is neither JPEG nor PNG; ignoring it")
        }
      } else {
        warnings.append("cover image '\(coverPath)' is missing from the archive")
      }
    }

    return EPUBBook(
      sourceURL: url,
      version: opf.version,
      metadata: opf.metadata,
      spine: opf.spine,
      toc: navigation.toc,
      tocSource: navigation.tocSource,
      landmarks: navigation.landmarks,
      cover: cover,
      warnings: warnings,
      archive: archive)
  }

  private init(
    sourceURL: URL, version: String, metadata: EPUBMetadata, spine: [SpineItem],
    toc: [TOCEntry], tocSource: TOCSource, landmarks: [EPUBLandmark],
    cover: EPUBCover?, warnings: [String], archive: ZIPArchive
  ) {
    self.sourceURL = sourceURL
    self.version = version
    self.metadata = metadata
    self.spine = spine
    self.toc = toc
    self.tocSource = tocSource
    self.landmarks = landmarks
    self.cover = cover
    self.warnings = warnings
    self.archive = archive
  }

  package func documentData(at path: String) throws -> Data {
    guard let entry = archive.entry(at: path) else { throw EPUBError.missingDocument(path) }
    return try archive.data(for: entry)
  }

  /// Concatenated stylesheet text, bounded, for presentation-informed
  /// extraction decisions (e.g. apparatus-number detection).
  package func stylesheetCSS(maximumBytes: Int = 4 << 20) -> String {
    var total = 0
    var css = ""
    for entry in archive.entries where entry.path.lowercased().hasSuffix(".css") {
      guard total + entry.uncompressedSize <= maximumBytes,
        let data = try? archive.data(for: entry)
      else { continue }
      total += data.count
      css += String(decoding: data, as: UTF8.self) + "\n"
    }
    return css
  }
}

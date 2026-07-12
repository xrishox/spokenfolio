import Foundation

/// META-INF/container.xml → the package document (OPF) path.
enum EPUBContainer {
  static let containerPath = "META-INF/container.xml"
  static let packageMediaType = "application/oebps-package+xml"

  static func packagePath(containerXML: Data) throws -> String {
    let document: XMLDocument
    do {
      document = try XHTMLDocument.parse(containerXML)
    } catch {
      throw EPUBError.invalidContainerXML(error.localizedDescription)
    }

    let rootfiles = try? XHTMLDocument.elements(named: "rootfile", in: document)
    let candidates = (rootfiles ?? []).compactMap { element -> String? in
      guard let fullPath = element.attribute(forName: "full-path")?.stringValue,
        !fullPath.isEmpty
      else { return nil }
      let mediaType = element.attribute(forName: "media-type")?.stringValue
      return (mediaType == nil || mediaType == packageMediaType) ? fullPath : nil
    }
    guard let path = candidates.first else {
      throw EPUBError.invalidContainerXML("no rootfile with a package document path")
    }
    // container.xml paths are relative to the archive root.
    guard let resolved = EPUBHref.resolve(path, relativeTo: "")?.path else {
      throw EPUBError.invalidContainerXML("rootfile path '\(path)' is not a valid archive path")
    }
    return resolved
  }
}

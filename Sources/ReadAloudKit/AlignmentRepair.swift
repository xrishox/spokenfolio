import DocumentIOKit
import Foundation

/// Isolated re-alignment for provably-narrated documents that stalign's
/// global chapter search left without overlays.
///
/// Large duplicated passages defeat global search even with verbatim
/// transcripts: the Bible's Kings/Chronicles parallels left 2 Kings
/// "not-found" and both Chronicles zero-width while their tracks contained
/// their text verbatim at the expected offsets. The synthesis sidecar
/// proves exactly which tracks narrate which documents, so each failed
/// document gets its own alignment run — its tracks only, every other
/// spine document neutralized — where search is unambiguous. The resulting
/// overlay is grafted into the primary output; the full verifier and
/// quality audit then run on the merged artifact as usual.
package enum AlignmentRepair {
  /// Narrated spine documents whose overlay is missing or has no clips in
  /// the aligned output — the class that is otherwise a guaranteed
  /// missing-narration audit failure.
  package static func documentsMissingOverlays(
    staged: URL, narratedDocuments: Set<String>
  ) throws -> [String] {
    let archive = try ZIPArchive(url: staged, limits: .readAloud)
    let opf = try openOPF(in: archive)
    var missing: [String] = []
    for path in try AlignmentSearchNeutralizer.spinePaths(in: archive)
    where narratedDocuments.contains(path) {
      guard
        let item = try docItem(forHref: path, opf: opf.document, opfPath: opf.path)
      else { continue }
      guard let overlayID = item.attribute(forName: "media-overlay")?.stringValue,
        let smilPath = try itemHref(forID: overlayID, opf: opf.document, opfPath: opf.path),
        let smilEntry = archive.entry(at: smilPath),
        let smil = try? BoundedXMLDocument.parse(archive.data(for: smilEntry)),
        try !smil.nodes(forXPath: "//*[local-name()='par']").isEmpty
      else {
        missing.append(path)
        continue
      }
    }
    return missing
  }

  /// The audit's unnarrated-section materiality floor: a section under 250
  /// tokens with no coverage is not a missing-narration finding, so a tiny
  /// part-heading document ("The Old Testament") that global search skips
  /// is not worth an isolated repair — and often cannot anchor anyway.
  package static let materialTokenFloor = 250

  /// Approximate narratable word count of a document in the marked-up EPUB.
  package static func wordCount(of document: String, markedup: URL) throws -> Int {
    let archive = try ZIPArchive(url: markedup, limits: .publication)
    guard let entry = archive.entry(at: document),
      let parsed = try? BoundedXMLDocument.parse(archive.data(for: entry)),
      let body = try parsed.nodes(forXPath: "//*[local-name()='body']").first
    else { return 0 }
    return (body.stringValue ?? "")
      .split(whereSeparator: { $0.isWhitespace }).count
  }

  /// Documents whose overlays reference any of `audioStems`' embedded
  /// tracks. After repairing a document, any *other* overlay still claiming
  /// its tracks was misanchored there by the same duplicated text (the
  /// Ezra ≈ 2 Chronicles 36 case) and must be re-aligned in isolation too,
  /// or its clips overlap the grafted ones on the shared track.
  package static func documentsClaimingTracks(
    staged: URL, audioStems: Set<String>, excluding: Set<String>
  ) throws -> [String] {
    let archive = try ZIPArchive(url: staged, limits: .readAloud)
    let opf = try openOPF(in: archive)
    var claimants: [String] = []
    for path in try AlignmentSearchNeutralizer.spinePaths(in: archive)
    where !excluding.contains(path) {
      guard
        let item = try docItem(forHref: path, opf: opf.document, opfPath: opf.path),
        let overlayID = item.attribute(forName: "media-overlay")?.stringValue,
        let smilPath = try itemHref(forID: overlayID, opf: opf.document, opfPath: opf.path),
        let smilEntry = archive.entry(at: smilPath),
        let smil = try? BoundedXMLDocument.parse(archive.data(for: smilEntry))
      else { continue }
      for case let node as XMLElement in try smil.nodes(
        forXPath: "//*[local-name()='audio']")
      {
        guard let src = node.attribute(forName: "src")?.stringValue else { continue }
        let stem = ((src.split(separator: "#").first.map(String.init) ?? src) as NSString)
          .lastPathComponent.replacingOccurrences(of: ".mp4", with: "")
        if audioStems.contains(stem) {
          claimants.append(path)
          break
        }
      }
    }
    return claimants
  }

  /// The processed-track stems (sorted order) whose chapters narrate `document`.
  package static func trackStems(
    narrating document: String, chapterSourceDocuments: [[String]], stems: [String]
  ) -> [String] {
    guard chapterSourceDocuments.count == stems.count else { return [] }
    return zip(stems, chapterSourceDocuments)
      .filter { $0.1.contains(document) }
      .map(\.0)
  }

  /// Grafts `document`'s overlay from an isolated repair output into the
  /// primary aligned EPUB: the SMIL (replacing an empty one if present),
  /// any audio tracks the primary run did not embed, the manifest items,
  /// the `media-overlay` attribute, and the per-overlay and total
  /// `media:duration` metadata.
  package static func graft(
    document: String, from repairEPUB: URL, into staged: URL
  ) throws {
    let repair = try ZIPArchive(url: repairEPUB, limits: .readAloud)
    let primary = try ZIPArchive(url: staged, limits: .readAloud)
    let repairOPF = try openOPF(in: repair)

    guard
      let repairItem = try docItem(
        forHref: document, opf: repairOPF.document, opfPath: repairOPF.path),
      let overlayID = repairItem.attribute(forName: "media-overlay")?.stringValue,
      let smilPath = try itemHref(
        forID: overlayID, opf: repairOPF.document, opfPath: repairOPF.path),
      let smilEntry = repair.entry(at: smilPath)
    else {
      throw ReadAloudError.invalidArtifact(
        "repair alignment produced no overlay for \(document)")
    }
    let smilData = try repair.data(for: smilEntry)
    let smil = try BoundedXMLDocument.parse(smilData)
    guard try !smil.nodes(forXPath: "//*[local-name()='par']").isEmpty else {
      throw ReadAloudError.invalidArtifact(
        "repair alignment produced an empty overlay for \(document)")
    }
    guard
      let durationMeta = try metaDuration(
        refines: overlayID, opf: repairOPF.document)
    else {
      throw ReadAloudError.invalidArtifact(
        "repair alignment recorded no duration for \(document)")
    }

    // Audio entries the repair overlay references but the primary run did
    // not embed (it drops tracks it could not align).
    var additions: [String: Data] = [:]
    var replacements: [String: Data] = [:]
    for case let node as XMLElement in try smil.nodes(
      forXPath: "//*[local-name()='audio']")
    {
      guard let src = node.attribute(forName: "src")?.stringValue,
        let audioPath = resolve(src, relativeTo: smilPath)
      else { continue }
      if primary.entry(at: audioPath) == nil, additions[audioPath] == nil {
        guard let audioEntry = repair.entry(at: audioPath) else {
          throw ReadAloudError.invalidArtifact(
            "repair overlay references missing audio \(audioPath)")
        }
        additions[audioPath] = try repair.data(for: audioEntry)
      }
    }
    if primary.entry(at: smilPath) == nil {
      additions[smilPath] = smilData
    } else {
      replacements[smilPath] = smilData
    }

    // Patch the primary OPF.
    let primaryOPF = try openOPF(in: primary)
    guard
      let manifest = try primaryOPF.document.nodes(
        forXPath: "//*[local-name()='manifest']"
      ).compactMap({ $0 as? XMLElement }).first,
      let metadata = try primaryOPF.document.nodes(
        forXPath: "//*[local-name()='metadata']"
      ).compactMap({ $0 as? XMLElement }).first,
      let primaryItem = try docItem(
        forHref: document, opf: primaryOPF.document, opfPath: primaryOPF.path)
    else {
      throw ReadAloudError.invalidArtifact("aligned EPUB has no usable package document")
    }
    primaryItem.removeAttribute(forName: "media-overlay")
    primaryItem.addAttribute(attribute("media-overlay", overlayID))

    if try itemHref(forID: overlayID, opf: primaryOPF.document, opfPath: primaryOPF.path)
      == nil
    {
      let smilItem = XMLElement(name: "item")
      smilItem.addAttribute(attribute("id", overlayID))
      smilItem.addAttribute(
        attribute("href", relativeHref(of: smilPath, to: primaryOPF.path)))
      smilItem.addAttribute(attribute("media-type", "application/smil+xml"))
      manifest.addChild(smilItem)
    }
    for (audioPath, _) in additions where audioPath.lowercased().hasSuffix(".mp4") {
      let audioItem = XMLElement(name: "item")
      audioItem.addAttribute(
        attribute("id", "audio_" + ((audioPath as NSString).lastPathComponent
          .replacingOccurrences(of: ".mp4", with: ""))))
      audioItem.addAttribute(
        attribute("href", relativeHref(of: audioPath, to: primaryOPF.path)))
      audioItem.addAttribute(attribute("media-type", "audio/mp4"))
      manifest.addChild(audioItem)
    }

    // Per-overlay duration: replace a stale value or append a new meta.
    var replacedMeta = false
    for case let node as XMLElement in try primaryOPF.document.nodes(
      forXPath: "//*[local-name()='meta'][@refines='#\(overlayID)']")
    {
      node.setChildren([XMLNode.text(withStringValue: durationMeta) as! XMLNode])
      replacedMeta = true
    }
    if !replacedMeta {
      let meta = XMLElement(name: "meta", stringValue: durationMeta)
      meta.addAttribute(attribute("property", "media:duration"))
      meta.addAttribute(attribute("refines", "#\(overlayID)"))
      metadata.addChild(meta)
    }
    // Total duration = sum of every per-overlay duration after the patch.
    var total = 0.0
    for case let node as XMLElement in try primaryOPF.document.nodes(
      forXPath: "//*[local-name()='meta'][@property='media:duration'][@refines]")
    {
      total += clockSeconds(node.stringValue ?? "") ?? 0
    }
    for case let node as XMLElement in try primaryOPF.document.nodes(
      forXPath: "//*[local-name()='meta'][@property='media:duration'][not(@refines)]")
    {
      node.setChildren([XMLNode.text(withStringValue: clockString(total)) as! XMLNode])
    }
    replacements[primaryOPF.path] = primaryOPF.document.xmlData

    let merged = staged.deletingLastPathComponent()
      .appendingPathComponent(".\(staged.lastPathComponent).graft")
    try ZIPArchiveRewriter.rewrite(
      primary, replacing: replacements, adding: additions, to: merged)
    _ = try FileManager.default.replaceItemAt(staged, withItemAt: merged)
  }

  /// Removes degenerate zero-length clips stalign occasionally emits (a
  /// sentence collapsed to `clipBegin == clipEnd`). Such a clip can never
  /// highlight anything, and the verifier rightly rejects it as invalid;
  /// dropping its par leaves the sentence overlay-less, which is legal —
  /// the quality audit still judges the resulting coverage. Applies to
  /// every engine: ASR runs hit the same stalign behavior.
  package static func sanitizeDegenerateClips(staged: URL) throws {
    let archive = try ZIPArchive(url: staged, limits: .readAloud)
    var replacements: [String: Data] = [:]
    for entry in archive.entries where entry.path.lowercased().hasSuffix(".smil") {
      let smil = try BoundedXMLDocument.parse(archive.data(for: entry))
      var changed = false
      for case let audio as XMLElement in try smil.nodes(
        forXPath: "//*[local-name()='audio']")
      {
        guard let beginText = audio.attribute(forName: "clipBegin")?.stringValue,
          let endText = audio.attribute(forName: "clipEnd")?.stringValue,
          let begin = clockSeconds(clipValue(beginText)),
          let end = clockSeconds(clipValue(endText)),
          end <= begin,
          let par = audio.parent as? XMLElement,
          let seq = par.parent as? XMLElement,
          let index = par.index as Int?
        else { continue }
        seq.removeChild(at: index)
        changed = true
      }
      if changed { replacements[entry.path] = smil.xmlData }
    }
    guard !replacements.isEmpty else { return }
    let sanitized = staged.deletingLastPathComponent()
      .appendingPathComponent(".\(staged.lastPathComponent).sanitize")
    try ZIPArchiveRewriter.rewrite(archive, replacing: replacements, to: sanitized)
    _ = try FileManager.default.replaceItemAt(staged, withItemAt: sanitized)
  }

  /// SMIL clip values carry an "s" suffix ("99.793s") or clock syntax.
  private static func clipValue(_ text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.hasSuffix("s") && !trimmed.hasSuffix("ms")
      ? String(trimmed.dropLast()) : trimmed
  }

  // MARK: - Package-document helpers

  private static func openOPF(
    in archive: ZIPArchive
  ) throws -> (document: XMLDocument, path: String) {
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
    return (
      try BoundedXMLDocument.parse(archive.data(for: opfEntry), allowTidy: false),
      opfPath
    )
  }

  private static func docItem(
    forHref path: String, opf: XMLDocument, opfPath: String
  ) throws -> XMLElement? {
    for case let node as XMLElement in try opf.nodes(
      forXPath: "//*[local-name()='manifest']/*[local-name()='item']")
    {
      guard let href = node.attribute(forName: "href")?.stringValue else { continue }
      if resolve(href, relativeTo: opfPath) == path { return node }
    }
    return nil
  }

  private static func itemHref(
    forID id: String, opf: XMLDocument, opfPath: String
  ) throws -> String? {
    for case let node as XMLElement in try opf.nodes(
      forXPath: "//*[local-name()='manifest']/*[local-name()='item'][@id='\(id)']")
    {
      guard let href = node.attribute(forName: "href")?.stringValue else { continue }
      return resolve(href, relativeTo: opfPath)
    }
    return nil
  }

  private static func metaDuration(
    refines overlayID: String, opf: XMLDocument
  ) throws -> String? {
    for case let node as XMLElement in try opf.nodes(
      forXPath: "//*[local-name()='meta'][@refines='#\(overlayID)']")
    {
      let value = (node.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      if !value.isEmpty { return value }
    }
    return nil
  }

  private static func attribute(_ name: String, _ value: String) -> XMLNode {
    XMLNode.attribute(withName: name, stringValue: value) as! XMLNode
  }

  /// The OPF's hrefs are relative to its own directory.
  private static func relativeHref(of path: String, to opfPath: String) -> String {
    let base = (opfPath as NSString).deletingLastPathComponent
    if base.isEmpty { return path }
    if path.hasPrefix(base + "/") { return String(path.dropFirst(base.count + 1)) }
    let ups = base.split(separator: "/").map { _ in ".." }.joined(separator: "/")
    return ups + "/" + path
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

  private static func clockSeconds(_ source: String) -> Double? {
    let parts = source.trimmingCharacters(in: .whitespacesAndNewlines)
      .split(separator: ":", omittingEmptySubsequences: false)
    guard !parts.isEmpty, parts.count <= 3, parts.allSatisfy({ Double($0) != nil })
    else { return nil }
    let value = parts.reduce(0.0) { $0 * 60 + (Double($1) ?? 0) }
    return value.isFinite ? value : nil
  }

  private static func clockString(_ seconds: Double) -> String {
    let total = max(0, seconds)
    let hours = Int(total) / 3_600
    let minutes = (Int(total) % 3_600) / 60
    let secs = total - Double(hours * 3_600 + minutes * 60)
    return String(format: "%02d:%02d:%05.2f", hours, minutes, secs)
  }
}

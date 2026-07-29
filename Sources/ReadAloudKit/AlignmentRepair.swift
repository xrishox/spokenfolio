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

  /// Every nonempty document that the synthesis sidecar proves was narrated
  /// must remain eligible for isolated repair. Even a one-word part heading
  /// owns a processed audio track; skipping it makes stalign omit that track
  /// from the EPUB and invalidates the transcript/audio binding.
  package static func shouldAttemptIsolatedRepair(wordCount: Int) -> Bool {
    wordCount > 0
  }

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

  /// Builds a repair EPUB for the narrow case where stalign refuses a short
  /// document even in isolation. This is available only to the
  /// synthesis-timeline path: one exact transcript segment must match one
  /// marked-up XHTML fragment after case, punctuation, and markup-boundary
  /// whitespace are removed. No fuzzy search or character-proportional
  /// timing is permitted.
  package static func writeExactSingleFragmentRepair(
    document: String, markedup: URL, audio: URL, transcript: URL, to output: URL
  ) throws {
    let source = try ZIPArchive(url: markedup, limits: .readAloud)
    let package = try openOPF(in: source)
    guard let documentEntry = source.entry(at: document),
      let documentItem = try docItem(
        forHref: document, opf: package.document, opfPath: package.path),
      let manifest = try package.document.nodes(
        forXPath: "//*[local-name()='manifest']"
      ).compactMap({ $0 as? XMLElement }).first,
      let metadata = try package.document.nodes(
        forXPath: "//*[local-name()='metadata']"
      ).compactMap({ $0 as? XMLElement }).first
    else {
      throw ReadAloudError.invalidArtifact(
        "exact repair has no usable narrated document")
    }
    let value = try StalignTranscriptValidator.decode(transcript)
    guard value.timeline.count == 1, let timing = value.timeline.first,
      timing.startTime.isFinite, timing.endTime.isFinite,
      timing.startTime >= 0, timing.endTime > timing.startTime
    else {
      throw ReadAloudError.invalidArtifact(
        "exact repair requires one bounded transcript segment")
    }
    let xhtml = try BoundedXMLDocument.parse(
      source.data(for: documentEntry), allowTidy: false)
    let expected = normalizedText(value.transcript)
    let candidates = try xhtml.nodes(forXPath: "//*[@id]")
      .compactMap { $0 as? XMLElement }
      .filter { normalizedText($0.stringValue ?? "") == expected }
    guard expected.isEmpty == false, candidates.count == 1,
      let fragmentID = candidates[0].attribute(forName: "id")?.stringValue,
      !fragmentID.isEmpty, fragmentID.utf8.count <= 1_024
    else {
      throw ReadAloudError.invalidArtifact(
        "exact repair could not identify one transcript-matching XHTML fragment")
    }
    // stalign's sentence wrapper can contain <br/> elements whose XML
    // string value concatenates the words on either side. Preserve the
    // visual line break and formatting tree, but add a text-space after
    // each break so identity/timing verification tokenizes it the same way
    // as the exact synthesis transcript.
    let descendants = try candidates[0].nodes(forXPath: ".//*")
      .compactMap { $0 as? XMLElement }
    guard descendants.allSatisfy({ $0.localName?.lowercased() == "br" }) else {
      throw ReadAloudError.invalidArtifact(
        "exact repair transcript match contains unsupported inline markup")
    }
    for lineBreak in descendants.reversed() {
      guard let parent = lineBreak.parent as? XMLElement else {
        throw ReadAloudError.invalidArtifact("exact repair markup is detached")
      }
      parent.insertChild(
        XMLNode.text(withStringValue: " ") as! XMLNode,
        at: lineBreak.index + 1)
    }
    guard normalizedWhitespace(candidates[0].stringValue ?? "")
      == normalizedWhitespace(value.transcript)
    else {
      throw ReadAloudError.invalidArtifact(
        "exact repair could not restore transcript-matching XHTML text")
    }
    let audioValues = try audio.resourceValues(forKeys: [
      .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
    ])
    guard audioValues.isRegularFile == true, audioValues.isSymbolicLink != true,
      let audioSize = audioValues.fileSize, audioSize > 0, audioSize <= 512 << 20
    else {
      throw ReadAloudError.invalidArtifact("exact repair audio is not a bounded regular file")
    }

    let documentDirectory = (document as NSString).deletingLastPathComponent
    let documentName = (document as NSString).lastPathComponent
    let documentStem = (documentName as NSString).deletingPathExtension
    let audioName = audio.lastPathComponent
    let audioStem = (audioName as NSString).deletingPathExtension
    guard !documentStem.isEmpty, !audioStem.isEmpty,
      documentName.utf8.count <= 1_024, audioName.utf8.count <= 1_024
    else { throw ReadAloudError.invalidArtifact("exact repair paths are invalid") }
    let directoryPrefix = documentDirectory.isEmpty ? "" : "\(documentDirectory)/"
    let smilPath = "\(directoryPrefix)MediaOverlays/\(documentStem).smil"
    let audioPath = "\(directoryPrefix)Audio/\(audioName)"
    let overlayID = "\(documentStem).xhtml_overlay"
    let audioID = "audio_\(audioStem)"
    guard source.entry(at: smilPath) == nil, source.entry(at: audioPath) == nil,
      try itemHref(forID: overlayID, opf: package.document, opfPath: package.path) == nil,
      try itemHref(forID: audioID, opf: package.document, opfPath: package.path) == nil
    else { throw ReadAloudError.invalidArtifact("exact repair paths collide with the EPUB") }

    let smil = XMLDocument(rootElement: XMLElement(name: "smil"))
    guard let smilRoot = smil.rootElement() else {
      throw ReadAloudError.invalidArtifact("exact repair could not create SMIL")
    }
    smilRoot.addAttribute(attribute("xmlns", "http://www.w3.org/ns/SMIL"))
    smilRoot.addAttribute(attribute("xmlns:epub", "http://www.idpf.org/2007/ops"))
    smilRoot.addAttribute(attribute("version", "3.0"))
    let body = XMLElement(name: "body")
    let sequence = XMLElement(name: "seq")
    sequence.addAttribute(attribute("id", overlayID))
    sequence.addAttribute(attribute("epub:textref", "../\(documentName)"))
    let par = XMLElement(name: "par")
    par.addAttribute(attribute("id", "\(documentStem)-exact-0"))
    let text = XMLElement(name: "text")
    text.addAttribute(attribute("src", "../\(documentName)#\(fragmentID)"))
    let audioNode = XMLElement(name: "audio")
    audioNode.addAttribute(attribute("src", "../Audio/\(audioName)"))
    audioNode.addAttribute(attribute("clipBegin", secondsString(timing.startTime)))
    audioNode.addAttribute(attribute("clipEnd", secondsString(timing.endTime)))
    par.addChild(text)
    par.addChild(audioNode)
    sequence.addChild(par)
    body.addChild(sequence)
    smilRoot.addChild(body)

    documentItem.removeAttribute(forName: "media-overlay")
    documentItem.addAttribute(attribute("media-overlay", overlayID))
    let smilItem = XMLElement(name: "item")
    smilItem.addAttribute(attribute("id", overlayID))
    smilItem.addAttribute(
      attribute("href", relativeHref(of: smilPath, to: package.path)))
    smilItem.addAttribute(attribute("media-type", "application/smil+xml"))
    manifest.addChild(smilItem)
    let audioItem = XMLElement(name: "item")
    audioItem.addAttribute(attribute("id", audioID))
    audioItem.addAttribute(
      attribute("href", relativeHref(of: audioPath, to: package.path)))
    audioItem.addAttribute(attribute("media-type", "audio/mp4"))
    manifest.addChild(audioItem)

    let duration = timing.endTime - timing.startTime
    let durationMeta = XMLElement(name: "meta", stringValue: clockString(duration))
    durationMeta.addAttribute(attribute("property", "media:duration"))
    durationMeta.addAttribute(attribute("refines", "#\(overlayID)"))
    metadata.addChild(durationMeta)
    var total = duration
    for case let node as XMLElement in try package.document.nodes(
      forXPath: "//*[local-name()='meta'][@property='media:duration'][@refines]"
    ) where node !== durationMeta {
      total += clockSeconds(node.stringValue ?? "") ?? 0
    }
    let totals = try package.document.nodes(
      forXPath: "//*[local-name()='meta'][@property='media:duration'][not(@refines)]"
    ).compactMap { $0 as? XMLElement }
    if totals.isEmpty {
      let totalMeta = XMLElement(name: "meta", stringValue: clockString(total))
      totalMeta.addAttribute(attribute("property", "media:duration"))
      metadata.addChild(totalMeta)
    } else {
      for totalMeta in totals {
        totalMeta.setChildren([XMLNode.text(withStringValue: clockString(total)) as! XMLNode])
      }
    }
    try ZIPArchiveRewriter.rewrite(
      source, replacing: [
        package.path: package.document.xmlData,
        document: xhtml.xmlData,
      ],
      adding: [
        smilPath: smil.xmlData,
        audioPath: try Data(contentsOf: audio, options: [.mappedIfSafe]),
      ], to: output)
  }

  /// Grafts `document`'s overlay from an isolated repair output into the
  /// primary aligned EPUB: the SMIL (replacing an empty one if present),
  /// any audio tracks the primary run did not embed, the manifest items,
  /// the `media-overlay` attribute, and the per-overlay and total
  /// `media:duration` metadata.
  package static func graft(
    document: String, from repairEPUB: URL, into staged: URL,
    replaceDocument: Bool = false
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
    if replaceDocument {
      guard let repairedDocument = repair.entry(at: document),
        primary.entry(at: document) != nil
      else {
        throw ReadAloudError.invalidArtifact(
          "exact repair document is absent from the EPUB")
      }
      replacements[document] = try repair.data(for: repairedDocument)
    }
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

  private static func secondsString(_ seconds: Double) -> String {
    String(format: "%.3fs", seconds)
  }

  private static func normalizedText(_ value: String) -> String {
    String(
      value.precomposedStringWithCanonicalMapping.lowercased().unicodeScalars.filter {
        CharacterSet.alphanumerics.contains($0)
      })
  }

  private static func normalizedWhitespace(_ value: String) -> String {
    value.precomposedStringWithCanonicalMapping
      .split(whereSeparator: { $0.isWhitespace })
      .joined(separator: " ")
  }
}

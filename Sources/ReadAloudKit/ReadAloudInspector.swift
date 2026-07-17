import DocumentIOKit
import EPUBKit
import Foundation
import PublicationKit

package struct ReadAloudClip: Sendable, Equatable {
  package var documentPath: String
  package var fragmentID: String
  package var text: String
  package var audioPath: String
  package var begin: Double
  package var end: Double
  package var primary: Bool
}

package struct ReadAloudAudioMember: Sendable {
  package var path: String
  package var mediaType: String
  package var entry: ZIPEntry
}

package struct ReadAloudSectionCoverage: Sendable, Equatable {
  package var path: String
  package var title: String
  package var role: SectionRole
  package var primary: Bool
  package var totalTokens: Int
  package var coveredTokens: Int
  package var largestUncoveredRunTokens: Int = 0
}

package struct ReadAloudInspection: Sendable {
  package var archive: ZIPArchive
  package var title: String
  package var language: String?
  package var clips: [ReadAloudClip]
  package var audio: [ReadAloudAudioMember]
  package var sections: [ReadAloudSectionCoverage]
  package var narrativeText: String
  package var metrics: ReadAloudAuditMetrics
  package var findings: [ReadAloudAuditFinding]
}

package enum ReadAloudInspector {
  private static let maximumFragments = 500_000
  private static let maximumClips = 250_000
  // Contiguous uncovered narrative of this size means a passage was never
  // narrated or aligned; a skipped chapter measures in the thousands, while
  // markup-interrupted sentences stay well under one hundred tokens.
  private static let brokenOmissionRunTokens = 800
  private struct ManifestItem {
    var id: String
    var path: String
    var mediaType: String
    var mediaOverlay: String?
  }

  package static func inspect(_ epub: URL) throws -> ReadAloudInspection {
    let archive = try ZIPArchive(url: epub, limits: .readAloud)
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
    var manifest: [String: ManifestItem] = [:]
    var manifestByPath: [String: ManifestItem] = [:]
    for case let node as XMLElement in try opf.nodes(
      forXPath: "//*[local-name()='manifest']/*[local-name()='item']")
    {
      guard let id = node.attribute(forName: "id")?.stringValue,
        let href = node.attribute(forName: "href")?.stringValue,
        let path = resolve(href, relativeTo: opfPath)
      else { continue }
      let item = ManifestItem(
        id: id, path: path,
        mediaType: node.attribute(forName: "media-type")?.stringValue ?? "",
        mediaOverlay: node.attribute(forName: "media-overlay")?.stringValue)
      guard manifest[id] == nil, manifestByPath[path] == nil else {
        throw ReadAloudError.invalidArtifact("EPUB manifest contains duplicate identities")
      }
      manifest[id] = item
      manifestByPath[path] = item
    }

    var spineItems: [ManifestItem] = []
    for case let node as XMLElement in try opf.nodes(
      forXPath: "//*[local-name()='spine']/*[local-name()='itemref']")
    {
      guard let idref = node.attribute(forName: "idref")?.stringValue,
        let item = manifest[idref]
      else { throw ReadAloudError.invalidArtifact("EPUB spine references a missing manifest item") }
      spineItems.append(item)
    }
    guard !spineItems.isEmpty else { throw ReadAloudError.invalidArtifact("EPUB spine is empty") }

    let publication = try EPUBImporter().load(url: epub, archiveLimits: .readAloud)
    var publicationSections: [String: PublicationSection] = [:]
    for section in publication.sections {
      let fallback =
        spineItems.indices.contains(section.index) ? spineItems[section.index].path : nil
      guard let path = section.blocks.first?.locator.documentID ?? fallback,
        publicationSections[path] == nil
      else { continue }
      publicationSections[path] = section
    }
    var fragmentText: [String: [String: String]] = [:]
    var totalFragments = 0
    var sectionCoverage: [String: ReadAloudSectionCoverage] = [:]
    var findings: [ReadAloudAuditFinding] = []

    for item in spineItems {
      let section = publicationSections[item.path]
      let role = section?.role ?? .unknown
      let primary = section?.readingOrder == .primary && isPrimary(role: role)
      let total = section?.blocks.reduce(0) { $0 + tokens($1.text).count } ?? 0
      sectionCoverage[item.path] = ReadAloudSectionCoverage(
        path: item.path, title: section?.title ?? item.path, role: role,
        primary: primary, totalTokens: total, coveredTokens: 0)
      guard let entry = archive.entry(at: item.path) else {
        findings.append(
          finding(
            .structure, .missingManifestReference, .broken, .confirmed,
            "A spine document is missing from the EPUB.", document: item.path))
        continue
      }
      do {
        let document = try BoundedXMLDocument.parse(archive.data(for: entry))
        var values: [String: String] = [:]
        let identifierNodes = try document.nodes(forXPath: "//*[@id]")
        let (nextTotal, overflow) = totalFragments.addingReportingOverflow(identifierNodes.count)
        guard !overflow, nextTotal <= maximumFragments else {
          throw ZIPError.archiveContentsTooLarge(totalUncompressedSize: nextTotal)
        }
        totalFragments = nextTotal
        for case let element as XMLElement in identifierNodes {
          guard let id = element.attribute(forName: "id")?.stringValue, !id.isEmpty else {
            continue
          }
          let value = normalizedText(element.stringValue ?? "")
          if values[id] == nil { values[id] = value }
        }
        fragmentText[item.path] = values
      } catch let error as ZIPError {
        throw error
      } catch {
        findings.append(
          finding(
            .structure, .missingTextFragment, .broken, .confirmed,
            "A spine document cannot be parsed safely.", document: item.path))
      }
    }

    let linkedSMILIDs = spineItems.compactMap(\.mediaOverlay)
    var linkedSMILPaths: [String] = []
    for id in linkedSMILIDs {
      guard let smil = manifest[id] else {
        findings.append(
          finding(
            .structure, .missingManifestReference, .broken, .confirmed,
            "A media-overlay relationship points to a missing manifest item."))
        continue
      }
      linkedSMILPaths.append(smil.path)
    }
    let manifestedSMIL = manifest.values.filter {
      $0.mediaType == "application/smil+xml" || $0.path.lowercased().hasSuffix(".smil")
    }
    for item in manifestedSMIL where !linkedSMILPaths.contains(item.path) {
      findings.append(
        finding(
          .structure, .orphanMedia, .needsReview, .tentative,
          "A manifested SMIL document is not linked from the reading order.",
          document: item.path))
    }

    var clips: [ReadAloudClip] = []
    var referencedAudioPaths = Set<String>()
    var coveredFragments = Set<String>()
    var lastEndByAudio: [String: Double] = [:]
    for smilPath in linkedSMILPaths {
      guard let entry = archive.entry(at: smilPath) else {
        findings.append(
          finding(
            .structure, .missingManifestReference, .broken, .confirmed,
            "A linked SMIL document is missing.", document: smilPath))
        continue
      }
      let document: XMLDocument
      do {
        document = try BoundedXMLDocument.parse(
          archive.data(for: entry),
          limits: .init(
            maximumInputBytes: 16 << 20, maximumTidyInputBytes: 0,
            maximumDepth: 128, maximumNodes: 200_000,
            maximumAttributes: 500_000, maximumTextBytes: 16 << 20),
          allowTidy: false)
      } catch {
        findings.append(
          finding(
            .structure, .missingManifestReference, .broken, .confirmed,
            "A linked SMIL document is invalid XML.", document: smilPath))
        continue
      }
      let pars = try document.nodes(forXPath: "//*[local-name()='par']").compactMap {
        $0 as? XMLElement
      }
      let (prospectiveClips, clipOverflow) = clips.count.addingReportingOverflow(pars.count)
      guard !clipOverflow, prospectiveClips <= maximumClips else {
        throw ZIPError.archiveContentsTooLarge(totalUncompressedSize: prospectiveClips)
      }
      if pars.isEmpty {
        findings.append(
          finding(
            .coverage, .emptyOverlay, .needsReview, .confirmed,
            "A spine-linked Media Overlay contains no clips.", document: smilPath))
      }
      for par in pars {
        let children = par.children?.compactMap { $0 as? XMLElement } ?? []
        guard let textNode = children.first(where: { $0.localName == "text" }),
          let audioNode = children.first(where: { $0.localName == "audio" }),
          let textSource = textNode.attribute(forName: "src")?.stringValue,
          let audioSource = audioNode.attribute(forName: "src")?.stringValue,
          let textPath = resolve(textSource, relativeTo: smilPath),
          let fragment = fragment(textSource),
          let audioPath = resolve(audioSource, relativeTo: smilPath)
        else {
          findings.append(
            finding(
              .structure, .missingManifestReference, .broken, .confirmed,
              "A SMIL clip does not contain resolvable text and audio references.",
              document: smilPath))
          continue
        }
        guard archive.entry(at: audioPath) != nil else {
          findings.append(
            finding(
              .structure, .missingAudio, .broken, .confirmed,
              "A SMIL clip references missing audio.", document: textPath,
              fragment: fragment, audio: audioPath))
          continue
        }
        guard let text = fragmentText[textPath]?[fragment] else {
          findings.append(
            finding(
              .structure, .missingTextFragment, .broken, .confirmed,
              "A SMIL clip references a missing XHTML fragment.", document: textPath,
              fragment: fragment, audio: audioPath))
          continue
        }
        guard let beginValue = audioNode.attribute(forName: "clipBegin")?.stringValue,
          let endValue = audioNode.attribute(forName: "clipEnd")?.stringValue,
          let begin = clockSeconds(beginValue), let end = clockSeconds(endValue)
        else {
          findings.append(
            finding(
              .structure, .invalidClipClock, .broken, .confirmed,
              "A SMIL clip has an invalid clock value.", document: textPath,
              fragment: fragment, audio: audioPath))
          continue
        }
        if !begin.isFinite || !end.isFinite || begin < 0 || end <= begin {
          findings.append(
            finding(
              .structure, .invertedClipInterval, .broken, .confirmed,
              "A SMIL clip ends before it begins.", document: textPath,
              fragment: fragment, audio: audioPath, begin: begin, end: end))
          continue
        }
        if let previous = lastEndByAudio[audioPath], begin + 0.001 < previous {
          findings.append(
            finding(
              .structure, .overlappingClip, .broken, .confirmed,
              "SMIL clips move backward or overlap on the same audio track.",
              document: textPath, fragment: fragment, audio: audioPath,
              begin: begin, end: end))
        }
        lastEndByAudio[audioPath] = max(lastEndByAudio[audioPath] ?? 0, end)
        referencedAudioPaths.insert(audioPath)
        coveredFragments.insert("\(textPath)#\(fragment)")
        clips.append(
          ReadAloudClip(
            documentPath: textPath, fragmentID: fragment, text: text,
            audioPath: audioPath, begin: begin, end: end,
            primary: sectionCoverage[textPath]?.primary ?? true))
      }
    }

    for key in coveredFragments {
      let parts = key.split(separator: "#", maxSplits: 1).map(String.init)
      guard parts.count == 2, let text = fragmentText[parts[0]]?[parts[1]],
        var section = sectionCoverage[parts[0]]
      else { continue }
      section.coveredTokens += tokens(text).count
      sectionCoverage[parts[0]] = section
    }

    var audio: [ReadAloudAudioMember] = []
    for path in referencedAudioPaths.sorted() {
      guard let entry = archive.entry(at: path) else { continue }
      audio.append(
        ReadAloudAudioMember(
          path: path, mediaType: manifestByPath[path]?.mediaType ?? "", entry: entry))
    }
    let manifestedAudio = manifest.values.filter {
      $0.mediaType.lowercased().hasPrefix("audio/") || isAudioPath($0.path)
    }
    for item in manifestedAudio where !referencedAudioPaths.contains(item.path) {
      findings.append(
        finding(
          .structure, .orphanMedia, .needsReview, .tentative,
          "Manifested audio is not referenced by a linked Media Overlay.",
          audio: item.path))
    }
    if linkedSMILPaths.isEmpty || audio.isEmpty || clips.isEmpty {
      findings.append(
        finding(
          .structure, .noFunctionalOverlay, .broken, .confirmed,
          "The EPUB has no functional Media Overlay and embedded-audio pair."))
    }

    let spineOrder = Dictionary(
      uniqueKeysWithValues: spineItems.enumerated().map { ($0.element.path, $0.offset) })
    var sections = sectionCoverage.values.sorted {
      (spineOrder[$0.path] ?? Int.max) < (spineOrder[$1.path] ?? Int.max)
    }
    // Clamp covered counts because malformed nested target markup can repeat
    // text. Coverage must never exceed the extracted narrative denominator.
    for index in sections.indices {
      sections[index].coveredTokens = min(
        sections[index].totalTokens, sections[index].coveredTokens)
    }
    // Aligners legitimately leave sentences that inline markup interrupts
    // (noterefs, italicized phrases, drop caps) without overlay fragments, so
    // healthy note-heavy books show 20%+ scattered token omission (measured:
    // A Conflict of Visions, 21% omitted, every gap under ~50 tokens).
    // Narration that never reached the overlay instead appears as one long
    // contiguous uncovered run, so broken-coverage findings measure runs in
    // document order rather than scattered totals.
    var coveredByDocument: [String: Set<String>] = [:]
    for key in coveredFragments {
      let parts = key.split(separator: "#", maxSplits: 1).map(String.init)
      guard parts.count == 2 else { continue }
      coveredByDocument[parts[0], default: []].insert(parts[1])
    }
    for index in sections.indices
    where sections[index].primary && sections[index].totalTokens > 0 {
      guard let entry = archive.entry(at: sections[index].path),
        let document = try? BoundedXMLDocument.parse(archive.data(for: entry))
      else { continue }
      sections[index].largestUncoveredRunTokens = largestUncoveredRun(
        in: document, covered: coveredByDocument[sections[index].path] ?? [])
    }
    let primaryTotal = sections.filter(\.primary).reduce(0) { $0 + $1.totalTokens }
    let primaryCovered = sections.filter(\.primary).reduce(0) { $0 + $1.coveredTokens }
    let largestOmission =
      sections.filter(\.primary).map { max(0, $0.totalTokens - $0.coveredTokens) }.max() ?? 0
    let largestOmissionRun =
      sections.filter(\.primary).map(\.largestUncoveredRunTokens).max() ?? 0
    let coverage = primaryTotal > 0 ? Double(primaryCovered) / Double(primaryTotal) : nil
    for section in sections where section.primary {
      let omitted = max(0, section.totalTokens - section.coveredTokens)
      let relative = primaryTotal > 0 ? Double(omitted) / Double(primaryTotal) : 0
      let unnarrated = section.coveredTokens == 0 && section.totalTokens >= 250
      if unnarrated || section.largestUncoveredRunTokens >= brokenOmissionRunTokens {
        findings.append(
          finding(
            .coverage, .missingPrimaryNarration, .likelyBroken, .strong,
            "A substantial primary-narrative passage has no aligned narration.",
            document: section.path,
            metrics: [
              "omittedTokens": Double(omitted),
              "largestUncoveredRunTokens": Double(section.largestUncoveredRunTokens),
              "publicationFraction": relative,
            ]))
      }
    }
    if let coverage, coverage < 0.95, largestOmissionRun < brokenOmissionRunTokens {
      findings.append(
        finding(
          .coverage, .missingPrimaryNarration, .needsReview, .tentative,
          "Primary narrative coverage is below the automatic-pass threshold.",
          metrics: [
            "primaryCoverage": coverage,
            "largestUncoveredRunTokens": Double(largestOmissionRun),
          ]))
    }

    var metrics = ReadAloudAuditMetrics()
    metrics.entryCount = archive.entries.count
    metrics.spineCount = spineItems.count
    metrics.smilCount = linkedSMILPaths.count
    metrics.audioCount = audio.count
    metrics.clipCount = clips.count
    metrics.primaryTokenCount = primaryTotal
    metrics.coveredPrimaryTokenCount = primaryCovered
    metrics.primaryCoverage = coverage
    metrics.largestPrimaryOmissionTokens = largestOmission
    metrics.largestPrimaryOmissionRunTokens = largestOmissionRun
    return ReadAloudInspection(
      archive: archive, title: publication.metadata.title,
      language: publication.metadata.language, clips: clips, audio: audio,
      sections: sections,
      narrativeText: publication.sections.filter { section in
        section.readingOrder == .primary && isPrimary(role: section.role)
      }.flatMap(\.blocks).map(\.text).joined(separator: "\n"),
      metrics: metrics, findings: findings)
  }

  private static func isPrimary(role: SectionRole) -> Bool {
    ![
      .cover, .titlePage, .copyright, .printedTOC, .notes, .bibliography,
      .index, .aboutAuthor, .alsoBy, .excerpt, .promotional,
    ].contains(role)
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

  private static func fragment(_ reference: String) -> String? {
    let parts = reference.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2 else { return nil }
    return String(parts[1]).removingPercentEncoding?.precomposedStringWithCanonicalMapping
  }

  private static func clockSeconds(_ source: String) -> Double? {
    let value = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    func finite(_ value: Double?) -> Double? {
      guard let value, value.isFinite else { return nil }
      return value
    }
    if value.hasSuffix("ms") { return finite(Double(value.dropLast(2))).map { $0 / 1_000 } }
    if value.hasSuffix("min") { return finite(Double(value.dropLast(3))).map { $0 * 60 } }
    if value.hasSuffix("h") { return finite(Double(value.dropLast())).map { $0 * 3_600 } }
    if value.hasSuffix("s") { return finite(Double(value.dropLast())) }
    let parts = value.split(separator: ":", omittingEmptySubsequences: false)
    guard !parts.isEmpty, parts.count <= 3, parts.allSatisfy({ Double($0) != nil }) else {
      return nil
    }
    return finite(parts.reduce(0.0) { $0 * 60 + (Double($1) ?? 0) })
  }

  /// Largest run of consecutive narrative tokens that no SMIL-referenced
  /// fragment covers, measured in document order across block boundaries so a
  /// skipped passage is one long run regardless of paragraph structure.
  private static func largestUncoveredRun(
    in document: XMLDocument, covered: Set<String>
  ) -> Int {
    var largest = 0
    var current = 0
    func walk(_ node: XMLNode, coveredAncestor: Bool) {
      if let element = node as? XMLElement {
        let name = (element.localName ?? element.name ?? "").lowercased()
        if name == "head" || name == "script" || name == "style" { return }
        let isCovered =
          coveredAncestor
            || element.attribute(forName: "id")?.stringValue.map(covered.contains) == true
        for child in element.children ?? [] { walk(child, coveredAncestor: isCovered) }
        return
      }
      if node.kind == .text {
        let count = tokens(node.stringValue ?? "").count
        guard count > 0 else { return }
        if coveredAncestor {
          largest = max(largest, current)
          current = 0
        } else {
          current += count
        }
        return
      }
      for child in node.children ?? [] { walk(child, coveredAncestor: coveredAncestor) }
    }
    walk(document, coveredAncestor: false)
    return max(largest, current)
  }

  private static func tokens(_ value: String) -> [String] {
    value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
      .map(String.init)
  }

  private static func normalizedText(_ value: String) -> String {
    value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }

  private static func isAudioPath(_ path: String) -> Bool {
    ["mp4", "m4a", "m4b", "mp3", "ogg", "opus", "aac", "wav"]
      .contains(URL(fileURLWithPath: path).pathExtension.lowercased())
  }

  private static func finding(
    _ dimension: ReadAloudAuditDimension, _ code: ReadAloudFindingCode,
    _ verdict: ReadAloudAuditVerdict, _ confidence: ReadAloudAuditConfidence,
    _ summary: String, document: String? = nil, fragment: String? = nil,
    audio: String? = nil, begin: Double? = nil, end: Double? = nil,
    metrics: [String: Double] = [:]
  ) -> ReadAloudAuditFinding {
    ReadAloudAuditFinding(
      dimension: dimension, code: code, verdict: verdict, confidence: confidence,
      summary: summary, documentPath: document, fragmentID: fragment,
      audioPath: audio, clipBegin: begin, clipEnd: end, metrics: metrics)
  }
}

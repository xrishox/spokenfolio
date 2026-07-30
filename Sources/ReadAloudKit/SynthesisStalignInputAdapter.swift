import DocumentIOKit
import Foundation

/// Re-expresses exact synthesis units in the sentence vocabulary the
/// installed, unmodified stalign executable consumes.
///
/// stalign first marks the pristine source using its own current segmenter.
/// This adapter then neutralizes sentence terminators inside every exact TTS
/// unit in a disposable copy and applies the identical substitutions to the
/// timeline transcript. A second normal stalign markup/align pass therefore
/// sees one source sentence per exact timing entry. After alignment the
/// substitutions are reversed; stalign's IDs and SMIL are never rewritten.
package enum SynthesisStalignInputAdapter {
  package static let version = 3

  private static let substitutions: [Character: Character] = [
    ".": "\u{E000}", "!": "\u{E001}", "?": "\u{E002}", "…": "\u{E003}",
  ]
  /// `Intl.Segmenter`, which stalign uses, treats a paragraph separator as a
  /// hard sentence boundary even when the authored sentence has no
  /// punctuation there. It exists only in the disposable input and is
  /// removed after stalign completes.
  private static let forcedBoundary: Character = "\u{2029}"
  private static let restorations = Dictionary(
    uniqueKeysWithValues: substitutions.map { ($0.value, $0.key) })

  private struct RawCharacter {
    var node: Int
    var offset: Int
    var span: Int
    var value: Character
  }

  package static func prepare(
    baselineMarkedup: URL, transcriptions: URL, sidecar: URL, to output: URL
  ) throws {
    let timeline = try JSONDecoder().decode(
      SynthesisTimelineTranscriber.Sidecar.self,
      from: Data(contentsOf: sidecar, options: [.mappedIfSafe]))
    guard timeline.schemaVersion == 3 else {
      throw ReadAloudError.invalidArtifact(
        "synthesis timeline lacks stalign input provenance; rebuild the audiobook")
    }
    let transcriptFiles = try regularFiles(in: transcriptions, extension: "json")
    let chapters = timeline.chapters.sorted { $0.index < $1.index }
    guard transcriptFiles.count == chapters.count else {
      throw ReadAloudError.invalidArtifact(
        "synthesis tracks do not match chapters during stalign input adaptation")
    }

    struct IndexedSegment {
      var chapter: Int
      var index: Int
      var value: SynthesisTimelineTranscriber.Sidecar.Segment
    }
    var byDocument: [String: [IndexedSegment]] = [:]
    var adaptedTexts: [[String]] = chapters.map { chapter in
      (chapter.segments ?? []).filter {
        $0.kind != "speechlessSilence" && $0.sourceLocator != nil
      }.map(\.text)
    }
    for (chapterIndex, chapter) in chapters.enumerated() {
      let segments = (chapter.segments ?? []).filter {
        $0.kind != "speechlessSilence" && $0.sourceLocator != nil
      }
      for (index, segment) in segments.enumerated() {
        guard let document = segment.sourceLocator?.documentID else { continue }
        byDocument[document, default: []].append(
          IndexedSegment(chapter: chapterIndex, index: index, value: segment))
      }
    }

    let archive = try ZIPArchive(url: baselineMarkedup, limits: .readAloud)
    var replacements: [String: Data] = [:]
    for (document, segments) in byDocument {
      guard let entry = archive.entry(at: document) else {
        throw ReadAloudError.invalidArtifact(
          "stalign markup omitted narrated document \(document)")
      }
      let parsed = try BoundedXMLDocument.parse(
        archive.data(for: entry), allowTidy: false)
      let spans = try parsed.nodes(forXPath: "//*[local-name()='span'][@id]")
        .compactMap { $0 as? XMLElement }
        .filter {
          guard let id = $0.attribute(forName: "id")?.stringValue,
            let marker = id.range(of: "-s", options: .backwards)
          else { return false }
          return !id[marker.upperBound...].isEmpty
            && id[marker.upperBound...].allSatisfy(\.isNumber)
        }
      guard !spans.isEmpty else {
        throw ReadAloudError.invalidArtifact(
          "stalign produced no sentence markers for narrated document \(document)")
      }
      if containsAdapterScalar(parsed.stringValue ?? "") {
        throw ReadAloudError.invalidArtifact(
          "source publication uses reserved stalign adapter characters")
      }

      var nodes: [XMLNode] = []
      var raw: [RawCharacter] = []
      var canonicalText: [Character] = []
      var canonicalToRaw: [Int] = []
      for (spanIndex, span) in spans.enumerated() {
        var spanNodes: [XMLNode] = []
        collectTextNodes(span, into: &spanNodes)
        for node in spanNodes {
          let nodeIndex = nodes.count
          nodes.append(node)
          for (offset, character) in (node.stringValue ?? "").enumerated() {
            let rawIndex = raw.count
            raw.append(
              RawCharacter(
                node: nodeIndex, offset: offset, span: spanIndex, value: character))
            for canonicalCharacter in canonicalCharacters(character) {
              canonicalText.append(canonicalCharacter)
              canonicalToRaw.append(rawIndex)
            }
          }
        }
      }

      var canonicalCursor = 0
      var substitutionsByNode: [Int: Set<Int>] = [:]
      var boundariesByNode: [Int: Set<Int>] = [:]
      for segment in segments {
        let target = Array(canonical(segment.value.text))
        guard !target.isEmpty else { continue }
        guard let found = firstRange(
          of: target, in: canonicalText, startingAt: canonicalCursor)
        else {
          throw ReadAloudError.invalidArtifact(
            "stalign could not locate a synthesis unit in \(document)")
        }
        canonicalCursor = found.upperBound
        let firstRaw = canonicalToRaw[found.lowerBound]
        let lastRaw = canonicalToRaw[found.upperBound - 1]
        let unitEndRaw = trailingNonAlphanumericEnd(after: lastRaw, in: raw)
        let spanRange = raw[firstRaw].span...raw[lastRaw].span

        // Preserve the terminator ending this exact unit, but neutralize every
        // earlier terminator so stalign cannot split one TTS request into
        // several sentences.
        let terminators = (firstRaw...unitEndRaw).filter {
          substitutions[raw[$0].value] != nil
        }
        for rawIndex in terminators.dropLast() {
          substitutionsByNode[raw[rawIndex].node, default: []]
            .insert(raw[rawIndex].offset)
        }

        // If an exact TTS unit starts or ends inside a sentence produced by
        // this installed stalign, force a boundary in the disposable source.
        // This also supports future word-sized or otherwise arbitrary units.
        if let preceding = precedingAlphanumeric(
          before: firstRaw, in: raw, constrainedTo: spanRange.lowerBound),
          raw[preceding].span == raw[firstRaw].span
        {
          boundariesByNode[raw[firstRaw].node, default: []]
            .insert(raw[firstRaw].offset)
        }
        if let following = followingAlphanumeric(
          after: lastRaw, in: raw, constrainedTo: spanRange.upperBound),
          raw[following].span == raw[lastRaw].span
        {
          boundariesByNode[raw[following].node, default: []]
            .insert(raw[following].offset)
        }

        adaptedTexts[segment.chapter][segment.index] =
          neutralizingInternalTerminators(in: segment.value.text)
      }
      apply(
        nodes: nodes, substitutions: substitutionsByNode,
        forcedBoundaries: boundariesByNode)
      unwrapSentenceMarkers(spans)
      replacements[document] = parsed.xmlData
    }
    try ZIPArchiveRewriter.rewrite(archive, replacing: replacements, to: output)

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    for (chapterIndex, transcriptURL) in transcriptFiles.enumerated() {
      let value = try StalignTranscriptValidator.decode(transcriptURL)
      guard value.timeline.count == adaptedTexts[chapterIndex].count else {
        throw ReadAloudError.invalidArtifact(
          "synthesis transcript entry count changed during stalign adaptation")
      }
      let entries = zip(value.timeline, adaptedTexts[chapterIndex]).map { entry, text in
        StalignTimelineEntry(
          type: text.contains(" ") ? "segment" : "word", text: text,
          startTime: entry.startTime, endTime: entry.endTime, confidence: entry.confidence)
      }
      try encoder.encode(StalignTranscript(timedEntries: entries))
        .write(to: transcriptURL, options: .atomic)
    }
  }

  /// Reverses only the private-use substitutions in XHTML and transcripts.
  /// SMIL and package data are copied byte-for-byte from stalign's output.
  package static func restore(
    aligned: URL, to output: URL
  ) throws {
    let archive = try ZIPArchive(url: aligned, limits: .readAloud)
    var replacements: [String: Data] = [:]
    for entry in archive.entries
    where ["xhtml", "html", "htm"].contains(
      (entry.path as NSString).pathExtension.lowercased())
    {
      let data = try archive.data(for: entry)
      guard let text = String(data: data, encoding: .utf8), containsAdapterScalar(text)
      else { continue }
      let restored = restoringTerminators(in: text)
      guard !containsAdapterScalar(restored) else {
        throw ReadAloudError.invalidArtifact(
          "stalign adapter characters remained in \(entry.path)")
      }
      replacements[entry.path] = Data(restored.utf8)
    }
    try ZIPArchiveRewriter.rewrite(archive, replacing: replacements, to: output)
  }

  private static func neutralizeInternalTerminators(in elements: [XMLElement]) {
    var nodes: [XMLNode] = []
    for element in elements {
      collectTextNodes(element, into: &nodes)
    }
    var occurrences: [(node: Int, character: Int)] = []
    for (nodeIndex, node) in nodes.enumerated() {
      for (characterIndex, character) in (node.stringValue ?? "").enumerated()
      where substitutions[character] != nil {
        occurrences.append((nodeIndex, characterIndex))
      }
    }
    guard occurrences.count > 1 else { return }
    let preserve = occurrences.last!
    for (nodeIndex, node) in nodes.enumerated() {
      var value = Array(node.stringValue ?? "")
      for index in value.indices where substitutions[value[index]] != nil {
        if nodeIndex != preserve.node || index != preserve.character {
          value[index] = substitutions[value[index]]!
        }
      }
      node.stringValue = String(value)
    }
  }

  private static func collectTextNodes(_ node: XMLNode, into result: inout [XMLNode]) {
    if node.kind == .text {
      result.append(node)
      return
    }
    for child in node.children ?? [] { collectTextNodes(child, into: &result) }
  }

  /// The baseline markup is an observation pass, not input markup for the
  /// real alignment. Leaving its wrappers in place makes the second stock
  /// `markup` pass nest new sentence spans inside stale ones, after which
  /// SMIL can target only part of a synthesis unit.
  private static func unwrapSentenceMarkers(_ spans: [XMLElement]) {
    for span in spans.reversed() {
      guard let parent = span.parent as? XMLElement else { continue }
      let insertionIndex = span.index
      let children = span.children ?? []
      for child in children { child.detach() }
      span.detach()
      for (offset, child) in children.enumerated() {
        parent.insertChild(child, at: insertionIndex + offset)
      }
    }
  }

  private static func neutralizingInternalTerminators(in text: String) -> String {
    var value = Array(text)
    let occurrences = value.indices.filter { substitutions[value[$0]] != nil }
    guard occurrences.count > 1, let preserve = occurrences.last else { return text }
    for index in occurrences where index != preserve {
      value[index] = substitutions[value[index]]!
    }
    return String(value)
  }

  private static func restoringTerminators(in text: String) -> String {
    String(text.compactMap {
      if $0 == forcedBoundary { return nil }
      return restorations[$0] ?? $0
    })
  }

  private static func containsAdapterScalar(_ text: String) -> Bool {
    text.contains { $0 == forcedBoundary || restorations[$0] != nil }
  }

  private static func canonical(_ text: String) -> String {
    text.decomposedStringWithCompatibilityMapping.lowercased()
      .unicodeScalars.filter {
        CharacterSet.alphanumerics.contains($0)
      }.map(String.init).joined()
  }

  private static func canonicalCharacters(_ character: Character) -> [Character] {
    Array(canonical(String(character)))
  }

  private static func firstRange(
    of needle: [Character], in haystack: [Character], startingAt start: Int
  ) -> Range<Int>? {
    guard !needle.isEmpty, start <= haystack.count,
      needle.count <= haystack.count - start
    else { return nil }
    let lastStart = haystack.count - needle.count
    guard start <= lastStart else { return nil }
    for candidate in start...lastStart
    where haystack[candidate..<(candidate + needle.count)].elementsEqual(needle) {
      return candidate..<(candidate + needle.count)
    }
    return nil
  }

  private static func precedingAlphanumeric(
    before index: Int, in raw: [RawCharacter], constrainedTo span: Int
  ) -> Int? {
    guard index > 0 else { return nil }
    for candidate in stride(from: index - 1, through: 0, by: -1) {
      guard raw[candidate].span == span else { return nil }
      if !canonicalCharacters(raw[candidate].value).isEmpty { return candidate }
    }
    return nil
  }

  private static func followingAlphanumeric(
    after index: Int, in raw: [RawCharacter], constrainedTo span: Int
  ) -> Int? {
    guard index + 1 < raw.count else { return nil }
    for candidate in (index + 1)..<raw.count {
      guard raw[candidate].span == span else { return nil }
      if !canonicalCharacters(raw[candidate].value).isEmpty { return candidate }
    }
    return nil
  }

  private static func trailingNonAlphanumericEnd(
    after index: Int, in raw: [RawCharacter]
  ) -> Int {
    var end = index
    guard index + 1 < raw.count else { return end }
    for candidate in (index + 1)..<raw.count {
      guard raw[candidate].span == raw[index].span,
        canonicalCharacters(raw[candidate].value).isEmpty
      else { break }
      end = candidate
    }
    return end
  }

  private static func apply(
    nodes: [XMLNode], substitutions: [Int: Set<Int>],
    forcedBoundaries: [Int: Set<Int>]
  ) {
    for (nodeIndex, node) in nodes.enumerated() {
      let replace = substitutions[nodeIndex] ?? []
      let boundaries = forcedBoundaries[nodeIndex] ?? []
      guard !replace.isEmpty || !boundaries.isEmpty else { continue }
      var result: [Character] = []
      for (offset, character) in (node.stringValue ?? "").enumerated() {
        if boundaries.contains(offset) { result.append(forcedBoundary) }
        result.append(replace.contains(offset) ? Self.substitutions[character]! : character)
      }
      node.stringValue = String(result)
    }
  }

  private static func regularFiles(in directory: URL, extension ext: String) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      .filter {
        guard $0.pathExtension.lowercased() == ext,
          let values = try? $0.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey,
          ])
        else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
      }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
  }
}

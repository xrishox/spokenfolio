import Foundation
import PublicationKit

struct ClassifiedEPUBSection {
  let item: SpineItem
  let extraction: ExtractedDocument?
  let role: SectionRole
  let title: String
}

/// Classifies every spine item into a SectionRole using, in priority order:
/// landmarks/guide semantics, notes-only content detection, TOC-title
/// keywords, filename keywords. Unmatched items stay `.unknown`, which the
/// default policy includes (fail-open).
enum SectionClassifier {
  private struct TOCSignal {
    let title: String
    let inheritedExclusion: SectionRole?
  }

  static func classify(
    book: EPUBBook,
    extractions: [Int: ExtractedDocument]
  ) -> [ClassifiedEPUBSection] {
    let tocByPath = tocSignalsByPath(book.toc)
    let landmarkRoles = landmarkRolesByPath(book.landmarks)
    // A TOC-anchored excerpt/marketing document owns the unanchored spine
    // documents that follow it, until the next TOC-anchored document. Bonus
    // excerpts routinely anchor only their title page while the excerpt's
    // prose lives in follow-on files with no TOC entry (measured: A Crown of
    // Swords anchors "Excerpt: The Path of Daggers" on the title page and
    // ships the excerpt's 12k-word prologue unanchored behind it). Chapter
    // planning already drops that range; classifying it identically keeps
    // narration expectations consistent for every consumer.
    // Cross-file noteref inbound density: a spine file that many dropped
    // noterefs point INTO is the book's note apparatus by construction
    // (NRSVue ships each biblical book's translator notes as a separate
    // unanchored file receiving hundreds of Tier-1 noterefs).
    var inboundNoterefs: [String: Int] = [:]
    var inboundMarkerLinks: [String: Int] = [:]
    for extraction in extractions.values {
      for file in extraction.noterefTargetFiles {
        inboundNoterefs[file, default: 0] += 1
      }
      for file in extraction.markerLinkTargetFiles {
        inboundMarkerLinks[file, default: 0] += 1
      }
    }
    var owningExclusion: SectionRole?
    return book.spine.map { item in
      let extraction = extractions[item.index]
      let tocSignal = tocByPath[item.path]
      let tocTitle = tocSignal?.title
      let basename = String(item.path.split(separator: "/").last ?? "")
      let role = role(for: item, tocTitle: tocTitle,
                      inboundNoterefs: inboundNoterefs[basename] ?? 0,
                      inboundMarkerLinks: inboundMarkerLinks[basename] ?? 0,
                      inheritedTOCExclusion: tocSignal?.inheritedExclusion,
                      spineOwnedExclusion: tocSignal == nil ? owningExclusion : nil,
                      landmarkRoles: landmarkRoles,
                      extraction: extraction)
      if tocSignal != nil {
        owningExclusion =
          role == .excerpt || role == .promotional || role == .alsoBy ? role : nil
      }
      let title = tocTitle ?? extraction?.firstHeading ?? defaultTitle(for: role, item: item)
      return ClassifiedEPUBSection(
        item: item, extraction: extraction, role: role, title: title)
    }
  }

  // MARK: - Signals

  private static let landmarkRoleMap: [String: SectionRole] = [
    "cover": .cover,
    "buy the book": .promotional,
    "connect on social media": .promotional,
    "connect with us": .promotional,
    "discover your next read": .promotional,
    "stay connected": .promotional,
    "titlepage": .titlePage,
    "title-page": .titlePage,
    "copyright-page": .copyright,
    "imprint": .copyright,
    "colophon": .copyright,
    "toc": .printedTOC,
    "index": .index,
    "footnotes": .notes,
    "endnotes": .notes,
    "rearnotes": .notes,
    "dedication": .dedication,
    "epigraph": .epigraph,
    "acknowledgments": .acknowledgments,
    "acknowledgements": .acknowledgments,
    "foreword": .foreword,
    "preface": .preface,
    "prologue": .prologue,
    "epilogue": .epilogue,
    "afterword": .afterword,
    "appendix": .appendix,
    "glossary": .glossary,
    "bibliography": .bibliography,
  ]

  /// Whole-title matches for words that are too common to trust as
  /// substrings — "Notes from Underground" must stay a chapter.
  private static let exactTitleRoles: [String: SectionRole] = [
    "title page": .titlePage,
    "copyright": .copyright,
    "copyright page": .copyright,
    "copyright notice": .copyright,
    "colophon": .copyright,
    "imprint": .copyright,
    "contents": .printedTOC,
    "table of contents": .printedTOC,
    "notes": .notes,
    "footnotes": .notes,
    "endnotes": .notes,
    "translator's notes": .notes,
    "translator’s notes": .notes,
    "works cited": .bibliography,
    "index": .index,
    "name index": .index,
    "subject index": .index,
    "author index": .index,
    "general index": .index,
    "cover": .cover,
  ]

  /// Prefix matches for section names that take subtitles ("Appendix A",
  /// "Acknowledgments and Thanks").
  private static let prefixTitleRoles: [(String, SectionRole)] = [
    ("dedication", .dedication),
    ("epigraph", .epigraph),
    ("acknowledgment", .acknowledgments),
    ("acknowledgement", .acknowledgments),
    ("foreword", .foreword),
    ("preface", .preface),
    ("prologue", .prologue),
    ("epilogue", .epilogue),
    ("afterword", .afterword),
    ("appendix", .appendix),
    ("glossary", .glossary),
    ("bibliography", .bibliography),
    ("index of ", .index),
    ("excerpt", .excerpt),
    ("sample chapter", .excerpt),
    ("read an excerpt", .excerpt),
    ("read a sample", .excerpt),
    ("preview chapter", .excerpt),
  ]

  /// Substring matches only for phrases unambiguous anywhere in a title.
  private static let containsTitleRoles: [(String, SectionRole)] = [
    ("about the author", .aboutAuthor),
    ("about the translator", .aboutAuthor),
    ("meet the author", .aboutAuthor),
    ("also by", .alsoBy),
    ("books by", .alsoBy),
    ("praise for", .alsoBy),
    ("excerpt from", .excerpt),
    ("preview of", .excerpt),
    ("sneak peek", .excerpt),
    ("sneak preview", .excerpt),
    ("buy the book", .promotional),
    ("connect on social media", .promotional),
  ]

  private static let filenameKeywordRoles: [(SectionRole, [String])] = [
    (.copyright, ["copyright", "colophon"]),
    (.titlePage, ["titlepage", "title-page", "title_page"]),
    (.printedTOC, ["contents"]),
    (.notes, ["footnote", "endnote", "rearnote"]),
    (.aboutAuthor, ["aboutauthor", "abouttheauthor", "about-the-author"]),
    (.dedication, ["dedication"]),
    (.acknowledgments, ["acknowledg"]),
    (.prologue, ["prologue"]),
    (.epilogue, ["epilogue"]),
    (.epigraph, ["epigraph"]),
    (.index, ["index"]),
    (.cover, ["cover"]),
    (.promotional, ["next-reads", "nextreads", "newsletter"]),
  ]

  nonisolated(unsafe) private static let partTitle = /^(part|book|volume)\b/.ignoresCase()

  private static func role(
    for item: SpineItem,
    tocTitle: String?,
    inboundNoterefs: Int = 0,
    inboundMarkerLinks: Int = 0,
    inheritedTOCExclusion: SectionRole?,
    spineOwnedExclusion: SectionRole?,
    landmarkRoles: [String: SectionRole],
    extraction: ExtractedDocument?
  ) -> SectionRole {
    if let landmarkRole = landmarkRoles[item.path] { return landmarkRole }
    if let extraction, extraction.isNotesOnly { return .notes }
    if let inheritedTOCExclusion { return inheritedTOCExclusion }

    if let tocTitle {
      let lowered = tocTitle.lowercased().trimmingCharacters(in: .whitespaces)
      if lowered.hasPrefix("chapter") || lowered.firstMatch(of: /^\d+[.:]?(\s|$)/) != nil {
        return .chapter
      }
      if lowered.firstMatch(of: partTitle) != nil { return .part }
      if let exact = exactTitleRoles[lowered] { return exact }
      for (prefix, role) in prefixTitleRoles where lowered.hasPrefix(prefix) { return role }
      for (phrase, role) in containsTitleRoles where lowered.contains(phrase) { return role }
      return .chapter
    }

    if let spineOwnedExclusion { return spineOwnedExclusion }

    let filename = (item.path.split(separator: "/").last ?? "").lowercased()
    for (role, keywords) in filenameKeywordRoles
    where keywords.contains(where: { filenameSignal($0, matches: filename) })
      && corroboratesFilenameRole(role, extraction: extraction)
    {
      return role
    }
    if inboundNoterefs >= minimumInboundNoterefs { return .notes }
    // Marker-shaped inbound links are attribute-free evidence (needed when
    // stalign's markup strips epub:type), but note back-links and index
    // page links share the shape, so they flip a file only when the file's
    // own content reads as a note list. Sapiens chapters receive hundreds
    // of digit-text links from the index and note files and must not flip.
    if inboundNoterefs + inboundMarkerLinks >= minimumInboundNoterefs,
      let extraction, isNoteListShaped(extraction)
    { return .notes }
    if let extraction, isStructurallyIndex(extraction) { return .index }
    if let extraction, isStructurallyPrintedTOC(extraction) { return .printedTOC }
    return .unknown
  }

  /// Printed tables of contents that reach here are spine-unanchored with
  /// meaningless filenames (War and Peace ships "Contents" as an untitled
  /// trailing file), so structure is the only signal: a document dominated
  /// by short structural-label lines ("CHAPTER XII", "BOOK ONE: 1805").
  /// Narrating one reads hundreds of chapter labels aloud, and no aligner
  /// can anchor the duplicated titles. Poetry cannot match (verse lines do
  /// not start with structural labels) and numbered aphorism books cannot
  /// (their numeral blocks are interleaved with long prose, failing the
  /// fraction test). Prose fails open as always.
  nonisolated(unsafe) private static let tocLabelLine =
    /(?i)^(?:(?:first|second|third)\s+)?(?:chapter|book|part|volume|act|scene|epilogue|prologue|appendix|section|canto|stave)\b.{0,50}$|^[IVXLCDM]{1,7}\.?$/
  private static let minimumTOCLines = 20

  private static func isStructurallyPrintedTOC(_ extraction: ExtractedDocument) -> Bool {
    let blocks = extraction.blocks
    guard blocks.count >= minimumTOCLines else { return false }
    let labelish = blocks.count {
      $0.text.count <= 60 && $0.text.wholeMatch(of: tocLabelLine) != nil
    }
    return labelish >= minimumTOCLines && Double(labelish) >= 0.5 * Double(blocks.count)
  }

  /// Index files that reach here have no TOC title at all (publishers ship
  /// them as unanchored trailing spine items), so structure is the only
  /// signal: a document dominated by short entry lines that end in page
  /// number runs. Calibrated on the 175-book corpus: real narrated indexes
  /// score 57–69% with hundreds of entries; the strongest non-index
  /// document scores 41% with 13 entries, so both thresholds hold a wide
  /// margin. Prose fails open as always.
  nonisolated(unsafe) private static let indexEntry =
    /^.{1,70}?[,.]?\s(?:\d{1,4}[,–\-]\s?)+\d{1,4}\.?$/
  /// A file this many dropped noterefs point into, with no TOC title of
  /// its own, holds note apparatus — no prose file accumulates twenty
  /// cross-file note references.
  private static let minimumInboundNoterefs = 20

  /// Note lists open each entry with its marker: an ascending number
  /// ("299. …", "[12] …"), a note symbol, or the NRSVue single-letter
  /// style ("a Or gods" — lowercase letter, then a capitalized note).
  /// Prose paragraphs start with capitalized words, so a majority of
  /// marker-opened blocks over a real sample separates the two cleanly.
  nonisolated(unsafe) private static let noteEntryStart =
    /^(?:\[?\d{1,4}\]?\s?[.):]?|[*†‡§¶]+|[a-z][.):]?)\s+[\p{Lu}0-9(\[“"']/
  private static let minimumNoteListEntries = 10

  private static func isNoteListShaped(_ extraction: ExtractedDocument) -> Bool {
    let blocks = extraction.blocks
    guard blocks.count >= minimumNoteListEntries else { return false }
    let markerish = blocks.count { $0.text.firstMatch(of: noteEntryStart) != nil }
    return markerish >= minimumNoteListEntries
      && Double(markerish) >= 0.5 * Double(blocks.count)
  }

  private static let minimumIndexEntries = 30
  private static let minimumIndexFraction = 0.5

  private static func isStructurallyIndex(_ extraction: ExtractedDocument) -> Bool {
    let blocks = extraction.blocks
    guard blocks.count >= minimumIndexEntries else { return false }
    let entries = blocks.count { $0.text.wholeMatch(of: indexEntry) != nil }
    return entries >= minimumIndexEntries
      && Double(entries) >= minimumIndexFraction * Double(blocks.count)
  }

  private static func filenameSignal(_ keyword: String, matches filename: String) -> Bool {
    let stem = (filename as NSString).deletingPathExtension
    let tokens = stem.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
      .map { String($0) }
    return tokens.contains(keyword) || tokens.joined().contains(keyword)
  }

  /// Filenames are weak publisher-controlled hints. They may support an
  /// exclusion only when the extracted document itself supplies a matching
  /// heading or note-only structure; otherwise prose fails open.
  private static func corroboratesFilenameRole(
    _ role: SectionRole, extraction: ExtractedDocument?
  ) -> Bool {
    guard let extraction else { return false }
    if role == .notes, extraction.isNotesOnly { return true }
    guard let heading = extraction.firstHeading?.lowercased() else { return false }
    if let exact = exactTitleRoles[heading] { return exact == role }
    if prefixTitleRoles.contains(where: { heading.hasPrefix($0.0) && $0.1 == role }) {
      return true
    }
    return containsTitleRoles.contains(where: { heading.contains($0.0) && $0.1 == role })
  }

  private static func tocSignalsByPath(_ toc: [TOCEntry]) -> [String: TOCSignal] {
    var result: [String: TOCSignal] = [:]
    func walk(_ entry: TOCEntry, inherited: SectionRole?) {
      let ownScope = exclusionScope(for: entry.title) ?? inherited
      // A fragment-scoped TOC entry describes a boundary inside a document,
      // not the semantic role of the entire spine item. It remains available
      // to chapter planning through Publication.navigation.
      if entry.fragment == nil, result[entry.path] == nil {
        result[entry.path] = TOCSignal(
          title: entry.title,
          inheritedExclusion: inherited)
      }
      for child in entry.children { walk(child, inherited: ownScope) }
    }
    for entry in toc { walk(entry, inherited: nil) }
    return result
  }

  /// Only categories whose child entries are predictably part of the same
  /// back-matter product inherit. Structural labels such as Contents or
  /// Copyright must never suppress unrelated descendants in malformed TOCs.
  private static func exclusionScope(for title: String) -> SectionRole? {
    let lowered = title.lowercased().trimmingCharacters(in: .whitespaces)
    if let exact = exactTitleRoles[lowered], exact == .promotional { return exact }
    for (prefix, role) in prefixTitleRoles
    where lowered.hasPrefix(prefix) && (role == .excerpt || role == .promotional || role == .alsoBy)
    { return role }
    for (phrase, role) in containsTitleRoles
    where lowered.contains(phrase) && (role == .excerpt || role == .promotional || role == .alsoBy)
    { return role }
    return nil
  }

  private static func landmarkRolesByPath(_ landmarks: [EPUBLandmark]) -> [String: SectionRole] {
    var result: [String: SectionRole] = [:]
    for landmark in landmarks {
      // Fragment-only landmarks identify a location, never the role of every
      // block sharing the XHTML resource.
      guard landmark.fragment == nil,
        let role = landmarkRoleMap[landmark.epubType], result[landmark.path] == nil
      else {
        continue
      }
      result[landmark.path] = role
    }
    return result
  }

  private static func defaultTitle(for role: SectionRole, item: SpineItem) -> String {
    switch role {
    case .unknown, .chapter: "Section \(item.index + 1)"
    default: role.rawValue.replacingOccurrences(of: "-", with: " ").capitalized
    }
  }

}

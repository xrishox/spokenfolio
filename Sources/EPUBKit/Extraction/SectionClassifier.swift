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
    return book.spine.map { item in
      let extraction = extractions[item.index]
      let tocSignal = tocByPath[item.path]
      let tocTitle = tocSignal?.title
      let role = role(for: item, tocTitle: tocTitle,
                      inheritedTOCExclusion: tocSignal?.inheritedExclusion,
                      landmarkRoles: landmarkRoles,
                      extraction: extraction)
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
    "works cited": .bibliography,
    "index": .index,
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
    inheritedTOCExclusion: SectionRole?,
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

    let filename = (item.path.split(separator: "/").last ?? "").lowercased()
    for (role, keywords) in filenameKeywordRoles
    where keywords.contains(where: { filename.contains($0) }) {
      return role
    }
    return .unknown
  }

  private static func tocSignalsByPath(_ toc: [TOCEntry]) -> [String: TOCSignal] {
    var result: [String: TOCSignal] = [:]
    func walk(_ entry: TOCEntry, inherited: SectionRole?) {
      let ownScope = exclusionScope(for: entry.title) ?? inherited
      if result[entry.path] == nil {
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
      guard let role = landmarkRoleMap[landmark.epubType], result[landmark.path] == nil else {
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

import Foundation

/// Classifies every spine item into a SectionRole using, in priority order:
/// landmarks/guide semantics, notes-only content detection, TOC-title
/// keywords, filename keywords. Unmatched items stay `.unknown`, which the
/// default policy includes (fail-open).
enum SectionClassifier {
  static func classify(
    book: EPUBBook,
    extractions: [Int: ExtractedDocument]
  ) -> [SectionInfo] {
    let tocByPath = tocTitlesByPath(book.toc)
    let landmarkRoles = landmarkRolesByPath(book.landmarks)
    var usedSlugs: Set<String> = []

    return book.spine.map { item in
      let extraction = extractions[item.index]
      let tocTitle = tocByPath[item.path]
      let role = role(for: item, tocTitle: tocTitle, landmarkRoles: landmarkRoles,
                      extraction: extraction)
      let title = tocTitle ?? extraction?.firstHeading ?? defaultTitle(for: role, item: item)
      let slug = uniqueSlug(for: title, index: item.index, used: &usedSlugs)
      return SectionInfo(
        spineIndex: item.index,
        role: role,
        title: title,
        slug: slug,
        characterCount: extraction?.characterCount ?? 0,
        includedByDefault: role.includedByDefault,
        included: role.includedByDefault)
    }
  }

  // MARK: - Signals

  private static let landmarkRoleMap: [String: SectionRole] = [
    "cover": .cover,
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
  ]

  nonisolated(unsafe) private static let partTitle = /^(part|book|volume)\b/.ignoresCase()

  private static func role(
    for item: SpineItem,
    tocTitle: String?,
    landmarkRoles: [String: SectionRole],
    extraction: ExtractedDocument?
  ) -> SectionRole {
    if let landmarkRole = landmarkRoles[item.path] { return landmarkRole }
    if let extraction, extraction.isNotesOnly { return .notes }

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

  private static func tocTitlesByPath(_ toc: [TOCEntry]) -> [String: String] {
    var result: [String: String] = [:]
    for entry in toc.flatMap(\.flattened) where result[entry.path] == nil {
      result[entry.path] = entry.title
    }
    return result
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

  private static func uniqueSlug(
    for title: String, index: Int, used: inout Set<String>
  ) -> String {
    var base = title.lowercased()
      .map { character in
        character.isLetter || character.isNumber ? String(character) : "-"
      }
      .joined()
    while base.contains("--") { base = base.replacingOccurrences(of: "--", with: "-") }
    base = base.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    if base.count > 40 { base = String(base.prefix(40)) }
    if base.isEmpty { base = "section" }
    var slug = base
    if used.contains(slug) { slug = "\(base)-\(index)" }
    used.insert(slug)
    return slug
  }
}

import ArgumentParser
import AudiobookKit
import CryptoKit
import EPUBKit
import Foundation

extension AudiobookCommand {
  /// A synthesis-free corpus exercise. This intentionally runs the same
  /// importer, section policy, chapter planner, sentence splitter, and
  /// request-unit planner as `audiobook create`.
  struct Audit: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "audit",
      abstract: "Dry-run every EPUB in a directory and write inspectable narration reports.")

    @Argument(help: "Directory containing EPUB files (searched recursively).")
    var directory: String

    @Option(name: .shortAndLong, help: "New or empty report directory.")
    var output: String

    func run() throws {
      let source = URL(fileURLWithPath: (directory as NSString).expandingTildeInPath)
        .standardizedFileURL
      let destination = URL(fileURLWithPath: (output as NSString).expandingTildeInPath)
        .standardizedFileURL
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory),
        isDirectory.boolValue
      else { throw ValidationError("not a directory: \(source.path)") }
      guard !FileManager.default.fileExists(atPath: destination.path) else {
        throw ValidationError("output already exists; choose a new directory: \(destination.path)")
      }
      try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
      let narrationRoot = destination.appendingPathComponent("narration", isDirectory: true)
      try FileManager.default.createDirectory(at: narrationRoot, withIntermediateDirectories: true)

      let books = try epubFiles(beneath: source)
      var reports: [BookReport] = []
      for (offset, url) in books.enumerated() {
        print("[\(offset + 1)/\(books.count)] \(url.lastPathComponent)")
        reports.append(try audit(url, sourceRoot: source, narrationRoot: narrationRoot))
      }
      try writeReports(reports, source: source, destination: destination)

      let failures = reports.filter { !$0.errors.isEmpty }
      print(
        "Audited \(reports.count) EPUBs: \(failures.count) failed, "
          + "\(reports.reduce(0) { $0 + $1.chapters }) chapters, "
          + "\(reports.reduce(0) { $0 + $1.synthesisUnits }) bounded synthesis units.")
      print("Reports: \(destination.path)")
      if !failures.isEmpty {
        throw CLIFailure(
          message: "\(failures.count) EPUB(s) failed the dry run; see summary.md", exitCode: 65)
      }
    }

    private func audit(_ url: URL, sourceRoot: URL, narrationRoot: URL) throws -> BookReport {
      let relative = relativePath(url, beneath: sourceRoot)
      let before = try sha256(url)
      var report = BookReport(source: relative, sha256: before)
      do {
        let publication = try EPUBImporter().load(url: url)
        let plan = try AudiobookPlanner.plan(publication: publication)
        report.title = plan.metadata.title
        report.chapters = plan.chapters.count
        report.characters = plan.totalCharacterCount
        report.warnings = plan.warnings

        let bookDirectory = narrationRoot.appendingPathComponent(
          uniqueDirectoryName(for: relative, hash: before), isDirectory: true)
        try FileManager.default.createDirectory(
          at: bookDirectory, withIntermediateDirectories: true)
        var allText = ""
        for (number, chapter) in plan.chapters.enumerated() {
          let paragraphs = chapter.allParagraphs.map { $0.sentences.joined(separator: " ") }
          let text = paragraphs.joined(separator: "\n\n")
          allText += text + "\n"
          let units = chapter.allParagraphs.flatMap(NarrationUnitPlanner.units)
          report.synthesisUnits += units.count
          report.maximumUnitCharacters = max(
            report.maximumUnitCharacters, units.map(\.text.count).max() ?? 0)
          if units.contains(where: { $0.text.count > NarrationUnitPlanner.maximumCharacters }) {
            report.errors.append("synthesis unit exceeds the configured character bound")
          }
          let filename = String(
            format: "%03d - %@.txt", number + 1, sanitizeFilename(chapter.title))
          try Data(text.utf8).write(to: bookDirectory.appendingPathComponent(filename))
        }
        report.reviewFindings = reviewFindings(in: allText)
      } catch {
        report.errors.append(error.localizedDescription)
      }
      let after = try sha256(url)
      if after != before { report.errors.append("source EPUB changed during a read-only audit") }
      return report
    }

    private func reviewFindings(in text: String) -> [String] {
      var findings: [String] = []
      let checks: [(String, String)] = [
        (#"(?i)<\/?(?:html|body|p|div|span|a|img|svg)\b"#, "HTML-like markup remains"),
        (#"\s+[.,;:!?]"#, "space appears before punctuation"),
        (#"\(\s*\)|\[\s*\]|\{\s*\}"#, "empty punctuation wrapper remains"),
        (
          #"(?i)\b(?:https?|ftp)://\S+"#,
          "visible URL-like prose remains; review rather than deleting automatically"
        ),
      ]
      for (pattern, message) in checks {
        if text.range(of: pattern, options: .regularExpression) != nil {
          findings.append(message)
        }
      }
      return findings
    }

    private func epubFiles(beneath root: URL) throws -> [URL] {
      let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey]
      guard
        let enumerator = FileManager.default.enumerator(
          at: root, includingPropertiesForKeys: keys,
          options: [.skipsHiddenFiles, .skipsPackageDescendants])
      else { return [] }
      return try enumerator.compactMap { value -> URL? in
        guard let url = value as? URL, url.pathExtension.lowercased() == "epub",
          try url.resourceValues(forKeys: Set(keys)).isRegularFile == true
        else { return nil }
        return url
      }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private func writeReports(_ reports: [BookReport], source: URL, destination: URL) throws {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      try encoder.encode(reports).write(to: destination.appendingPathComponent("books.json"))
      let summary = AuditSummary(
        source: source.path, books: reports.count,
        failures: reports.filter { !$0.errors.isEmpty }.count,
        chapters: reports.reduce(0) { $0 + $1.chapters },
        characters: reports.reduce(0) { $0 + $1.characters },
        synthesisUnits: reports.reduce(0) { $0 + $1.synthesisUnits },
        booksNeedingReview: reports.filter { !$0.reviewFindings.isEmpty }.count)
      try encoder.encode(summary).write(to: destination.appendingPathComponent("summary.json"))
      let markdown = makeSummaryMarkdown(summary: summary, reports: reports)
      try Data(markdown.utf8).write(to: destination.appendingPathComponent("summary.md"))
    }

    private func makeSummaryMarkdown(summary: AuditSummary, reports: [BookReport]) -> String {
      var text = """
        # EPUB narration audit

        - Books: \(summary.books)
        - Failures: \(summary.failures)
        - Chapters: \(summary.chapters)
        - Narration characters: \(summary.characters)
        - Bounded synthesis units: \(summary.synthesisUnits)
        - Books needing review: \(summary.booksNeedingReview)

        """
      for report in reports where !report.errors.isEmpty || !report.reviewFindings.isEmpty {
        text += "\n## \(report.source)\n"
        for error in report.errors { text += "\n- ERROR: \(error)\n" }
        for finding in report.reviewFindings { text += "\n- REVIEW: \(finding)\n" }
      }
      return text
    }

    private func uniqueDirectoryName(for relativePath: String, hash: String) -> String {
      sanitizeFilename(URL(fileURLWithPath: relativePath).deletingPathExtension().lastPathComponent)
        + "-" + hash.prefix(8)
    }

    private func relativePath(_ url: URL, beneath root: URL) -> String {
      let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
      return url.path.hasPrefix(prefix)
        ? String(url.path.dropFirst(prefix.count)) : url.lastPathComponent
    }

    private func sha256(_ url: URL) throws -> String {
      let handle = try FileHandle(forReadingFrom: url)
      defer { try? handle.close() }
      var hasher = SHA256()
      while let data = try handle.read(upToCount: 4 << 20), !data.isEmpty {
        hasher.update(data: data)
      }
      return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
  }
}

private struct BookReport: Codable {
  let source: String
  let sha256: String
  var title = ""
  var chapters = 0
  var characters = 0
  var synthesisUnits = 0
  var maximumUnitCharacters = 0
  var warnings: [String] = []
  var reviewFindings: [String] = []
  var errors: [String] = []
}

private struct AuditSummary: Codable {
  let source: String
  let books: Int
  let failures: Int
  let chapters: Int
  let characters: Int
  let synthesisUnits: Int
  let booksNeedingReview: Int
}

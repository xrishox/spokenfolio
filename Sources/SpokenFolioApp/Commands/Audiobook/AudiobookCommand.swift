import ArgumentParser
import AudiobookKit
import EPUBKit
import Foundation
import PublicationKit
import SiriTTSCore
import TTSKit

/// `spokenfolio audiobook …`: EPUB inspection and audiobook creation.
/// This is a narrow branch of the public ArgumentParser command tree.
struct AudiobookCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "audiobook",
    abstract: "Create audiobooks from EPUB books using installed Siri voices.",
    subcommands: [Create.self, Chapters.self, ExportText.self, Audit.self, Voices.self, Verify.self],
    defaultSubcommand: nil
  )

}

// MARK: - Shared options

struct BookArguments: ParsableArguments {
  @Argument(help: "Path to the EPUB file.", completion: .file(extensions: ["epub"]))
  var epub: String

  @Option(
    name: .customLong("include-sections"),
    help: "Sections to add to the smart defaults: indices, ranges, or slugs (e.g. '3,7-9,about-the-author').")
  var includeSections: String?

  @Option(
    name: .customLong("exclude-sections"),
    help: "Sections to remove: indices, ranges, or slugs.")
  var excludeSections: String?

  @Flag(inversion: .prefixedNo, help: "Speak chapter titles (default: from configuration).")
  var announceTitles: Bool?

  @Option(name: .customLong("max-chapters"), help: "Only plan the first N chapters (testing aid).")
  var maxChapters: Int?

  func loadPublication() throws -> Publication {
    let url = URL(fileURLWithPath: (epub as NSString).expandingTildeInPath)
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw CLIFailure(message: "no such file: \(url.path)", exitCode: 66 /* EX_NOINPUT */)
    }
    do {
      return try EPUBImporter().load(url: url)
    } catch {
      throw CLIFailure(
        message: "could not read EPUB: \(error.localizedDescription)",
        exitCode: 65 /* EX_DATAERR */)
    }
  }

  /// Explicit flag wins in either direction; the config supplies the
  /// default. The GUI passes the flag explicitly, so its toggle always
  /// takes effect (and yields the same resume job key as the equivalent
  /// CLI invocation).
  func effectiveAnnounceTitles(config: AudiobookConfig) -> Bool {
    announceTitles ?? config.announceTitles
  }

  func planOptions(config: AudiobookConfig) throws -> PlanOptions {
    var options = PlanOptions()
    options.announceTitles = effectiveAnnounceTitles(config: config)
    options.includeSections = try Self.expandSectionTokens(includeSections)
    options.excludeSections = try Self.expandSectionTokens(excludeSections)
    if let maxChapters {
      guard maxChapters > 0 else {
        throw ValidationError("--max-chapters must be at least 1")
      }
      options.maxChapters = maxChapters
    }
    return options
  }

  func plan(config: AudiobookConfig? = nil) throws -> AudiobookPlan {
    let resolved = try config ?? AppConfig.load().audiobook
    do {
      return try AudiobookPlanner.plan(
        publication: try loadPublication(), options: try planOptions(config: resolved))
    } catch let error as AudiobookPlanError {
      throw CLIFailure(message: error.localizedDescription, exitCode: 65)
    }
  }

  /// "3,7-9,about-the-author" → ["3", "7", "8", "9", "about-the-author"].
  /// Only pure numeric ranges expand; slugs may legitimately contain dashes.
  static func expandSectionTokens(_ list: String?) throws -> [String] {
    guard let list else { return [] }
    var tokens: [String] = []
    for raw in list.split(separator: ",") {
      let token = raw.trimmingCharacters(in: .whitespaces)
      guard !token.isEmpty else { continue }
      let parts = token.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
      if parts.count == 2, let low = Int(parts[0]), let high = Int(parts[1]) {
        guard low <= high else {
          throw ValidationError("section range '\(token)' is reversed")
        }
        tokens.append(contentsOf: (low...high).map(String.init))
      } else {
        tokens.append(token)
      }
    }
    return tokens
  }
}

struct CLIFailure: Error, CustomStringConvertible {
  let message: String
  let exitCode: Int32
  var description: String { message }
}

extension AudiobookCommand {
  // MARK: - chapters

  struct Chapters: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Show every book section, its role, and whether it will be narrated.")

    @OptionGroup var book: BookArguments

    func run() throws {
      let loaded = try book.plan()

      print("Sections (\(loaded.sections.count)):")
      print("  IDX  USE  DEFAULT  ROLE          CHARS  SLUG")
      for section in loaded.sections {
        let use = section.included ? "✓" : "✗"
        let def = section.includedByDefault ? "✓" : "✗"
        let role = section.role.rawValue.padding(toLength: 12, withPad: " ", startingAt: 0)
        let chars = String(section.characterCount).leftPadded(to: 7)
        let index = String(section.index).leftPadded(to: 5)
        print("\(index)   \(use)     \(def)     \(role)\(chars)  \(section.slug)")
      }

      print("\nChapters (\(loaded.chapters.count)):")
      for (number, chapter) in loaded.chapters.enumerated() {
        let announced = chapter.announcement != nil ? " [announced]" : ""
        let chars = String(chapter.characterCount).leftPadded(to: 7)
        print("\(String(number + 1).leftPadded(to: 5))  \(chars)  \(chapter.title)\(announced)")
      }
      print(
        "\nTotal: \(loaded.totalCharacterCount) characters in \(loaded.chapters.count) chapters.")
      for warning in loaded.warnings { FileHandle.standardError.write(Data("warning: \(warning)\n".utf8)) }
    }
  }

  // MARK: - export-text

  struct ExportText: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "export-text",
      abstract: "Write the exact narration text, one file per chapter, for inspection.")

    @OptionGroup var book: BookArguments

    @Option(name: .shortAndLong, help: "Output directory (default: '<book> narration' beside the EPUB).")
    var output: String?

    func run() throws {
      let plan = try book.plan()
      let epubURL = URL(fileURLWithPath: (book.epub as NSString).expandingTildeInPath)
      let directory = output.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        ?? epubURL.deletingPathExtension().appendingPathExtension("narration")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

      for (number, chapter) in plan.chapters.enumerated() {
        var text = ""
        if let announcement = chapter.announcement {
          text += announcement.sentences.joined(separator: " ") + "\n\n"
        }
        text += chapter.paragraphs
          .map { $0.sentences.joined(separator: " ") }
          .joined(separator: "\n\n")
        let name = String(format: "%03d - %@.txt", number + 1, sanitizeFilename(chapter.title))
        try Data(text.utf8).write(to: directory.appendingPathComponent(name))
      }
      print("Wrote \(plan.chapters.count) chapter files to \(directory.path)")
      for warning in plan.warnings { FileHandle.standardError.write(Data("warning: \(warning)\n".utf8)) }
    }
  }

  // MARK: - voices

  struct Voices: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "List installed Siri voices usable for audiobooks.")

    func run() throws {
      let backend: SiriTTSBackend
      do {
        backend = try SiriTTSBackend()
      } catch {
        throw CLIFailure(
          message:
            "no compatible Siri voices installed — download one in System Settings and run 'spokenfolio doctor'",
          exitCode: 69 /* EX_UNAVAILABLE */)
      }
      print("Installed Siri voices (\(backend.voices.count)):")
      for voice in backend.voices {
        let name = voice.name.padding(toLength: 24, withPad: " ", startingAt: 0)
        let lang = voice.language.padding(toLength: 8, withPad: " ", startingAt: 0)
        print("  \(name)\(lang)\(voice.quality.padding(toLength: 10, withPad: " ", startingAt: 0))\(voice.key.voiceID)")
      }
    }
  }
}

// MARK: - Helpers

func sanitizeFilename(_ name: String) -> String {
  let forbidden = CharacterSet(charactersIn: "/:\\?%*|\"<>")
  var result = String(
    name.unicodeScalars.map { forbidden.contains($0) ? "-" : Character($0) })
  if result.count > 120 { result = String(result.prefix(120)) }
  let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
  return trimmed.isEmpty ? "untitled" : trimmed
}

extension String {
  func leftPadded(to width: Int) -> String {
    count >= width ? self : String(repeating: " ", count: width - count) + self
  }
}

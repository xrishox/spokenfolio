import CryptoKit
import DocumentIOKit
import Foundation

/// The external tools used at the publication boundary. Calibre is optional
/// for EPUB 3 input, while EPUBCheck is mandatory for every accepted EPUB.
package struct EPUBComplianceToolchain: Sendable, Equatable {
  package var epubcheck: URL
  package var ebookConvert: URL?

  package init(epubcheck: URL, ebookConvert: URL? = nil) {
    self.epubcheck = epubcheck
    self.ebookConvert = ebookConvert
  }

  package static func resolve(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> Self {
    guard let epubcheck = executable(
      named: "epubcheck", override: environment["EPUBCHECK_PATH"], environment: environment)
    else {
      throw EPUBComplianceError.missingEPUBCheck
    }
    let converter = executable(
      named: "ebook-convert", override: environment["CALIBRE_EBOOK_CONVERT_PATH"],
      additional: ["/Applications/calibre.app/Contents/MacOS/ebook-convert"],
      environment: environment)
    return Self(epubcheck: epubcheck, ebookConvert: converter)
  }

  private static func executable(
    named name: String, override: String?, additional: [String] = [],
    environment: [String: String]
  ) -> URL? {
    var paths = additional
    if let override, !override.isEmpty { paths.insert(override, at: 0) }
    paths += ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"]
    paths += (environment["PATH"] ?? "").split(separator: ":").map {
      URL(fileURLWithPath: String($0)).appendingPathComponent(name).path
    }
    var seen = Set<String>()
    for path in paths {
      let url = URL(fileURLWithPath: path).standardizedFileURL
      guard seen.insert(url.path).inserted,
        FileManager.default.isExecutableFile(atPath: url.path)
      else { continue }
      return url
    }
    return nil
  }
}

package struct EPUBConformanceReport: Codable, Sendable, Equatable {
  package var epubVersion: String
  package var checkerVersion: String
  package var fatalCount: Int
  package var errorCount: Int
  package var warningCount: Int
  package var usageCount: Int

  package init(
    epubVersion: String, checkerVersion: String, fatalCount: Int,
    errorCount: Int, warningCount: Int, usageCount: Int
  ) {
    self.epubVersion = epubVersion
    self.checkerVersion = checkerVersion
    self.fatalCount = fatalCount
    self.errorCount = errorCount
    self.warningCount = warningCount
    self.usageCount = usageCount
  }
}

/// A source ready for import. Converted output lives in a private scratch
/// directory owned by the caller and must be cleaned after it is staged.
package struct PreparedEPUB: Sendable {
  package var url: URL
  package var sourceVersion: String
  package var wasConverted: Bool
  package var conformance: EPUBConformanceReport
  package var scratchDirectory: URL?

  package func cleanup() {
    guard let scratchDirectory else { return }
    try? FileManager.default.removeItem(at: scratchDirectory)
  }
}

package enum EPUBComplianceError: Error, LocalizedError, Equatable {
  case missingEPUBCheck
  case missingCalibre(sourceVersion: String)
  case unsupportedVersion(String)
  case processTimedOut(String)
  case conversionFailed
  case conversionDidNotProduceEPUB3(String)
  case unsupportedEPUBCheck(String)
  case invalidValidatorReport
  case nonconforming(fatal: Int, errors: Int)

  package var errorDescription: String? {
    switch self {
    case .missingEPUBCheck:
      "EPUBCheck is required to verify EPUB 3 compliance; install it with 'brew install epubcheck'."
    case .missingCalibre(let version):
      "This is EPUB \(version). Install Calibre so SpokenFolio can safely convert it to EPUB 3."
    case .unsupportedVersion(let version):
      "Unsupported EPUB package version '\(version)'."
    case .processTimedOut(let tool):
      "\(tool) exceeded its bounded execution time."
    case .conversionFailed:
      "Calibre could not convert this publication to EPUB 3."
    case .conversionDidNotProduceEPUB3(let version):
      "Calibre produced EPUB \(version), not EPUB 3."
    case .unsupportedEPUBCheck(let version):
      "EPUBCheck 5.3.0 or newer is required; found '\(version)'."
    case .invalidValidatorReport:
      "EPUBCheck did not produce a valid bounded conformance report."
    case .nonconforming(let fatal, let errors):
      "EPUBCheck found \(fatal) fatal error(s) and \(errors) error(s); the publication was not accepted."
    }
  }
}

/// One fail-closed EPUB boundary shared by import, production, delivery, and
/// ReadAloud verification. It never rewrites EPUB 3 input. EPUB 2 conversion
/// is delegated to Calibre, then independently verified by EPUBCheck.
package enum EPUBCompliance {
  private static let maximumReportBytes = 4 << 20

  package static func packageVersion(
    at url: URL, archiveLimits: ZIPArchive.Limits = .publication
  ) throws -> String {
    try EPUBBook.load(url: url, archiveLimits: archiveLimits).version
  }

  package static func isEPUB3(version: String) -> Bool {
    let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let majorText = trimmed.split(separator: ".", maxSplits: 1).first,
      let major = Int(majorText)
    else { return false }
    return major == 3
  }

  package static func prepare(
    source: URL, toolchain: EPUBComplianceToolchain? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) async throws -> PreparedEPUB {
    let tools = try toolchain ?? .resolve(environment: environment)
    let sourceVersion = try packageVersion(at: source)
    if isEPUB3(version: sourceVersion) {
      let report = try await validateEPUB3(
        at: source, toolchain: tools, environment: environment)
      return PreparedEPUB(
        url: source, sourceVersion: sourceVersion, wasConverted: false,
        conformance: report, scratchDirectory: nil)
    }
    guard sourceVersion.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("2") else {
      throw EPUBComplianceError.unsupportedVersion(sourceVersion)
    }
    guard let converter = tools.ebookConvert else {
      throw EPUBComplianceError.missingCalibre(sourceVersion: sourceVersion)
    }

    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
      "spokenfolio-epub-normalize-\(UUID().uuidString)", isDirectory: true)
    do {
      try FileManager.default.createDirectory(
        at: scratch, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      let converted = scratch.appendingPathComponent("calibre.epub")
      let output = scratch.appendingPathComponent("normalized.epub")
      let status = try await run(
        executable: converter,
        arguments: [
          source.path, converted.path, "--epub-version=3",
          "--dont-split-on-page-breaks", "--no-default-epub-cover",
        ], environment: environment, timeout: .seconds(1_800), toolName: "Calibre")
      guard status == 0, FileManager.default.fileExists(atPath: converted.path) else {
        throw EPUBComplianceError.conversionFailed
      }
      // Calibre writes current ZIP timestamps, a random package UUID, and a
      // current modification date even when every narrative payload is
      // identical. Canonicalize those generated fields and the validated ZIP
      // records so one source has stable catalog, duplicate, and resume
      // identity.
      let archive = try ZIPArchive(url: converted, limits: .publication)
      guard let container = archive.entry(at: EPUBContainer.containerPath) else {
        throw EPUBError.missingContainerXML
      }
      let opfPath = try EPUBContainer.packagePath(
        containerXML: archive.data(for: container))
      guard let opf = archive.entry(at: opfPath) else {
        throw EPUBError.missingPackageDocument(opfPath)
      }
      let sourceIdentity = try sha256(source)
      let canonicalOPF = try canonicalPackageDocument(
        archive.data(for: opf), sourceIdentity: sourceIdentity)
      try ZIPArchiveRewriter.rewrite(
        archive, replacing: [opfPath: canonicalOPF], to: output)
      try FileManager.default.removeItem(at: converted)
      let version = try packageVersion(at: output)
      guard isEPUB3(version: version) else {
        throw EPUBComplianceError.conversionDidNotProduceEPUB3(version)
      }
      let report = try await validateEPUB3(
        at: output, toolchain: tools, environment: environment)
      return PreparedEPUB(
        url: output, sourceVersion: sourceVersion, wasConverted: true,
        conformance: report, scratchDirectory: scratch)
    } catch {
      try? FileManager.default.removeItem(at: scratch)
      throw error
    }
  }

  package static func validateEPUB3(
    at url: URL, toolchain: EPUBComplianceToolchain? = nil,
    archiveLimits: ZIPArchive.Limits = .publication,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) async throws -> EPUBConformanceReport {
    let tools = try toolchain ?? .resolve(environment: environment)
    let version = try packageVersion(at: url, archiveLimits: archiveLimits)
    guard isEPUB3(version: version) else {
      throw EPUBComplianceError.unsupportedVersion(version)
    }

    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
      "spokenfolio-epubcheck-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: scratch, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: scratch) }
    let reportURL = scratch.appendingPathComponent("report.json")
    let status = try await run(
      executable: tools.epubcheck,
      arguments: [url.path, "--json", reportURL.path],
      environment: environment, timeout: .seconds(900), toolName: "EPUBCheck")
    let values = try? reportURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values?.isRegularFile == true, let size = values?.fileSize,
      size > 0, size <= maximumReportBytes,
      let data = try? Data(contentsOf: reportURL, options: [.mappedIfSafe]),
      let parsed = try? JSONDecoder().decode(EPUBCheckJSON.self, from: data)
    else { throw EPUBComplianceError.invalidValidatorReport }
    let result = EPUBConformanceReport(
      epubVersion: parsed.publication.ePubVersion,
      checkerVersion: parsed.checker.checkerVersion,
      fatalCount: parsed.checker.nFatal, errorCount: parsed.checker.nError,
      warningCount: parsed.checker.nWarning, usageCount: parsed.checker.nUsage)
    guard supportedEPUBCheck(result.checkerVersion) else {
      throw EPUBComplianceError.unsupportedEPUBCheck(result.checkerVersion)
    }
    guard status == 0, result.fatalCount == 0, result.errorCount == 0,
      isEPUB3(version: result.epubVersion)
    else {
      throw EPUBComplianceError.nonconforming(
        fatal: result.fatalCount, errors: result.errorCount)
    }
    return result
  }

  private static func supportedEPUBCheck(_ value: String) -> Bool {
    let candidate = value.split(whereSeparator: {
      !$0.isNumber && $0 != "."
    }).first(where: { $0.first?.isNumber == true })
    guard let candidate else { return false }
    let components = candidate.split(separator: ".").compactMap { Int($0) }
    guard !components.isEmpty else { return false }
    let normalized = components + Array(repeating: 0, count: max(0, 3 - components.count))
    return (normalized[0], normalized[1], normalized[2]) >= (5, 3, 0)
  }

  package static func toolVersions(
    toolchain: EPUBComplianceToolchain? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) async throws -> (epubcheck: String, calibre: String?) {
    let tools = try toolchain ?? .resolve(environment: environment)
    let check = try await capturedVersion(
      executable: tools.epubcheck, arguments: ["--version"], environment: environment)
    let calibre: String?
    if let converter = tools.ebookConvert {
      calibre = try await capturedVersion(
        executable: converter, arguments: ["--version"], environment: environment)
    } else {
      calibre = nil
    }
    return (check, calibre)
  }

  private struct EPUBCheckJSON: Decodable {
    struct Checker: Decodable {
      let checkerVersion: String
      let nFatal: Int
      let nError: Int
      let nWarning: Int
      let nUsage: Int
    }
    struct Publication: Decodable { let ePubVersion: String }
    let checker: Checker
    let publication: Publication
  }

  private static func capturedVersion(
    executable: URL, arguments: [String], environment: [String: String]
  ) async throws -> String {
    let pipe = Pipe()
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.environment = environment
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    guard process.terminationStatus == 0, data.count <= 16 << 10 else {
      throw EPUBComplianceError.invalidValidatorReport
    }
    return String(decoding: data, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func canonicalPackageDocument(
    _ data: Data, sourceIdentity: String
  ) throws -> Data {
    let document = try BoundedXMLDocument.parse(
      data, preserveWhitespace: true, allowTidy: false)
    guard let root = document.rootElement(),
      root.localName == "package",
      let uniqueIdentifierID = root.attribute(forName: "unique-identifier")?.stringValue,
      !uniqueIdentifierID.isEmpty
    else {
      throw EPUBComplianceError.conversionFailed
    }
    var identifierUpdated = false
    var stack = [root]
    while let element = stack.popLast() {
      if element.localName == "identifier",
        element.attribute(forName: "id")?.stringValue == uniqueIdentifierID
      {
        element.stringValue = deterministicUUIDURN(sourceIdentity)
        identifierUpdated = true
      } else if element.localName == "meta",
        element.attribute(forName: "property")?.stringValue == "dcterms:modified"
      {
        element.stringValue = "1980-01-01T00:00:00Z"
      }
      for case let child as XMLElement in element.children ?? [] {
        stack.append(child)
      }
    }
    guard identifierUpdated else {
      throw EPUBComplianceError.conversionFailed
    }
    return document.xmlData(options: [.nodePreserveAll])
  }

  private static func deterministicUUIDURN(_ sha256: String) -> String {
    var hex = Array(sha256.prefix(32))
    // RFC 9562 UUIDv8: stable application-defined bits with the standard
    // variant, derived solely from the exact source bytes.
    hex[12] = "8"
    hex[16] = "8"
    let value =
      String(hex[0..<8]) + "-" + String(hex[8..<12]) + "-"
      + String(hex[12..<16]) + "-" + String(hex[16..<20]) + "-"
      + String(hex[20..<32])
    return "urn:uuid:\(value)"
  }

  private static func sha256(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hash = SHA256()
    while true {
      let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
      if chunk.isEmpty { break }
      hash.update(data: chunk)
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private static func run(
    executable: URL, arguments: [String], environment: [String: String],
    timeout: Duration, toolName: String
  ) async throws -> Int32 {
    try Task.checkCancellation()
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.environment = environment
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    do {
      while process.isRunning {
        try Task.checkCancellation()
        guard clock.now < deadline else {
          process.interrupt()
          try? await Task.sleep(for: .seconds(2))
          if process.isRunning { process.terminate() }
          throw EPUBComplianceError.processTimedOut(toolName)
        }
        try await Task.sleep(for: .milliseconds(100))
      }
      return process.terminationStatus
    } catch {
      if process.isRunning {
        process.interrupt()
        try? await Task.sleep(for: .seconds(1))
        if process.isRunning { process.terminate() }
      }
      throw error
    }
  }
}

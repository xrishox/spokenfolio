import CryptoKit
import Darwin
import DocumentIOKit
import EPUBKit
import Foundation

package enum ReadAloudTools {
  package struct StalignRelease: Sendable, Equatable {
    package var version: String
    package var sha256: String
    package var downloadURL: URL

    package init(version: String, sha256: String, downloadURL: URL) {
      self.version = version
      self.sha256 = sha256
      self.downloadURL = downloadURL
    }
  }

  private struct PackageRelease: Decodable {
    var id: Int
    var name: String
    var version: String
    var status: String
  }

  private struct PackageFile: Decodable {
    var fileName: String
    var size: Int
    var fileSHA256: String

    private enum CodingKeys: String, CodingKey {
      case fileName = "file_name"
      case size
      case fileSHA256 = "file_sha256"
    }
  }

  private struct SemanticVersion: Comparable {
    var components: [Int]

    init?(_ rawValue: String) {
      guard !rawValue.contains("-") else { return nil }
      let values = rawValue.split(separator: ".", omittingEmptySubsequences: false)
      guard values.count >= 2, values.count <= 4,
        values.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) })
      else { return nil }
      components = values.compactMap { Int($0) }
      guard components.count == values.count else { return nil }
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
      let count = max(lhs.components.count, rhs.components.count)
      for index in 0..<count {
        let left = index < lhs.components.count ? lhs.components[index] : 0
        let right = index < rhs.components.count ? rhs.components[index] : 0
        if left != right { return left < right }
      }
      return false
    }
  }

  private static let stalignProjectID = 67_994_333
  private static let stalignPackageName = "stalign"
  private static let stalignArtifactName = "stalign-darwin-arm64"
  /// Publisher identity is a supply-chain boundary, not a version pin.
  package static let upstreamStalignTeamID = "XZZA7493Q2"
  private static let maximumStalignBytes = 256 << 20
  private static let gitLabAPI = URL(string: "https://gitlab.com/api/v4")!

  package static func resolve(
    managedStalign: URL, environment: [String: String] = ProcessInfo.processInfo.environment
  ) async throws -> ReadAloudToolchain {
    guard FileManager.default.isExecutableFile(atPath: managedStalign.path) else {
      throw ReadAloudError.missingTool(
        "stalign; install it from the ReadAloud Tools screen")
    }
    let hash = try sha256(managedStalign)
    let runner = ExternalProcessRunner()
    let versionText = try await validateStalign(
      managedStalign, expectedVersion: nil, runner: runner, environment: environment)

    let pair = try resolveFFmpeg(environment: environment)
    let compliance = try EPUBComplianceToolchain.resolve(environment: environment)
    let complianceVersions = try await EPUBCompliance.toolVersions(
      toolchain: compliance, environment: environment)
    return ReadAloudToolchain(
      stalign: managedStalign, ffmpeg: pair.0, ffprobe: pair.1,
      epubcheck: compliance.epubcheck,
      stalignVersion: versionText, stalignSHA256: hash,
      epubcheckVersion: complianceVersions.epubcheck)
  }

  package static func availableStalignReleases(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) async throws -> [StalignRelease] {
    let runner = ExternalProcessRunner()
    let packagesURL = gitLabAPI
      .appendingPathComponent("projects/\(stalignProjectID)/packages")
    var components = URLComponents(url: packagesURL, resolvingAgainstBaseURL: false)
    components?.queryItems = [
      URLQueryItem(name: "package_type", value: "generic"),
      URLQueryItem(name: "package_name", value: stalignPackageName),
      URLQueryItem(name: "status", value: "default"),
      URLQueryItem(name: "per_page", value: "100"),
    ]
    guard let url = components?.url else {
      throw ReadAloudError.unsupportedTool("the stalign release index URL is invalid")
    }
    let packages: [PackageRelease] = try await fetchJSON(
      [PackageRelease].self, from: url, runner: runner, environment: environment)
    var releases: [StalignRelease] = []
    for package in packages where package.name == stalignPackageName
      && package.status == "default" && SemanticVersion(package.version) != nil
    {
      let filesURL = gitLabAPI
        .appendingPathComponent(
          "projects/\(stalignProjectID)/packages/\(package.id)/package_files")
      let files: [PackageFile] = try await fetchJSON(
        [PackageFile].self, from: filesURL, runner: runner, environment: environment)
      guard let file = files.first(where: {
        $0.fileName == stalignArtifactName
          && $0.size > 0 && $0.size <= maximumStalignBytes
          && $0.fileSHA256.count == 64 && $0.fileSHA256.allSatisfy(\.isHexDigit)
      }) else { continue }
      let download = gitLabAPI.appendingPathComponent(
        "projects/\(stalignProjectID)/packages/generic/"
          + "\(stalignPackageName)/\(package.version)/\(stalignArtifactName)")
      releases.append(
        StalignRelease(
          version: package.version, sha256: file.fileSHA256.lowercased(),
          downloadURL: download))
    }
    return releases.sorted {
      SemanticVersion($0.version)! > SemanticVersion($1.version)!
    }
  }

  package static func latestStalignRelease(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) async throws -> StalignRelease {
    guard let release = try await availableStalignReleases(environment: environment).first else {
      throw ReadAloudError.missingTool("no stable macOS ARM64 stalign release is available")
    }
    return release
  }

  package static func installStalign(
    destination: URL, version requestedVersion: String? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) async throws -> StalignRelease {
    let releases = try await availableStalignReleases(environment: environment)
    let release: StalignRelease
    if let requestedVersion {
      guard let match = releases.first(where: { $0.version == requestedVersion }) else {
        throw ReadAloudError.unsupportedTool(
          "stable stalign \(requestedVersion) is unavailable for macOS ARM64")
      }
      release = match
    } else {
      guard let latest = releases.first else {
        throw ReadAloudError.missingTool("no stable macOS ARM64 stalign release is available")
      }
      release = latest
    }
    guard release.downloadURL.scheme == "https",
      release.downloadURL.host == "gitlab.com"
    else {
      throw ReadAloudError.unsupportedTool("the stalign download origin is invalid")
    }
    let directory = destination.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let temporary = directory.appendingPathComponent(".stalign-\(UUID().uuidString).download")
    defer { try? FileManager.default.removeItem(at: temporary) }
    let runner = ExternalProcessRunner()
    let download = try await runner.run(
      executable: URL(fileURLWithPath: "/usr/bin/curl"),
      arguments: [
        "--fail", "--silent", "--show-error", "--location", "--max-redirs", "5",
        "--proto", "=https", "--proto-redir", "=https", "--max-time", "600",
        "--max-filesize", String(maximumStalignBytes), "--output", temporary.path,
        release.downloadURL.absoluteString,
      ], environment: environment, timeout: .seconds(630))
    guard download.status == 0 else {
      let detail = String(decoding: download.stderr, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      throw ReadAloudError.processFailed(
        detail.isEmpty ? "stalign download failed" : "stalign download failed: \(detail)")
    }
    let values = try temporary.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values.isRegularFile == true, let size = values.fileSize,
      size > 0, size <= maximumStalignBytes
    else {
      throw ReadAloudError.unsupportedTool("downloaded stalign has an invalid size")
    }
    guard try sha256(temporary) == release.sha256 else {
      throw ReadAloudError.unsupportedTool("downloaded stalign checksum is invalid")
    }
    guard chmod(temporary.path, S_IRUSR | S_IWUSR | S_IXUSR) == 0 else {
      throw ReadAloudError.processFailed("could not make the downloaded stalign executable")
    }
    let verification = try await runner.run(
      executable: URL(fileURLWithPath: "/usr/bin/codesign"),
      arguments: ["--verify", "--strict", "--verbose=4", temporary.path],
      environment: environment)
    guard verification.status == 0 else {
      throw ReadAloudError.unsupportedTool("downloaded stalign signature is invalid")
    }
    let signature = try await runner.run(
      executable: URL(fileURLWithPath: "/usr/bin/codesign"),
      arguments: ["-dv", "--verbose=4", temporary.path],
      environment: environment)
    let details = String(decoding: signature.stderr, as: UTF8.self)
    guard signature.status == 0,
      details.contains("TeamIdentifier=\(upstreamStalignTeamID)")
    else {
      throw ReadAloudError.unsupportedTool("downloaded stalign has the wrong signing identity")
    }
    _ = try await validateStalign(
      temporary, expectedVersion: release.version, runner: runner, environment: environment)

    let backup = directory.appendingPathComponent(".stalign-\(UUID().uuidString).rollback")
    var movedExisting = false
    defer { try? FileManager.default.removeItem(at: backup) }
    if FileManager.default.fileExists(atPath: destination.path) {
      try FileManager.default.moveItem(at: destination, to: backup)
      movedExisting = true
    }
    do {
      try FileManager.default.moveItem(at: temporary, to: destination)
      _ = try await validateStalign(
        destination, expectedVersion: release.version, runner: runner, environment: environment)
    } catch {
      try? FileManager.default.removeItem(at: destination)
      if movedExisting { try? FileManager.default.moveItem(at: backup, to: destination) }
      throw error
    }
    return release
  }

  private static func fetchJSON<Value: Decodable>(
    _ type: Value.Type, from url: URL, runner: ExternalProcessRunner,
    environment: [String: String]
  ) async throws -> Value {
    guard url.scheme == "https", url.host == "gitlab.com" else {
      throw ReadAloudError.unsupportedTool("the stalign release metadata origin is invalid")
    }
    let result = try await runner.run(
      executable: URL(fileURLWithPath: "/usr/bin/curl"),
      arguments: [
        "--fail", "--silent", "--show-error", "--location", "--max-redirs", "3",
        "--proto", "=https", "--proto-redir", "=https", "--max-time", "30",
        url.absoluteString,
      ], environment: environment, timeout: .seconds(40))
    guard result.status == 0 else {
      throw ReadAloudError.processFailed("could not retrieve stalign release metadata")
    }
    do { return try JSONDecoder().decode(type, from: result.stdout) } catch {
      throw ReadAloudError.unsupportedTool("stalign release metadata is invalid")
    }
  }

  private static func validateStalign(
    _ executable: URL, expectedVersion: String?, runner: ExternalProcessRunner,
    environment: [String: String]
  ) async throws -> String {
    let signatureCheck = try await runner.run(
      executable: URL(fileURLWithPath: "/usr/bin/codesign"),
      arguments: ["--verify", "--strict", "--verbose=4", executable.path],
      environment: environment, timeout: .seconds(30))
    let signatureDetail = try await runner.run(
      executable: URL(fileURLWithPath: "/usr/bin/codesign"),
      arguments: ["-dv", "--verbose=4", executable.path],
      environment: environment, timeout: .seconds(30))
    let signatureText = String(decoding: signatureDetail.stderr, as: UTF8.self)
    guard signatureCheck.status == 0, signatureDetail.status == 0,
      signatureText.contains("TeamIdentifier=\(upstreamStalignTeamID)")
    else {
      throw ReadAloudError.unsupportedTool(
        "stalign is not signed by the expected upstream publisher")
    }
    let version = try await runner.run(
      executable: executable, arguments: ["--version"], environment: environment,
      timeout: .seconds(30))
    let versionText = String(decoding: version.stdout, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard version.status == 0, SemanticVersion(versionText) != nil,
      expectedVersion == nil || versionText == expectedVersion
    else {
      throw ReadAloudError.unsupportedTool("stalign did not report the expected stable version")
    }
    let required: [(String, [String])] = [
      ("process", ["--codec", "--bitrate", "--parallel"]),
      ("markup", ["--granularity", "--language"]),
      ("align", ["--transcriptions", "--audiobook", "--epub", "--output", "--reports"]),
    ]
    for (command, flags) in required {
      let help = try await runner.run(
        executable: executable, arguments: [command, "--help"], environment: environment,
        timeout: .seconds(30))
      let output =
        String(decoding: help.stdout, as: UTF8.self)
        + String(decoding: help.stderr, as: UTF8.self)
      guard help.status == 0, flags.allSatisfy(output.contains) else {
        throw ReadAloudError.unsupportedTool(
          "stalign \(versionText) lacks the required '\(command)' interface")
      }
    }
    try await validateMarkupCompatibility(
      executable, runner: runner, environment: environment)
    return versionText
  }

  /// A CLI can retain its flags while changing the generated EPUB contract.
  /// Exercise the installed executable against a real, bounded EPUB 3
  /// fixture and require the sentence IDs consumed by our adapter.
  private static func validateMarkupCompatibility(
    _ executable: URL, runner: ExternalProcessRunner,
    environment: [String: String]
  ) async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory
      .appendingPathComponent("spokenfolio-stalign-probe-\(UUID().uuidString)")
    let source = root.appendingPathComponent("source", isDirectory: true)
    let input = root.appendingPathComponent("input.epub")
    let output = root.appendingPathComponent("output.epub")
    defer { try? fm.removeItem(at: root) }
    try fm.createDirectory(
      at: source.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
    try fm.createDirectory(
      at: source.appendingPathComponent("OEBPS"), withIntermediateDirectories: true)
    try Data("application/epub+zip".utf8).write(
      to: source.appendingPathComponent("mimetype"))
    try Data(
      """
      <?xml version="1.0"?>
      <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
        <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
      </container>
      """.utf8
    ).write(to: source.appendingPathComponent("META-INF/container.xml"))
    try Data(
      """
      <?xml version="1.0" encoding="UTF-8"?>
      <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
          <dc:identifier id="id">spokenfolio-compatibility-probe</dc:identifier>
          <dc:title>Compatibility Probe</dc:title><dc:language>en</dc:language>
        </metadata>
        <manifest>
          <item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/>
        </manifest>
        <spine><itemref idref="chapter"/></spine>
      </package>
      """.utf8
    ).write(to: source.appendingPathComponent("OEBPS/content.opf"))
    try Data(
      """
      <?xml version="1.0" encoding="UTF-8"?>
      <html xmlns="http://www.w3.org/1999/xhtml"><head><title>Probe</title></head>
        <body><p>First sentence. Second sentence!</p></body>
      </html>
      """.utf8
    ).write(to: source.appendingPathComponent("OEBPS/chapter.xhtml"))

    let zip = URL(fileURLWithPath: "/usr/bin/zip")
    let stored = try await runner.run(
      executable: zip, arguments: ["-q", "-X", "-0", input.path, "mimetype"],
      environment: environment, timeout: .seconds(30), currentDirectory: source)
    let remainder = try await runner.run(
      executable: zip,
      arguments: ["-q", "-X", "-r", input.path, "META-INF", "OEBPS"],
      environment: environment, timeout: .seconds(30), currentDirectory: source)
    guard stored.status == 0, remainder.status == 0 else {
      throw ReadAloudError.unsupportedTool(
        "could not construct the stalign compatibility fixture")
    }
    let markup = try await runner.run(
      executable: executable,
      arguments: [
        "markup", "--granularity", "sentence", "--language", "en-US",
        "--no-progress", "--log-level", "error", input.path, output.path,
      ], environment: environment, timeout: .seconds(90))
    guard markup.status == 0, fm.fileExists(atPath: output.path) else {
      throw ReadAloudError.unsupportedTool(
        "stalign failed the EPUB markup compatibility probe")
    }
    let archive = try ZIPArchive(url: output, limits: .readAloud)
    guard let entry = archive.entry(at: "OEBPS/chapter.xhtml") else {
      throw ReadAloudError.unsupportedTool(
        "stalign markup omitted the compatibility document")
    }
    let document = try BoundedXMLDocument.parse(archive.data(for: entry))
    let sentenceIDs = try document.nodes(
      forXPath: "//*[local-name()='span'][@id]"
    ).compactMap { ($0 as? XMLElement)?.attribute(forName: "id")?.stringValue }
      .filter { $0.range(of: #"-s[0-9]+$"#, options: .regularExpression) != nil }
    guard sentenceIDs.count == 2 else {
      throw ReadAloudError.unsupportedTool(
        "stalign markup does not expose the required sentence identifiers")
    }
  }

  package static func resolveFFmpegOnly(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> (ffmpeg: URL, ffprobe: URL) {
    let pair = try resolveFFmpeg(environment: environment)
    return (pair.0, pair.1)
  }

  package static func resolveEPUBCompliance(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) async throws -> (
    epubcheck: URL, version: String, calibre: URL?, calibreVersion: String?
  ) {
    let tools = try EPUBComplianceToolchain.resolve(environment: environment)
    let versions = try await EPUBCompliance.toolVersions(
      toolchain: tools, environment: environment)
    return (tools.epubcheck, versions.epubcheck, tools.ebookConvert, versions.calibre)
  }

  private static func resolveFFmpeg(environment: [String: String]) throws -> (URL, URL) {
    var directories: [String] = []
    if let explicit = environment["FFMPEG_PATH"], !explicit.isEmpty {
      let url = URL(fileURLWithPath: explicit)
      directories.append(url.hasDirectoryPath ? url.path : url.deletingLastPathComponent().path)
    }
    directories += ["/opt/homebrew/bin", "/usr/local/bin"]
    directories += (environment["PATH"] ?? "").split(separator: ":").map(String.init)
    for directory in directories {
      let ffmpeg = URL(fileURLWithPath: directory).appendingPathComponent("ffmpeg")
      let ffprobe = URL(fileURLWithPath: directory).appendingPathComponent("ffprobe")
      if FileManager.default.isExecutableFile(atPath: ffmpeg.path),
        FileManager.default.isExecutableFile(atPath: ffprobe.path)
      {
        return (ffmpeg, ffprobe)
      }
    }
    throw ReadAloudError.missingTool("ffmpeg and ffprobe; install them with 'brew install ffmpeg'")
  }

  package static func sha256(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hash = SHA256()
    while let data = try handle.read(upToCount: 4 << 20), !data.isEmpty { hash.update(data: data) }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }
}

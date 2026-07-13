import CryptoKit
import Darwin
import Foundation

package enum ReadAloudTools {
  package static let pinnedStalignVersion = "0.1.52"
  package static let pinnedStalignSHA256 =
    "e95ea0973bab0021500c446ddf708bcf0435c2c0bfa666c9e4019c080b049100"
  package static let pinnedStalignTeamID = "XZZA7493Q2"
  package static let pinnedStalignURL = URL(
    string:
      "https://gitlab.com/api/v4/projects/67994333/packages/generic/stalign/0.1.52/stalign-darwin-arm64"
  )!

  package static func resolve(
    managedStalign: URL, environment: [String: String] = ProcessInfo.processInfo.environment
  ) async throws -> ReadAloudToolchain {
    guard FileManager.default.isExecutableFile(atPath: managedStalign.path) else {
      throw ReadAloudError.missingTool(
        "stalign \(pinnedStalignVersion); install it from the ReadAloud Tools screen")
    }
    let hash = try sha256(managedStalign)
    guard hash == pinnedStalignSHA256 else {
      throw ReadAloudError.unsupportedTool("stalign checksum does not match the pinned release")
    }
    let runner = ExternalProcessRunner()
    let version = try await runner.run(
      executable: managedStalign, arguments: ["--version"], environment: environment)
    let versionText = String(decoding: version.stdout, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard version.status == 0, versionText == pinnedStalignVersion else {
      throw ReadAloudError.unsupportedTool("expected stalign \(pinnedStalignVersion)")
    }

    let pair = try resolveFFmpeg(environment: environment)
    return ReadAloudToolchain(
      stalign: managedStalign, ffmpeg: pair.0, ffprobe: pair.1,
      stalignVersion: versionText, stalignSHA256: hash)
  }

  package static func installStalign(destination: URL) async throws {
    let directory = destination.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let temporary = directory.appendingPathComponent(".stalign-\(UUID().uuidString).download")
    defer { try? FileManager.default.removeItem(at: temporary) }
    let (downloaded, response) = try await URLSession.shared.download(from: pinnedStalignURL)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
      throw ReadAloudError.processFailed("stalign download returned an unexpected response")
    }
    try FileManager.default.moveItem(at: downloaded, to: temporary)
    guard try sha256(temporary) == pinnedStalignSHA256 else {
      throw ReadAloudError.unsupportedTool("downloaded stalign checksum is invalid")
    }
    _ = chmod(temporary.path, S_IRUSR | S_IWUSR | S_IXUSR)
    let runner = ExternalProcessRunner()
    let verification = try await runner.run(
      executable: URL(fileURLWithPath: "/usr/bin/codesign"),
      arguments: ["--verify", "--strict", "--verbose=4", temporary.path],
      environment: ProcessInfo.processInfo.environment)
    guard verification.status == 0 else {
      throw ReadAloudError.unsupportedTool("downloaded stalign signature is invalid")
    }
    let signature = try await runner.run(
      executable: URL(fileURLWithPath: "/usr/bin/codesign"),
      arguments: ["-dv", "--verbose=4", temporary.path],
      environment: ProcessInfo.processInfo.environment)
    let details = String(decoding: signature.stderr, as: UTF8.self)
    guard signature.status == 0, details.contains("TeamIdentifier=\(pinnedStalignTeamID)") else {
      throw ReadAloudError.unsupportedTool("downloaded stalign has the wrong signing identity")
    }
    if FileManager.default.fileExists(atPath: destination.path) {
      _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
    } else {
      try FileManager.default.moveItem(at: temporary, to: destination)
    }
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

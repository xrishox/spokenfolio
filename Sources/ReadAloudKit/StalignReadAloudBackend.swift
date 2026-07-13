import CryptoKit
import Foundation

package protocol ReadAloudBackend: Sendable {
  func create(
    request: ReadAloudRequest,
    progress: @escaping @Sendable (ReadAloudProgress) -> Void
  ) async throws -> ReadAloudVerificationReport
}

package final class StalignReadAloudBackend: ReadAloudBackend, @unchecked Sendable {
  private let tools: ReadAloudToolchain
  private let runner: ExternalProcessRunner

  package init(tools: ReadAloudToolchain, runner: ExternalProcessRunner = .init()) {
    self.tools = tools
    self.runner = runner
  }

  package func create(
    request: ReadAloudRequest,
    progress: @escaping @Sendable (ReadAloudProgress) -> Void
  ) async throws -> ReadAloudVerificationReport {
    try request.validate()
    let fm = FileManager.default
    guard fm.fileExists(atPath: request.epubPath), fm.fileExists(atPath: request.audiobookPath)
    else {
      throw ReadAloudError.invalidRequest("EPUB or audiobook input does not exist")
    }
    let output = URL(fileURLWithPath: request.outputPath)
    if fm.fileExists(atPath: output.path), !request.overwrite {
      throw ReadAloudError.outputExists(output.path)
    }
    let work = URL(fileURLWithPath: request.workDirectory, isDirectory: true)
    try fm.createDirectory(at: work, withIntermediateDirectories: true)
    let input = work.appendingPathComponent("input", isDirectory: true)
    let processed = work.appendingPathComponent("processed", isDirectory: true)
    let transcriptions = work.appendingPathComponent("transcriptions", isDirectory: true)
    let markedup = work.appendingPathComponent("markedup.epub")
    let staged = work.appendingPathComponent("output.partial.epub")
    let report = work.appendingPathComponent("alignment-report.json")
    let manifestURL = work.appendingPathComponent("readaloud-manifest.json")
    let fingerprint = try requestFingerprint(request)
    var manifest = try loadManifest(manifestURL, fingerprint: fingerprint)

    let environment = childEnvironment(work: work)
    progress(
      .init(
        stage: .preparing, stageFraction: 0, overallFraction: 0,
        message: "Preparing ReadAloud tools"))
    // The work directory is user-selectable in the CLI. Never retain a stale
    // input symlink when the same directory is reused for another audiobook.
    try reset(input)
    let stagedAudio = input.appendingPathComponent(
      URL(fileURLWithPath: request.audiobookPath).lastPathComponent)
    try fm.createSymbolicLink(
      at: stagedAudio, withDestinationURL: URL(fileURLWithPath: request.audiobookPath))

    let processedAudioIsValid = try await validateProcessed(processed, environment: environment)
    if !manifest.completed.contains(.processingAudio) || !processedAudioIsValid {
      try reset(processed)
      try await runStage(
        .processingAudio,
        arguments: [
          "process", "--parallel", "1", "--codec", "libopus", "--bitrate",
          "\(request.opusBitrateKbps)K", "--no-progress", "--log-level", "info",
          input.path, processed.path,
        ], environment: environment, base: 0.05, weight: 0.10, progress: progress)
      guard try await validateProcessed(processed, environment: environment) else {
        throw ReadAloudError.invalidArtifact("stalign produced no Opus audio")
      }
      manifest.completed.insert(.processingAudio)
      try save(manifest, to: manifestURL)
    }

    if try !manifest.completed.contains(.transcribing) || !validateTranscriptions(transcriptions) {
      try reset(transcriptions)
      let model =
        request.language.lowercased().hasPrefix("en")
        ? (request.whisperModel.hasSuffix(".en")
          ? request.whisperModel : request.whisperModel + ".en")
        : request.whisperModel.replacingOccurrences(of: ".en", with: "")
      try await runStage(
        .transcribing,
        arguments: [
          "transcribe", "--parallel", "1", "--language", request.language,
          "--engine", "whisper.cpp", "--model", model,
          "--no-progress", "--log-level", "info", processed.path, transcriptions.path,
        ], environment: environment, base: 0.15, weight: 0.65, progress: progress)
      guard try validateTranscriptions(transcriptions) else {
        throw ReadAloudError.invalidArtifact("stalign produced invalid transcriptions")
      }
      manifest.completed.insert(.transcribing)
      try save(manifest, to: manifestURL)
    }

    if !manifest.completed.contains(.markingUp) || !fm.fileExists(atPath: markedup.path) {
      try? fm.removeItem(at: markedup)
      try await runStage(
        .markingUp,
        arguments: [
          "markup", "--granularity", "sentence", "--language", request.language,
          "--no-progress", "--log-level", "info", request.epubPath, markedup.path,
        ], environment: environment, base: 0.80, weight: 0.05, progress: progress)
      guard fm.fileExists(atPath: markedup.path) else {
        throw ReadAloudError.invalidArtifact("stalign did not produce a marked-up EPUB")
      }
      manifest.completed.insert(.markingUp)
      try save(manifest, to: manifestURL)
    }

    try? fm.removeItem(at: staged)
    try? fm.removeItem(at: report)
    try await runStage(
      .aligning,
      arguments: [
        "align", "--transcriptions", transcriptions.path, "--output", staged.path,
        "--audiobook", processed.path, "--epub", markedup.path, "--reports", report.path,
        "--language", request.language, "--granularity", "sentence",
        "--no-progress", "--log-level", "info",
      ], environment: environment, base: 0.85, weight: 0.10, progress: progress)
    guard fm.fileExists(atPath: staged.path), fm.fileExists(atPath: report.path) else {
      throw ReadAloudError.invalidArtifact("stalign did not produce an aligned EPUB and report")
    }

    progress(
      .init(
        stage: .verifying, stageFraction: 0, overallFraction: 0.95,
        message: "Verifying embedded Media Overlays"))
    let verification = try await ReadAloudVerifier.verifyPublished(
      epub: staged, ffprobe: tools.ffprobe, environment: environment)
    try Task.checkCancellation()
    try fm.createDirectory(
      at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    let publish = output.deletingLastPathComponent().appendingPathComponent(
      ".\(UUID().uuidString).readaloud")
    try? fm.removeItem(at: publish)
    defer { try? fm.removeItem(at: publish) }
    try fm.copyItem(at: staged, to: publish)
    if fm.fileExists(atPath: output.path) {
      guard request.overwrite else { throw ReadAloudError.outputExists(output.path) }
      _ = try fm.replaceItemAt(output, withItemAt: publish)
    } else {
      try fm.moveItem(at: publish, to: output)
    }
    progress(
      .init(stage: .verifying, stageFraction: 1, overallFraction: 1, message: "ReadAloud verified"))
    return verification
  }

  private func runStage(
    _ stage: ReadAloudStage, arguments: [String], environment: [String: String],
    base: Double, weight: Double,
    progress: @escaping @Sendable (ReadAloudProgress) -> Void
  ) async throws {
    progress(.init(stage: stage, stageFraction: 0, overallFraction: base, message: stage.rawValue))
    let parser = AdvisoryProgressParser { fraction in
      progress(
        .init(
          stage: stage, stageFraction: fraction, overallFraction: base + weight * fraction,
          message: stage.rawValue))
    }
    let result = try await runner.run(
      executable: tools.stalign, arguments: arguments, environment: environment,
      onStderr: { parser.consume($0) })
    try Task.checkCancellation()
    if result.status != 0 {
      throw ReadAloudError.processFailed(
        String(decoding: result.stderr.suffix(4_096), as: UTF8.self))
    }
    progress(
      .init(stage: stage, stageFraction: 1, overallFraction: base + weight, message: stage.rawValue)
    )
  }

  private func childEnvironment(work: URL) -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    let home = work.deletingLastPathComponent().appendingPathComponent(
      "tool-home", isDirectory: true)
    try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let temporary = work.appendingPathComponent("tmp", isDirectory: true)
    try? FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    environment["HOME"] = home.path
    environment["TMPDIR"] = temporary.path
    let toolDirectory = tools.ffmpeg.deletingLastPathComponent().path
    environment["PATH"] = toolDirectory + ":" + (environment["PATH"] ?? "")
    return environment
  }

  private func validateProcessed(
    _ directory: URL, environment: [String: String]
  ) async throws -> Bool {
    guard FileManager.default.fileExists(atPath: directory.path) else { return false }
    let files = try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: [.fileSizeKey]
    )
    .filter { $0.pathExtension.lowercased() == "mp4" }
    guard !files.isEmpty,
      files.allSatisfy({ ((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0 })
    else { return false }
    for file in files {
      let probe = try await runner.run(
        executable: tools.ffprobe,
        arguments: [
          "-v", "error", "-select_streams", "a:0",
          "-show_entries", "stream=codec_name,sample_rate,channels", "-of", "json", file.path,
        ], environment: environment)
      guard probe.status == 0,
        let object = try? JSONSerialization.jsonObject(with: probe.stdout) as? [String: Any],
        let streams = object["streams"] as? [[String: Any]], let stream = streams.first,
        stream["codec_name"] as? String == "opus",
        String(describing: stream["sample_rate"] ?? "") == "48000",
        stream["channels"] as? Int == 1
      else { return false }
    }
    return true
  }

  private func validateTranscriptions(_ directory: URL) throws -> Bool {
    guard FileManager.default.fileExists(atPath: directory.path) else { return false }
    let files = try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil
    )
    .filter { $0.pathExtension.lowercased() == "json" }
    guard !files.isEmpty else { return false }
    return files.allSatisfy { url in
      guard let data = try? Data(contentsOf: url),
        let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        value["transcript"] is String, value["timeline"] is [Any]
      else { return false }
      return true
    }
  }

  private func reset(_ url: URL) throws {
    try? FileManager.default.removeItem(at: url)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }

  private struct Manifest: Codable {
    var schemaVersion = 1
    var fingerprint: String
    var completed: Set<ReadAloudStage>
  }

  private func loadManifest(_ url: URL, fingerprint: String) throws -> Manifest {
    if let data = try? Data(contentsOf: url),
      let value = try? JSONDecoder().decode(Manifest.self, from: data),
      value.schemaVersion == 1, value.fingerprint == fingerprint
    {
      return value
    }
    try? FileManager.default.removeItem(
      at: url.deletingLastPathComponent().appendingPathComponent("processed"))
    try? FileManager.default.removeItem(
      at: url.deletingLastPathComponent().appendingPathComponent("transcriptions"))
    return Manifest(fingerprint: fingerprint, completed: [])
  }

  private func save(_ value: Manifest, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(value)
    let temporary = url.appendingPathExtension(UUID().uuidString)
    try data.write(to: temporary)
    if FileManager.default.fileExists(atPath: url.path) {
      _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    } else {
      try FileManager.default.moveItem(at: temporary, to: url)
    }
  }

  package func requestFingerprint(_ request: ReadAloudRequest) throws -> String {
    var value = request
    value.outputPath = ""
    value.workDirectory = ""
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(value)
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
      + ":\(try ReadAloudTools.sha256(URL(fileURLWithPath: request.epubPath)))"
      + ":\(try ReadAloudTools.sha256(URL(fileURLWithPath: request.audiobookPath)))"
      + ":\(tools.stalignVersion):\(tools.stalignSHA256)"
  }
}

private final class AdvisoryProgressParser: @unchecked Sendable {
  private let lock = NSLock()
  private var last = 0.0
  private let callback: @Sendable (Double) -> Void
  init(callback: @escaping @Sendable (Double) -> Void) { self.callback = callback }
  func consume(_ value: String) {
    let pattern = /Progress:\s*(\d{1,3})%/
    for match in value.matches(of: pattern) {
      guard let amount = Double(match.1), amount <= 100 else { continue }
      lock.withLock {
        let fraction = amount / 100
        guard fraction >= last else { return }
        last = fraction
        callback(fraction)
      }
    }
  }
}

import Foundation
import XCTest

@testable import ReadAloudKit

final class ReadAloudTests: XCTestCase {
  func testRequestPolicy() throws {
    let value = ReadAloudRequest(
      epubPath: "a.epub", audiobookPath: "a.m4b", outputPath: "out.epub",
      workDirectory: "work")
    try value.validate()
    var bad = value
    bad.opusBitrateKbps = 128
    XCTAssertThrowsError(try bad.validate())
    bad = value
    bad.outputPath = bad.epubPath
    XCTAssertThrowsError(try bad.validate(), "publishing must not replace the source EPUB")
  }

  func testProcessRunnerCapturesStatusAndOutput() async throws {
    let runner = ExternalProcessRunner()
    let value = try await runner.run(
      executable: URL(fileURLWithPath: "/bin/sh"),
      arguments: ["-c", "printf output; printf error >&2; exit 7"],
      environment: ProcessInfo.processInfo.environment)
    XCTAssertEqual(value.status, 7)
    XCTAssertEqual(String(decoding: value.stdout, as: UTF8.self), "output")
    XCTAssertEqual(String(decoding: value.stderr, as: UTF8.self), "error")
  }

  func testResumeFingerprintIsCanonicalAndContentSensitive() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let epub = root.appendingPathComponent("book.epub")
    let audio = root.appendingPathComponent("book.m4b")
    try Data("epub".utf8).write(to: epub)
    try Data("audio".utf8).write(to: audio)
    let tool = URL(fileURLWithPath: "/usr/bin/true")
    let backend = StalignReadAloudBackend(
      tools: .init(
        stalign: tool, ffmpeg: tool, ffprobe: tool,
        stalignVersion: "test", stalignSHA256: "hash"))
    var request = ReadAloudRequest(
      epubPath: epub.path, audiobookPath: audio.path,
      outputPath: root.appendingPathComponent("one.epub").path,
      workDirectory: root.appendingPathComponent("work-one").path)
    let first = try backend.requestFingerprint(request)
    request.outputPath = root.appendingPathComponent("two.epub").path
    request.workDirectory = root.appendingPathComponent("work-two").path
    XCTAssertEqual(first, try backend.requestFingerprint(request))
    try Data("changed audio".utf8).write(to: audio)
    XCTAssertNotEqual(first, try backend.requestFingerprint(request))
  }

  func testStatusZeroWithoutArtifactsIsRejected() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let empty = root.appendingPathComponent("empty")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: empty)
    _ = chmod(empty.path, 0o700)
    let source = root.appendingPathComponent("book.epub")
    let audio = root.appendingPathComponent("book.m4b")
    let staleAudio = root.appendingPathComponent("old.m4b")
    try Data([1]).write(to: source)
    try Data([1]).write(to: audio)
    try Data([2]).write(to: staleAudio)
    let input = root.appendingPathComponent("work/input")
    try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: input.appendingPathComponent(audio.lastPathComponent), withDestinationURL: staleAudio)
    let backend = StalignReadAloudBackend(
      tools: ReadAloudToolchain(
        stalign: empty, ffmpeg: empty, ffprobe: empty,
        stalignVersion: "test", stalignSHA256: "test"))
    do {
      _ = try await backend.create(
        request: ReadAloudRequest(
          epubPath: source.path, audiobookPath: audio.path,
          outputPath: root.appendingPathComponent("out.epub").path,
          workDirectory: root.appendingPathComponent("work").path),
        progress: { _ in })
      XCTFail("missing semantic outputs must fail even when the tool exits zero")
    } catch let error as ReadAloudError {
      guard case .invalidArtifact = error else { return XCTFail("unexpected error \(error)") }
      XCTAssertTrue(
        FileManager.default.fileExists(
          atPath: root.appendingPathComponent("work/tmp").path),
        "the controlled TMPDIR must exist before stalign starts")
      let destination = try FileManager.default.destinationOfSymbolicLink(
        atPath: input.appendingPathComponent(audio.lastPathComponent).path)
      XCTAssertEqual(destination, audio.path)
    }
  }
}

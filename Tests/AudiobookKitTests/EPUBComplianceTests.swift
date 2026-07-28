import CryptoKit
import DocumentIOKit
import Foundation
import XCTest

@testable import EPUBKit

final class EPUBComplianceTests: XCTestCase {
  private var cleanupURLs: [URL] = []

  override func tearDown() {
    cleanupURLs.forEach { try? FileManager.default.removeItem(at: $0) }
    cleanupURLs = []
    super.tearDown()
  }

  func testEPUB3IsValidatedWithoutConversion() async throws {
    let source = try EPUBFixture.spineOnlyShape().write()
    cleanupURLs.append(source)
    let checker = try checkerScript()

    let prepared = try await EPUBCompliance.prepare(
      source: source,
      toolchain: .init(epubcheck: checker, ebookConvert: nil))
    defer { prepared.cleanup() }

    XCTAssertEqual(prepared.url, source)
    XCTAssertFalse(prepared.wasConverted)
    XCTAssertEqual(prepared.sourceVersion, "3.0")
    XCTAssertEqual(prepared.conformance.checkerVersion, "test-5.3.0")
    XCTAssertEqual(prepared.conformance.warningCount, 1)
  }

  func testEPUB2IsConvertedThenIndependentlyValidated() async throws {
    let source = try EPUBFixture.epub2Shape().write()
    let converted = try EPUBFixture.spineOnlyShape().write()
    cleanupURLs += [source, converted]
    let checker = try checkerScript()
    let converter = try converterScript(copying: converted)

    let prepared = try await EPUBCompliance.prepare(
      source: source,
      toolchain: .init(epubcheck: checker, ebookConvert: converter))
    defer { prepared.cleanup() }

    XCTAssertTrue(prepared.wasConverted)
    XCTAssertEqual(prepared.sourceVersion, "2.0")
    XCTAssertNotEqual(prepared.url, source)
    XCTAssertEqual(try EPUBCompliance.packageVersion(at: prepared.url), "3.0")
    XCTAssertEqual(prepared.conformance.errorCount, 0)
  }

  func testEPUB2WithoutCalibreFailsBeforeProcessing() async throws {
    let source = try EPUBFixture.epub2Shape().write()
    cleanupURLs.append(source)
    let checker = try checkerScript()

    do {
      _ = try await EPUBCompliance.prepare(
        source: source,
        toolchain: .init(epubcheck: checker, ebookConvert: nil))
      XCTFail("EPUB 2 must not be relabeled without a real converter")
    } catch let error as EPUBComplianceError {
      XCTAssertEqual(error, .missingCalibre(sourceVersion: "2.0"))
    }
  }

  func testEPUBCheckErrorsRejectAnOtherwiseParseableEPUB3() async throws {
    let source = try EPUBFixture.spineOnlyShape().write()
    cleanupURLs.append(source)
    let checker = try checkerScript(errors: 2, exitStatus: 1)

    do {
      _ = try await EPUBCompliance.validateEPUB3(
        at: source, toolchain: .init(epubcheck: checker))
      XCTFail("EPUBCheck errors must fail closed")
    } catch let error as EPUBComplianceError {
      XCTAssertEqual(error, .nonconforming(fatal: 0, errors: 2))
    }
  }

  func testRealEPUB2ConversionIsDeterministicWhenConfigured() async throws {
    guard let path = ProcessInfo.processInfo.environment["EPUB2_CONVERSION_TEST_EPUB"] else {
      throw XCTSkip("set EPUB2_CONVERSION_TEST_EPUB to a real EPUB 2 publication")
    }
    let source = URL(fileURLWithPath: path)
    let first = try await EPUBCompliance.prepare(source: source)
    defer { first.cleanup() }
    let second = try await EPUBCompliance.prepare(source: source)
    defer { second.cleanup() }
    guard first.wasConverted, second.wasConverted else {
      throw XCTSkip("EPUB2_CONVERSION_TEST_EPUB is already EPUB 3")
    }
    let firstArchive = try ZIPArchive(url: first.url, limits: .publication)
    let secondArchive = try ZIPArchive(url: second.url, limits: .publication)
    let firstPaths = firstArchive.entries.map(\.path)
    let secondPaths = secondArchive.entries.map(\.path)
    XCTAssertEqual(firstPaths, secondPaths)
    let differing = firstPaths.filter { path in
      guard let left = firstArchive.entry(at: path), let right = secondArchive.entry(at: path)
      else { return true }
      return (try? firstArchive.data(for: left)) != (try? secondArchive.data(for: right))
    }
    XCTAssertEqual(differing, [], "Calibre entry payloads must be deterministic")
    XCTAssertEqual(
      try digest(first.url), try digest(second.url),
      "canonicalized Calibre output must have stable content identity")
  }

  private func digest(_ url: URL) throws -> String {
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

  private func checkerScript(errors: Int = 0, exitStatus: Int32 = 0) throws -> URL {
    let directory = try scratch()
    let script = directory.appendingPathComponent("epubcheck")
    let body = """
      #!/bin/sh
      if [ "$1" = "--version" ]; then
        echo "EPUBCheck vtest-5.3.0"
        exit 0
      fi
      report=""
      while [ "$#" -gt 0 ]; do
        if [ "$1" = "--json" ]; then
          shift
          report="$1"
        fi
        shift
      done
      printf '%s' '{"checker":{"checkerVersion":"test-5.3.0","nFatal":0,"nError":\(errors),"nWarning":1,"nUsage":0},"publication":{"ePubVersion":"3.0"}}' > "$report"
      exit \(exitStatus)
      """
    try Data(body.utf8).write(to: script)
    XCTAssertEqual(chmod(script.path, 0o700), 0)
    return script
  }

  private func converterScript(copying fixture: URL) throws -> URL {
    let directory = try scratch()
    let script = directory.appendingPathComponent("ebook-convert")
    let body = """
      #!/bin/sh
      cp '\(fixture.path)' "$2"
      """
    try Data(body.utf8).write(to: script)
    XCTAssertEqual(chmod(script.path, 0o700), 0)
    return script
  }

  private func scratch() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "epub-compliance-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    cleanupURLs.append(directory)
    return directory
  }
}

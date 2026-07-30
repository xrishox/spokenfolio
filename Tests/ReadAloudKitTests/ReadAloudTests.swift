import AVFoundation
import Foundation
import Speech
import XCTest

@testable import ReadAloudKit

final class ReadAloudTests: XCTestCase {
  func testSynthesisTimelineCreationDoesNotRunFreshASR() {
    XCTAssertFalse(
      StalignReadAloudBackend.usesFreshASRForCreation(.synthesis))
    XCTAssertTrue(
      StalignReadAloudBackend.usesFreshASRForCreation(.apple),
      "standalone import modes may still use recognition evidence")
  }

  private func makeReadAloudFixture(
    clips: String, linkOverlay: Bool = true,
    text: String = "The quick brown fox crosses the quiet field.",
    // A second overlay document whose name ("a-second.smil") enumerates
    // BEFORE chapter.smil in the archive, for cross-document ordering tests.
    earlierEnumeratedClips: String? = nil
  ) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let source = root.appendingPathComponent("source")
    try FileManager.default.createDirectory(
      at: source.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: source.appendingPathComponent("OEBPS"), withIntermediateDirectories: true)
    try Data("application/epub+zip".utf8).write(to: source.appendingPathComponent("mimetype"))
    try Data(
      """
      <?xml version="1.0"?>
      <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
        <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
      </container>
      """.utf8
    ).write(to: source.appendingPathComponent("META-INF/container.xml"))
    let overlay = linkOverlay ? " media-overlay=\"smil\"" : ""
    try Data(
      """
      <?xml version="1.0"?>
      <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
          <dc:identifier id="id">fixture</dc:identifier><dc:title>Fixture</dc:title><dc:language>en</dc:language>
        </metadata>
        <manifest>
          <item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"\(overlay)/>
          <item id="smil" href="chapter.smil" media-type="application/smil+xml"/>
          \(earlierEnumeratedClips == nil
            ? ""
            : """
              <item id="second" href="second.xhtml" media-type="application/xhtml+xml" media-overlay="smil2"/>
              <item id="smil2" href="a-second.smil" media-type="application/smil+xml"/>
              """)
          <item id="audio" href="audio.mp4" media-type="audio/ogg; codecs=opus"/>
        </manifest>
        <spine><itemref idref="chapter"/>\(earlierEnumeratedClips == nil ? "" : "<itemref idref=\"second\"/>")</spine>
      </package>
      """.utf8
    ).write(to: source.appendingPathComponent("OEBPS/content.opf"))
    try Data(
      """
      <html xmlns="http://www.w3.org/1999/xhtml"><head><title>Chapter</title></head>
      <body><p id="s1">\(text)</p></body></html>
      """.utf8
    ).write(to: source.appendingPathComponent("OEBPS/chapter.xhtml"))
    try Data(
      """
      <smil xmlns="http://www.w3.org/ns/SMIL" version="3.0"><body><seq>\(clips)</seq></body></smil>
      """.utf8
    ).write(to: source.appendingPathComponent("OEBPS/chapter.smil"))
    if let earlierEnumeratedClips {
      try Data(
        """
        <html xmlns="http://www.w3.org/1999/xhtml"><head><title>Second</title></head>
        <body><p id="s2">A later chapter that continues the same audio track.</p></body></html>
        """.utf8
      ).write(to: source.appendingPathComponent("OEBPS/second.xhtml"))
      try Data(
        """
        <smil xmlns="http://www.w3.org/ns/SMIL" version="3.0"><body><seq>\(earlierEnumeratedClips)</seq></body></smil>
        """.utf8
      ).write(to: source.appendingPathComponent("OEBPS/a-second.smil"))
    }
    try Data([0, 1, 2, 3]).write(to: source.appendingPathComponent("OEBPS/audio.mp4"))
    let output = root.appendingPathComponent("fixture.epub")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    process.currentDirectoryURL = source
    process.arguments = ["-q", "-X", "-r", output.path, "."]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return output
  }

  func testWholeBookStageDeadlineScalesWithAudioAndStaysBounded() {
    // Floor: short books keep the historical 30-minute budget.
    XCTAssertEqual(ReadAloudDeadlines.wholeBookStage(totalAudioSeconds: 0), .seconds(1_800))
    XCTAssertEqual(ReadAloudDeadlines.wholeBookStage(totalAudioSeconds: 600), .seconds(1_800))
    // A 14-hour book (measured timeout case) gets hours, not 30 minutes.
    let fourteenHours = ReadAloudDeadlines.wholeBookStage(totalAudioSeconds: 14 * 3_600)
    XCTAssertGreaterThan(fourteenHours, .seconds(10 * 3_600))
    // Ceiling: even absurd inputs stay bounded so hung tools are caught.
    XCTAssertEqual(
      ReadAloudDeadlines.wholeBookStage(totalAudioSeconds: 1e9), .seconds(43_200))
    XCTAssertEqual(
      ReadAloudDeadlines.wholeBookStage(totalAudioSeconds: .infinity), .seconds(1_800))
  }

  /// Manual experiment (env-gated, never in CI): does DictationTranscriber
  /// with a book-trained custom language model recognize proper names better
  /// than the uncustomizable long-form SpeechTranscriber? Prints comparative
  /// vocabulary hit counts per track; policy decisions come from this data.
  /// Set READALOUD_ASR_EXPERIMENT_AUDIO (dir of processed .mp4 tracks),
  /// READALOUD_ASR_EXPERIMENT_EPUB (source EPUB), READALOUD_ASR_EXPERIMENT_FFMPEG.
  func testDictationTranscriberCustomLanguageModelExperiment() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let audioDir = env["READALOUD_ASR_EXPERIMENT_AUDIO"],
      let epubPath = env["READALOUD_ASR_EXPERIMENT_EPUB"],
      let ffmpeg = env["READALOUD_ASR_EXPERIMENT_FFMPEG"]
    else { throw XCTSkip("set READALOUD_ASR_EXPERIMENT_{AUDIO,EPUB,FFMPEG}") }
    guard #available(macOS 26.0, *) else { throw XCTSkip("requires macOS 26") }
    let limit = Int(env["READALOUD_ASR_EXPERIMENT_LIMIT"] ?? "3") ?? 3
    let resolvedLocale = await SpeechTranscriber.supportedLocale(
      equivalentTo: Locale(identifier: "en-US"))
    let locale = try XCTUnwrap(resolvedLocale)

    let vocabulary = BookVocabulary.terms(sourceEPUB: URL(fileURLWithPath: epubPath))
    XCTAssertFalse(vocabulary.isEmpty)
    let work = FileManager.default.temporaryDirectory
      .appendingPathComponent("asr-experiment-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: work) }

    // Train the custom language model from the book's own terms.
    let data = SFCustomLanguageModelData(
      locale: locale, identifier: "com.xrishox.spokenfolio.asr-experiment", version: "1")
    for term in vocabulary { data.insert(phraseCount: .init(phrase: term, count: 10)) }
    let asset = work.appendingPathComponent("book-lm.bin")
    try await data.export(to: asset)
    let configuration = SFSpeechLanguageModel.Configuration(
      languageModel: work.appendingPathComponent("book.lm"),
      vocabulary: work.appendingPathComponent("book.vocab"))
    try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
      SFSpeechLanguageModel.prepareCustomLanguageModel(
        for: asset, configuration: configuration
      ) { error in
        if let error { c.resume(throwing: error) } else { c.resume() }
      }
    }

    let installModules: [any SpeechModule] = [
      SpeechTranscriber(
        locale: locale, transcriptionOptions: [], reportingOptions: [],
        attributeOptions: [.audioTimeRange]),
      DictationTranscriber(
        locale: locale,
        contentHints: [.customizedLanguage(modelConfiguration: configuration)],
        transcriptionOptions: [], reportingOptions: [],
        attributeOptions: [.audioTimeRange]),
    ]
    if let request = try await AssetInventory.assetInstallationRequest(
      supporting: installModules)
    {
      try await request.downloadAndInstall()
    }

    let tracks = try FileManager.default.contentsOfDirectory(
      at: URL(fileURLWithPath: audioDir), includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "mp4" }.sorted { $0.path < $1.path }.prefix(limit)

    func decode(_ input: URL) throws -> URL {
      let wav = work.appendingPathComponent(UUID().uuidString + ".wav")
      let p = Process()
      p.executableURL = URL(fileURLWithPath: ffmpeg)
      p.arguments = [
        "-hide_banner", "-loglevel", "error", "-y", "-i", input.path,
        "-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", wav.path,
      ]
      try p.run()
      p.waitUntilExit()
      guard p.terminationStatus == 0 else { throw CocoaError(.fileReadUnknown) }
      return wav
    }

    func hits(_ text: String) -> Int {
      vocabulary.prefix(300).filter { text.contains($0) }.count
    }

    for track in tracks {
      let wav = try decode(track)
      var texts: [String: String] = [:]

      let plain = SpeechTranscriber(
        locale: locale, transcriptionOptions: [], reportingOptions: [],
        attributeOptions: [.audioTimeRange])
      let plainAnalyzer = SpeechAnalyzer(
        modules: [plain], options: .init(priority: .userInitiated, modelRetention: .whileInUse))
      let plainCollector = Task {
        var t = ""
        for try await r in plain.results where r.isFinal {
          t += String(r.text.characters)
        }
        return t
      }
      _ = try await plainAnalyzer.analyzeSequence(from: try AVAudioFile(forReading: wav))
      try await plainAnalyzer.finalizeAndFinishThroughEndOfInput()
      texts["speech"] = try await plainCollector.value

      let dictation = DictationTranscriber(
        locale: locale,
        contentHints: [.customizedLanguage(modelConfiguration: configuration)],
        transcriptionOptions: [], reportingOptions: [],
        attributeOptions: [.audioTimeRange])
      let dictationAnalyzer = SpeechAnalyzer(
        modules: [dictation],
        options: .init(priority: .userInitiated, modelRetention: .whileInUse))
      let dictationCollector = Task {
        var t = ""
        for try await r in dictation.results where r.isFinal {
          t += String(r.text.characters)
        }
        return t
      }
      _ = try await dictationAnalyzer.analyzeSequence(from: try AVAudioFile(forReading: wav))
      try await dictationAnalyzer.finalizeAndFinishThroughEndOfInput()
      texts["dictation+lm"] = try await dictationCollector.value

      let name = track.lastPathComponent
      print("EXPERIMENT \(name): speech hits=\(hits(texts["speech"] ?? ""))"
        + " dictation+lm hits=\(hits(texts["dictation+lm"] ?? ""))")
      print("  speech:      \((texts["speech"] ?? "").prefix(160))")
      print("  dictation+lm:\((texts["dictation+lm"] ?? "").prefix(160))")
      XCTAssertFalse((texts["dictation+lm"] ?? "").isEmpty)
    }
  }

  func testBookVocabularyExtractsProperTermsOnly() {
    let text = """
      The queen watched Daenerys Targaryen cross the bay. Daenerys spoke to
      Missandei while the crowd waited. Watch the watch turn: Watch is also a
      common word here, and the walls of Meereen stood silent. Dalla's son
      slept.
      """
    let terms = BookVocabulary.terms(in: text)
    XCTAssertTrue(terms.contains("Daenerys"), "capitalized-only names are hints")
    XCTAssertTrue(terms.contains("Missandei"))
    XCTAssertTrue(terms.contains("Meereen"))
    XCTAssertTrue(terms.contains("Dalla"), "possessives are reduced to the name")
    XCTAssertFalse(terms.contains("The"), "words also seen lowercase are not names")
    XCTAssertFalse(terms.contains("Watch"), "sentence-case of common words is excluded")
    XCTAssertEqual(terms.first, "Daenerys", "most frequent name leads the hint list")
    XCTAssertLessThanOrEqual(terms.count, BookVocabulary.maximumTerms)
  }

  func testRequestPolicy() throws {
    let value = ReadAloudRequest(
      epubPath: "a.epub", audiobookPath: "a.m4b", outputPath: "out.epub",
      workDirectory: "work")
    try value.validate()
    XCTAssertEqual(value.asr, .apple)
    var bad = value
    bad.opusBitrateKbps = 128
    XCTAssertThrowsError(try bad.validate())
    bad = value
    bad.outputPath = bad.epubPath
    XCTAssertThrowsError(try bad.validate(), "publishing must not replace the source EPUB")

    bad = value
    bad.asr = .whisperTurbo
    try bad.validate()
    XCTAssertEqual(bad.asr.whisperModel, .largeV3Turbo)
    bad.language = "fr-FR"
    bad.asr = .whisper(ReadAloudWhisperModel(rawValue: "small.en")!)
    XCTAssertThrowsError(try bad.validate())
    bad = value
    bad.asr = .apple
    try bad.validate()
    bad.expectedExistingSHA256 = String(repeating: "a", count: 64)
    XCTAssertThrowsError(try bad.validate())
    bad.overwrite = true
    XCTAssertNoThrow(try bad.validate())
    bad.asr = .init(engine: .whisper, whisperModel: nil)
    XCTAssertThrowsError(try bad.validate())
  }

  func testLegacyRequestDecodesAsWhisperTinyWithoutBeingRewritten() throws {
    let data = Data(
      """
      {"schemaVersion":1,"epubPath":"a.epub","audiobookPath":"a.m4b",\
      "outputPath":"out.epub","workDirectory":"work","opusBitrateKbps":32,\
      "language":"en-US","whisperModel":"tiny","overwrite":false}
      """.utf8)
    let request = try JSONDecoder().decode(ReadAloudRequest.self, from: data)
    XCTAssertEqual(request.schemaVersion, 1)
    XCTAssertEqual(request.asr, .whisper(.tiny))
    try request.validate()
    let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request))
      as? [String: Any]
    XCTAssertEqual(encoded?["whisperModel"] as? String, "tiny")
    XCTAssertNil(encoded?["asr"])
  }

  func testStalignTranscriptValidatesUnicodeOffsetsAndZeroDurationEntries() throws {
    let value = StalignTranscript(timedEntries: [
      .init(type: "word", text: "Hello", startTime: 0, endTime: 0.5, confidence: 0.9),
      .init(type: "word", text: "🪐", startTime: 0.5, endTime: 0.5, confidence: 1),
      .init(type: "segment", text: "wide world", startTime: 0.5, endTime: 1.2),
    ])
    XCTAssertEqual(value.transcript, "Hello 🪐 wide world")
    XCTAssertEqual(value.timeline[1].endOffsetUtf16 - value.timeline[1].startOffsetUtf16, 2)
    XCTAssertEqual(value.timeline[1].endOffsetUtf32 - value.timeline[1].startOffsetUtf32, 1)
    XCTAssertNoThrow(try StalignTranscriptValidator.validate(value, audioDuration: 1.2))

    var invalid = value
    invalid.timeline[1].startOffsetUtf16 += 1
    XCTAssertThrowsError(
      try StalignTranscriptValidator.validate(invalid, audioDuration: 1.2))
    invalid = value
    invalid.timeline[2].confidence = 1.1
    XCTAssertThrowsError(
      try StalignTranscriptValidator.validate(invalid, audioDuration: 1.2))
    invalid = value
    invalid.timeline[2].endTime = 2.3
    XCTAssertThrowsError(
      try StalignTranscriptValidator.validate(invalid, audioDuration: 1.2))
    // stalign's own Whisper transcripts legitimately overshoot the audio end
    // (whisper.cpp segment tails; measured 20.9s past EOF on a healthy
    // track), so stalign-produced transcripts skip the ceiling while every
    // structural rule still applies.
    XCTAssertNoThrow(
      try StalignTranscriptValidator.validate(
        invalid, audioDuration: 1.2, enforceDurationCeiling: false))
    var disordered = invalid
    disordered.timeline[1].startOffsetUtf16 += 1
    XCTAssertThrowsError(
      try StalignTranscriptValidator.validate(
        disordered, audioDuration: 1.2, enforceDurationCeiling: false))
  }

  func testHeadingNormalizerRepairsOnlyUniqueShortRomanHeading() throws {
    let value = StalignTranscript(timedEntries: [
      .init(type: "word", text: "V", startTime: 0.18, endTime: 1.44),
      .init(type: "word", text: "Believers", startTime: 1.45, endTime: 2),
      .init(type: "word", text: "in", startTime: 2, endTime: 2.2),
      .init(type: "word", text: "a", startTime: 2.2, endTime: 2.3),
      .init(type: "word", text: "forgotten", startTime: 2.3, endTime: 3),
      .init(type: "word", text: "world", startTime: 3, endTime: 4.5),
    ])
    let normalizer = EPUBHeadingTranscriptNormalizer(
      candidates: ["Part Five Believers in a forgotten world"])
    let repaired = normalizer.normalize(value, audioDuration: 4.85)
    XCTAssertEqual(repaired.repairCount, 1)
    XCTAssertEqual(repaired.transcript.timeline[0].text, "Part 5.")
    XCTAssertNoThrow(
      try StalignTranscriptValidator.validate(repaired.transcript, audioDuration: 4.85))

    let ambiguous = EPUBHeadingTranscriptNormalizer(candidates: [
      "Part Five Believers in a forgotten world",
      "Book Five Believers in a forgotten world",
    ])
    XCTAssertEqual(ambiguous.normalize(value, audioDuration: 4.85).repairCount, 0)
    XCTAssertEqual(normalizer.normalize(value, audioDuration: 31).repairCount, 0)
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

  func testProcessRunnerTimesOutAndDoesNotShareProcessState() async throws {
    let runner = ExternalProcessRunner()
    async let quick = runner.run(
      executable: URL(fileURLWithPath: "/bin/echo"), arguments: ["quick"],
      environment: ProcessInfo.processInfo.environment, timeout: .seconds(2))
    do {
      _ = try await runner.run(
        executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"],
        environment: ProcessInfo.processInfo.environment, timeout: .milliseconds(50))
      XCTFail("sleeping tool exceeded its deadline")
    } catch let error as ExternalProcessError {
      XCTAssertEqual(error, .timedOut)
    }
    let quickResult = try await quick
    XCTAssertEqual(String(decoding: quickResult.stdout, as: UTF8.self), "quick\n")
  }

  func testWhisperProviderPassesTurboModelWithoutInventingEnglishSuffix() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let processed = root.appendingPathComponent("processed")
    let output = root.appendingPathComponent("transcriptions")
    let home = root.appendingPathComponent("home")
    try FileManager.default.createDirectory(at: processed, withIntermediateDirectories: true)
    let capture = root.appendingPathComponent("arguments")
    let tool = root.appendingPathComponent("stalign")
    try Data(
      "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$CAPTURE\"\n".utf8
    ).write(to: tool)
    _ = chmod(tool.path, 0o700)
    let provider = StalignWhisperTranscriber(
      model: .largeV3Turbo,
      tools: .init(
        stalign: tool, ffmpeg: tool, ffprobe: tool, epubcheck: tool,
        stalignVersion: "test", stalignSHA256: "test", epubcheckVersion: "test"))
    try await provider.transcribe(
      .init(
        processedAudio: processed, transcriptions: output,
        sourceEPUB: root.appendingPathComponent("book.epub"), language: "en-US",
        temporaryDirectory: root.appendingPathComponent("tmp"),
        environment: ["HOME": home.path, "CAPTURE": capture.path]),
      progress: { _, _ in })
    let arguments = try String(contentsOf: capture, encoding: .utf8)
    XCTAssertTrue(arguments.contains("large-v3-turbo\n"))
    XCTAssertFalse(arguments.contains("large-v3-turbo.en"))
  }

  @available(macOS 26.0, *)
  func testRealAppleSpeechProviderWhenConfigured() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let audioPath = environment["READALOUD_TEST_APPLE_AUDIO"],
      let epubPath = environment["READALOUD_TEST_APPLE_EPUB"],
      let stalignPath = environment["READALOUD_TEST_STALIGN"]
    else {
      throw XCTSkip(
        "Set READALOUD_TEST_APPLE_AUDIO, READALOUD_TEST_APPLE_EPUB, and READALOUD_TEST_STALIGN")
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let processed = root.appendingPathComponent("processed")
    let transcriptions = root.appendingPathComponent("transcriptions")
    try FileManager.default.createDirectory(at: processed, withIntermediateDirectories: true)
    let audio = URL(fileURLWithPath: audioPath)
    try FileManager.default.linkItem(
      at: audio, to: processed.appendingPathComponent(audio.lastPathComponent))
    let tools = try await ReadAloudTools.resolve(
      managedStalign: URL(fileURLWithPath: stalignPath))
    let provider = AppleSpeechReadAloudTranscriber(tools: tools)
    try await provider.transcribe(
      .init(
        processedAudio: processed, transcriptions: transcriptions,
        sourceEPUB: URL(fileURLWithPath: epubPath), language: "en-US",
        temporaryDirectory: root.appendingPathComponent("tmp"),
        environment: ProcessInfo.processInfo.environment),
      progress: { _, _ in })
    let transcript = transcriptions.appendingPathComponent(
      audio.deletingPathExtension().lastPathComponent + ".json")
    let value = try StalignTranscriptValidator.decode(transcript)
    XCTAssertFalse(value.timeline.isEmpty)
    XCTAssertTrue(value.timeline.allSatisfy { $0.startTime.isFinite && $0.endTime.isFinite })
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
        stalign: tool, ffmpeg: tool, ffprobe: tool, epubcheck: tool,
        stalignVersion: "test", stalignSHA256: "hash", epubcheckVersion: "test"))
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
        stalign: empty, ffmpeg: empty, ffprobe: empty, epubcheck: empty,
        stalignVersion: "test", stalignSHA256: "test", epubcheckVersion: "test"))
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
      let staged = input.appendingPathComponent(audio.lastPathComponent)
      XCTAssertEqual(try Data(contentsOf: staged), try Data(contentsOf: audio))
      XCTAssertThrowsError(
        try FileManager.default.destinationOfSymbolicLink(atPath: staged.path),
        "external tools must receive an immutable work copy rather than a source symlink")
    }
  }

  func testSharedAudioAcrossOverlayDocumentsVerifiesRegardlessOfEnumerationOrder() async throws {
    // Regression (1984): an audio track split by duration spans two chapters,
    // and the later-narrative overlay document enumerates FIRST in the
    // archive with high clip times. Per-document ordering must accept this;
    // cross-document accumulation used to reject it.
    let epub = try makeReadAloudFixture(
      clips: """
        <par><text src="chapter.xhtml#s1"/><audio src="audio.mp4" clipBegin="0s" clipEnd="1s"/></par>
        """,
      earlierEnumeratedClips: """
        <par><text src="second.xhtml#s2"/><audio src="audio.mp4" clipBegin="1.5s" clipEnd="2.5s"/></par>
        """)
    let root = epub.deletingLastPathComponent()
    let probe = root.appendingPathComponent("ffprobe-shared")
    try Data(
      "#!/bin/sh\nprintf '%s' '{\"streams\":[{\"codec_name\":\"opus\",\"sample_rate\":\"48000\",\"channels\":1,\"duration\":\"3.0\"}]}'\n"
        .utf8).write(to: probe)
    _ = chmod(probe.path, 0o700)
    let epubcheck = try makeEPUBCheckStub(in: root)
    let report = try await ReadAloudVerifier.verifyPublished(
      epub: epub, ffmpeg: probe, ffprobe: probe, epubcheck: epubcheck)
    XCTAssertEqual(report.smilCount, 2)

    // An overlay document with zero clips is stalign's normal output for a
    // spine item where nothing aligned; the coverage gate judges that, the
    // structural verifier must not (regression: A Feast for Crows appendix).
    let emptyOverlay = try makeReadAloudFixture(
      clips: """
        <par><text src="chapter.xhtml#s1"/><audio src="audio.mp4" clipBegin="0s" clipEnd="1s"/></par>
        """,
      earlierEnumeratedClips: "")
    let emptyReport = try await ReadAloudVerifier.verifyPublished(
      epub: emptyOverlay, ffmpeg: probe, ffprobe: probe, epubcheck: epubcheck)
    XCTAssertEqual(emptyReport.smilCount, 2)

    // Disorder WITHIN one overlay document is still a hard failure.
    let disordered = try makeReadAloudFixture(
      clips: """
        <par><text src="chapter.xhtml#s1"/><audio src="audio.mp4" clipBegin="1s" clipEnd="2s"/></par>
        <par><text src="chapter.xhtml#s1"/><audio src="audio.mp4" clipBegin="0s" clipEnd="0.5s"/></par>
        """)
    do {
      _ = try await ReadAloudVerifier.verifyPublished(
        epub: disordered, ffmpeg: probe, ffprobe: probe, epubcheck: epubcheck)
      XCTFail("in-document clip disorder must be rejected")
    } catch let error as ReadAloudError {
      guard case .invalidArtifact(let reason) = error, reason.contains("out of order") else {
        return XCTFail("unexpected error \(error)")
      }
    }
  }

  func testInspectorUsesAuthoritativeOverlayGraphAndCoverage() throws {
    let epub = try makeReadAloudFixture(
      clips: """
        <par><text src="chapter.xhtml#s1"/><audio src="audio.mp4" clipBegin="0s" clipEnd="2s"/></par>
        """)
    let value = try ReadAloudInspector.inspect(epub)
    XCTAssertEqual(value.metrics.smilCount, 1)
    XCTAssertEqual(value.metrics.audioCount, 1)
    XCTAssertEqual(value.metrics.clipCount, 1)
    XCTAssertEqual(value.metrics.primaryCoverage, 1)
    XCTAssertFalse(value.findings.contains { $0.verdict == .broken })
  }

  /// Multi-document fixture for coverage-shape tests: each document gets its
  /// own overlay (when it has clips) and all overlays share one audio track.
  private func makeCoverageFixture(
    documents: [(name: String, body: String, clips: String)]
  ) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let source = root.appendingPathComponent("source")
    try FileManager.default.createDirectory(
      at: source.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: source.appendingPathComponent("OEBPS"), withIntermediateDirectories: true)
    try Data("application/epub+zip".utf8).write(to: source.appendingPathComponent("mimetype"))
    try Data(
      """
      <?xml version="1.0"?>
      <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
        <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
      </container>
      """.utf8
    ).write(to: source.appendingPathComponent("META-INF/container.xml"))
    var manifest = ""
    var spine = ""
    for (index, document) in documents.enumerated() {
      let overlay = document.clips.isEmpty ? "" : " media-overlay=\"smil\(index)\""
      manifest +=
        "<item id=\"doc\(index)\" href=\"\(document.name).xhtml\" media-type=\"application/xhtml+xml\"\(overlay)/>"
      if !document.clips.isEmpty {
        manifest +=
          "<item id=\"smil\(index)\" href=\"\(document.name).smil\" media-type=\"application/smil+xml\"/>"
      }
      spine += "<itemref idref=\"doc\(index)\"/>"
    }
    try Data(
      """
      <?xml version="1.0"?>
      <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
          <dc:identifier id="id">coverage-fixture</dc:identifier><dc:title>Coverage</dc:title><dc:language>en</dc:language>
        </metadata>
        <manifest>
          \(manifest)
          <item id="audio" href="audio.mp4" media-type="audio/ogg; codecs=opus"/>
        </manifest>
        <spine>\(spine)</spine>
      </package>
      """.utf8
    ).write(to: source.appendingPathComponent("OEBPS/content.opf"))
    for document in documents {
      try Data(
        """
        <html xmlns="http://www.w3.org/1999/xhtml"><head><title>\(document.name)</title></head>
        <body>\(document.body)</body></html>
        """.utf8
      ).write(to: source.appendingPathComponent("OEBPS/\(document.name).xhtml"))
      if !document.clips.isEmpty {
        try Data(
          """
          <smil xmlns="http://www.w3.org/ns/SMIL" version="3.0"><body><seq>\(document.clips)</seq></body></smil>
          """.utf8
        ).write(to: source.appendingPathComponent("OEBPS/\(document.name).smil"))
      }
    }
    try Data([0, 1, 2, 3]).write(to: source.appendingPathComponent("OEBPS/audio.mp4"))
    let output = root.appendingPathComponent("coverage-fixture.epub")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    process.currentDirectoryURL = source
    process.arguments = ["-q", "-X", "-r", output.path, "."]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return output
  }

  func testInspectorToleratesScatteredInlineMarkupCoverageGaps() throws {
    // Regression (A Conflict of Visions): stalign leaves sentences that
    // inline markup interrupts (noterefs, italics, drop caps) without overlay
    // fragments. 21% of that book's tokens were omitted in scattered gaps
    // under ~50 tokens while every chapter carried hundreds of clips; the
    // coverage dimension must report review, never likelyBroken, for that
    // shape regardless of the scattered total.
    let covered = "alpha beta gamma delta epsilon zeta eta theta iota kappa"
    let tail = "lambda mu nu xi omicron pi rho sigma tau upsilon phi chi"
    var body = "<p>"
    var clips = ""
    for index in 0..<100 {
      body += "<span id=\"s\(index)\">\(covered).</span> \(tail). "
      clips +=
        "<par><text src=\"scattered.xhtml#s\(index)\"/><audio src=\"audio.mp4\" clipBegin=\"\(index)s\" clipEnd=\"\(index).5s\"/></par>"
    }
    body += "</p>"
    let epub = try makeCoverageFixture(documents: [("scattered", body, clips)])
    let inspection = try ReadAloudInspector.inspect(epub)
    XCTAssertFalse(
      inspection.findings.contains { $0.verdict == .likelyBroken || $0.verdict == .broken },
      "scattered inline-markup gaps must not read as broken narration")
    XCTAssertTrue(
      inspection.findings.contains {
        $0.code == .missingPrimaryNarration && $0.verdict == .needsReview
      }, "sub-threshold coverage still deserves review")
    XCTAssertEqual(inspection.metrics.largestPrimaryOmissionRunTokens, 12)
  }

  func testInspectorFlagsContiguousUnnarratedPassages() throws {
    let covered = "alpha beta gamma delta epsilon zeta eta theta iota kappa"
    let gap = (1...850).map { "gapword\($0)" }.joined(separator: " ")
    let midGapBody = """
      <p><span id="a1">\(covered).</span></p><p>\(gap)</p><p><span id="a2">\(covered).</span></p>
      """
    let midGapClips = """
      <par><text src="midgap.xhtml#a1"/><audio src="audio.mp4" clipBegin="0s" clipEnd="1s"/></par>
      <par><text src="midgap.xhtml#a2"/><audio src="audio.mp4" clipBegin="1s" clipEnd="2s"/></par>
      """
    let skippedBody =
      "<h1>Chapter Two</h1><p>" + (1...300).map { "skipped\($0)" }.joined(separator: " ") + "</p>"
    let epub = try makeCoverageFixture(documents: [
      ("midgap", midGapBody, midGapClips),
      ("skipped", skippedBody, ""),
    ])
    let inspection = try ReadAloudInspector.inspect(epub)
    let broken = inspection.findings.filter {
      $0.code == .missingPrimaryNarration && $0.verdict == .likelyBroken
    }
    XCTAssertEqual(
      Set(broken.compactMap(\.documentPath)), ["OEBPS/midgap.xhtml", "OEBPS/skipped.xhtml"],
      "a mid-document run and a fully unnarrated section must both stay hard failures")
  }

  func testPublishedVerifierAcceptsMonoOrStereoButRejectsMoreChannels() async throws {
    let epub = try makeReadAloudFixture(
      clips: """
        <par><text src="chapter.xhtml#s1"/><audio src="audio.mp4" clipBegin="0s" clipEnd="2s"/></par>
        """)
    let root = epub.deletingLastPathComponent()
    let probe = root.appendingPathComponent("ffprobe-channels")
    func writeProbe(channels: Int) throws {
      try Data(
        "#!/bin/sh\nprintf '%s' '{\"streams\":[{\"codec_name\":\"opus\",\"sample_rate\":\"48000\",\"channels\":\(channels),\"duration\":\"3.0\"}]}'\n"
          .utf8).write(to: probe)
      _ = chmod(probe.path, 0o700)
    }
    let epubcheck = try makeEPUBCheckStub(in: root)
    try writeProbe(channels: 1)
    _ = try await ReadAloudVerifier.verifyPublished(
      epub: epub, ffmpeg: probe, ffprobe: probe, epubcheck: epubcheck)
    try writeProbe(channels: 2)
    _ = try await ReadAloudVerifier.verifyPublished(
      epub: epub, ffmpeg: probe, ffprobe: probe, epubcheck: epubcheck)
    try writeProbe(channels: 3)
    do {
      _ = try await ReadAloudVerifier.verifyPublished(
        epub: epub, ffmpeg: probe, ffprobe: probe, epubcheck: epubcheck)
      XCTFail("ReadAloud audio with more than two channels must fail")
    } catch let error as ReadAloudError {
      guard case .invalidArtifact = error else { return XCTFail("unexpected error \(error)") }
    }
  }

  func testPublishedVerifierRequiresACompleteAudioDecode() async throws {
    let epub = try makeReadAloudFixture(
      clips: """
        <par><text src="chapter.xhtml#s1"/><audio src="audio.mp4" clipBegin="0s" clipEnd="2s"/></par>
        """)
    let root = epub.deletingLastPathComponent()
    let probe = root.appendingPathComponent("ffprobe-decode")
    try Data(
      "#!/bin/sh\nprintf '%s' '{\"streams\":[{\"codec_name\":\"opus\",\"sample_rate\":\"48000\",\"channels\":1,\"duration\":\"3.0\"}]}'\n"
        .utf8).write(to: probe)
    _ = chmod(probe.path, 0o700)
    let decoder = root.appendingPathComponent("ffmpeg-decode")
    try Data("#!/bin/sh\nexit 9\n".utf8).write(to: decoder)
    _ = chmod(decoder.path, 0o700)
    let epubcheck = try makeEPUBCheckStub(in: root)

    do {
      _ = try await ReadAloudVerifier.verifyPublished(
        epub: epub, ffmpeg: decoder, ffprobe: probe, epubcheck: epubcheck)
      XCTFail("metadata probing must not substitute for decoding the full stream")
    } catch let error as ReadAloudError {
      guard case .invalidArtifact = error else {
        return XCTFail("unexpected error \(error)")
      }
    }
  }

  func testInspectorDiagnosesMissingOverlayAndInvertedClips() throws {
    let noOverlay = try makeReadAloudFixture(clips: "", linkOverlay: false)
    let missing = try ReadAloudInspector.inspect(noOverlay)
    XCTAssertTrue(missing.findings.contains { $0.code == .noFunctionalOverlay })

    let inverted = try makeReadAloudFixture(
      clips: """
        <par><text src="chapter.xhtml#s1"/><audio src="audio.mp4" clipBegin="5s" clipEnd="2s"/></par>
        """)
    let invalid = try ReadAloudInspector.inspect(inverted)
    XCTAssertTrue(invalid.findings.contains { $0.code == .invertedClipInterval })
    XCTAssertTrue(invalid.findings.contains { $0.verdict == .broken })

    let nonfinite = try makeReadAloudFixture(
      clips: """
        <par><text src="chapter.xhtml#s1"/><audio src="audio.mp4" clipBegin="NaNs" clipEnd="2s"/></par>
        """)
    let nonfiniteValue = try ReadAloudInspector.inspect(nonfinite)
    XCTAssertTrue(nonfiniteValue.findings.contains { $0.code == .invalidClipClock })
  }

  func testQualityAuditDiagnosesWrongWorkFromBoundTranscript() async throws {
    let text = "one two three four five six seven eight nine ten eleven twelve thirteen fourteen"
    let epub = try makeReadAloudFixture(
      clips: """
        <par><text src="chapter.xhtml#s1"/><audio src="audio.mp4" clipBegin="0s" clipEnd="2s"/></par>
        """, text: text)
    let root = epub.deletingLastPathComponent()
    let transcripts = root.appendingPathComponent("transcripts")
    try FileManager.default.createDirectory(at: transcripts, withIntermediateDirectories: true)
    let unrelated = [
      "alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta",
      "theta", "iota", "kappa", "lambda", "mu", "nu", "xi",
    ]
    let transcript = StalignTranscript(timedEntries: unrelated.enumerated().map { index, text in
      .init(
        type: "word", text: text, startTime: Double(index) / 10,
        endTime: Double(index + 1) / 10)
    })
    try JSONEncoder().encode(transcript).write(
      to: transcripts.appendingPathComponent("audio.json"))
    let processed = root.appendingPathComponent("processed")
    try FileManager.default.createDirectory(at: processed, withIntermediateDirectories: true)
    let inspection = try ReadAloudInspector.inspect(epub)
    try inspection.archive.extract(
      try XCTUnwrap(inspection.audio.first?.entry),
      to: processed.appendingPathComponent("audio.mp4"))
    try TranscriptBindingManifest.write(
      processedAudio: processed, transcriptions: transcripts,
      sourceAudiobookSHA256: String(repeating: "a", count: 64),
      transcriptionFingerprint: String(repeating: "b", count: 64))
    let probe = root.appendingPathComponent("ffprobe")
    try Data(
      "#!/bin/sh\nprintf '%s' '{\"streams\":[{\"codec_name\":\"opus\",\"sample_rate\":\"48000\",\"channels\":1,\"duration\":\"3.0\"}]}'\n"
        .utf8
    )
    .write(to: probe)
    _ = chmod(probe.path, 0o700)
    let epubcheck = try makeEPUBCheckStub(in: root)
    let report = try await ReadAloudQualityAuditor().audit(
      .init(
        epub: epub, retainedTranscriptions: transcripts,
        retainedTranscriptionsAreBound: true, useFreshASR: false),
      tools: .init(
        stalign: nil, ffmpeg: probe, ffprobe: probe, epubcheck: epubcheck))
    XCTAssertEqual(report.verdict, .likelyBroken)
    XCTAssertTrue(
      report.findings.contains {
        $0.code == .possibleWorkTranslationOrLanguageMismatch
      })
    XCTAssertThrowsError(try StalignReadAloudBackend.requireAcceptableQuality(report))
  }

  func testQualityIntervalsAreHalfOpenAtAdjacentClipBoundaries() async throws {
    let first = "one two three four five six seven eight nine ten"
    let second = "A later chapter that continues the same audio track."
    let epub = try makeReadAloudFixture(
      clips: """
        <par><text src="chapter.xhtml#s1"/><audio src="audio.mp4" clipBegin="0s" clipEnd="1s"/></par>
        """, text: first,
      earlierEnumeratedClips: """
        <par><text src="second.xhtml#s2"/><audio src="audio.mp4" clipBegin="1s" clipEnd="2s"/></par>
        """)
    let root = epub.deletingLastPathComponent()
    let transcripts = root.appendingPathComponent("adjacent-transcripts")
    let processed = root.appendingPathComponent("adjacent-processed")
    try FileManager.default.createDirectory(at: transcripts, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: processed, withIntermediateDirectories: true)
    let transcript = StalignTranscript(timedEntries: [
      .init(type: "segment", text: first, startTime: 0, endTime: 1),
      .init(type: "segment", text: second, startTime: 1, endTime: 2),
    ])
    try JSONEncoder().encode(transcript).write(
      to: transcripts.appendingPathComponent("audio.json"))
    let inspection = try ReadAloudInspector.inspect(epub)
    try inspection.archive.extract(
      try XCTUnwrap(inspection.audio.first?.entry),
      to: processed.appendingPathComponent("audio.mp4"))
    try TranscriptBindingManifest.write(
      processedAudio: processed, transcriptions: transcripts,
      sourceAudiobookSHA256: String(repeating: "c", count: 64),
      transcriptionFingerprint: String(repeating: "d", count: 64))
    let probe = root.appendingPathComponent("adjacent-probe")
    try Data(
      "#!/bin/sh\nprintf '%s' '{\"streams\":[{\"codec_name\":\"opus\",\"sample_rate\":\"48000\",\"channels\":1,\"duration\":\"3.0\"}]}'\n"
        .utf8).write(to: probe)
    _ = chmod(probe.path, 0o700)
    let epubcheck = try makeEPUBCheckStub(in: root)

    let report = try await ReadAloudQualityAuditor().audit(
      .init(
        epub: epub, retainedTranscriptions: transcripts,
        retainedTranscriptionsAreBound: true, useFreshASR: false),
      tools: .init(
        stalign: nil, ffmpeg: probe, ffprobe: probe, epubcheck: epubcheck))

    XCTAssertEqual(report.evidenceAdequacy, .complete)
    XCTAssertEqual(report.metrics.clipWeightedSimilarity, 1)
    XCTAssertEqual(report.metrics.lowClipFraction, 0)
    XCTAssertFalse(report.findings.contains { $0.dimension == .timing })
  }

  func testQualityAuditScoresCoarseSegmentsAgainstAllOverlappingClips() async throws {
    let first = "The first sentence has enough words for reliable comparison."
    let second = "The second sentence also belongs to this synthesized paragraph."
    let epub = try makeReadAloudFixture(
      clips: """
        <par><text src="chapter.xhtml#s1"/><audio src="audio.mp4" clipBegin="0s" clipEnd="1s"/></par>
        <par><text src="chapter.xhtml#s2"/><audio src="audio.mp4" clipBegin="1s" clipEnd="2s"/></par>
        """,
      text: "\(first)</p><p id=\"s2\">\(second)")
    let root = epub.deletingLastPathComponent()
    let transcripts = root.appendingPathComponent("coarse-transcripts")
    let processed = root.appendingPathComponent("coarse-processed")
    try FileManager.default.createDirectory(at: transcripts, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: processed, withIntermediateDirectories: true)
    let transcript = StalignTranscript(timedEntries: [
      .init(type: "segment", text: "\(first) \(second)", startTime: 0, endTime: 2)
    ])
    try JSONEncoder().encode(transcript).write(
      to: transcripts.appendingPathComponent("audio.json"))
    let inspection = try ReadAloudInspector.inspect(epub)
    try inspection.archive.extract(
      try XCTUnwrap(inspection.audio.first?.entry),
      to: processed.appendingPathComponent("audio.mp4"))
    try TranscriptBindingManifest.write(
      processedAudio: processed, transcriptions: transcripts,
      sourceAudiobookSHA256: String(repeating: "1", count: 64),
      transcriptionFingerprint: String(repeating: "2", count: 64))
    let probe = root.appendingPathComponent("coarse-probe")
    try Data(
      "#!/bin/sh\nprintf '%s' '{\"streams\":[{\"codec_name\":\"opus\",\"sample_rate\":\"48000\",\"channels\":1,\"duration\":\"3.0\"}]}'\n"
        .utf8).write(to: probe)
    _ = chmod(probe.path, 0o700)
    let epubcheck = try makeEPUBCheckStub(in: root)

    let report = try await ReadAloudQualityAuditor().audit(
      .init(
        epub: epub, retainedTranscriptions: transcripts,
        retainedTranscriptionsAreBound: true, useFreshASR: false),
      tools: .init(
        stalign: nil, ffmpeg: probe, ffprobe: probe, epubcheck: epubcheck))

    XCTAssertEqual(report.evidenceAdequacy, .complete)
    XCTAssertEqual(report.metrics.clipWeightedSimilarity, 1)
    XCTAssertEqual(report.metrics.lowClipFraction, 0)
    XCTAssertFalse(report.findings.contains { $0.dimension == .timing })
  }

  func testQualityAuditIgnoresSubMillisecondClipRoundingAtSegmentBoundaries() async throws {
    let first = "The first synthesized paragraph has enough words."
    let second = "The second synthesized paragraph remains separate."
    let third = "The third synthesized paragraph must not absorb the second."
    let epub = try makeReadAloudFixture(
      clips: """
        <par><text src="chapter.xhtml#s1"/><audio src="audio.mp4" clipBegin="0s" clipEnd="1.907s"/></par>
        <par><text src="chapter.xhtml#s2"/><audio src="audio.mp4" clipBegin="1.907s" clipEnd="3.868s"/></par>
        <par><text src="chapter.xhtml#s3"/><audio src="audio.mp4" clipBegin="3.868s" clipEnd="24.948s"/></par>
        """,
      text: "\(first)</p><p id=\"s2\">\(second)</p><p id=\"s3\">\(third)")
    let root = epub.deletingLastPathComponent()
    let transcripts = root.appendingPathComponent("rounded-transcripts")
    let processed = root.appendingPathComponent("rounded-processed")
    try FileManager.default.createDirectory(at: transcripts, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: processed, withIntermediateDirectories: true)
    let transcript = StalignTranscript(timedEntries: [
      .init(type: "segment", text: first, startTime: 0.25, endTime: 1.3075),
      .init(type: "segment", text: second, startTime: 1.9075, endTime: 3.2675),
      .init(type: "segment", text: third, startTime: 3.8675, endTime: 24.3475),
    ])
    try JSONEncoder().encode(transcript).write(
      to: transcripts.appendingPathComponent("audio.json"))
    let inspection = try ReadAloudInspector.inspect(epub)
    try inspection.archive.extract(
      try XCTUnwrap(inspection.audio.first?.entry),
      to: processed.appendingPathComponent("audio.mp4"))
    try TranscriptBindingManifest.write(
      processedAudio: processed, transcriptions: transcripts,
      sourceAudiobookSHA256: String(repeating: "3", count: 64),
      transcriptionFingerprint: String(repeating: "4", count: 64))
    let probe = root.appendingPathComponent("rounded-probe")
    try Data(
      "#!/bin/sh\nprintf '%s' '{\"streams\":[{\"codec_name\":\"opus\",\"sample_rate\":\"48000\",\"channels\":1,\"duration\":\"25.0\"}]}'\n"
        .utf8).write(to: probe)
    _ = chmod(probe.path, 0o700)
    let epubcheck = try makeEPUBCheckStub(in: root)

    let report = try await ReadAloudQualityAuditor().audit(
      .init(
        epub: epub, retainedTranscriptions: transcripts,
        retainedTranscriptionsAreBound: true, useFreshASR: false),
      tools: .init(
        stalign: nil, ffmpeg: probe, ffprobe: probe, epubcheck: epubcheck))

    XCTAssertEqual(report.metrics.clipWeightedSimilarity, 1)
    XCTAssertEqual(report.metrics.lowClipFraction, 0)
    XCTAssertFalse(report.findings.contains { $0.dimension == .timing })
  }

  func testTranscriptBindingRejectsTranscriptMutation() async throws {
    let epub = try makeReadAloudFixture(
      clips: """
        <par><text src="chapter.xhtml#s1"/><audio src="audio.mp4" clipBegin="0s" clipEnd="2s"/></par>
        """)
    let root = epub.deletingLastPathComponent()
    let transcripts = root.appendingPathComponent("bound-transcripts")
    let processed = root.appendingPathComponent("bound-processed")
    try FileManager.default.createDirectory(at: transcripts, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: processed, withIntermediateDirectories: true)
    let transcriptURL = transcripts.appendingPathComponent("audio.json")
    try JSONEncoder().encode(
      StalignTranscript(timedEntries: [
        .init(type: "segment", text: "The quick brown fox", startTime: 0, endTime: 2)
      ])
    ).write(to: transcriptURL)
    let inspection = try ReadAloudInspector.inspect(epub)
    try inspection.archive.extract(
      try XCTUnwrap(inspection.audio.first?.entry),
      to: processed.appendingPathComponent("audio.mp4"))
    try TranscriptBindingManifest.write(
      processedAudio: processed, transcriptions: transcripts,
      sourceAudiobookSHA256: String(repeating: "e", count: 64),
      transcriptionFingerprint: String(repeating: "f", count: 64))
    XCTAssertNoThrow(
      try TranscriptBindingManifest.validate(
        transcriptions: transcripts, inspection: inspection))

    try Data("changed".utf8).write(to: transcriptURL)
    XCTAssertThrowsError(
      try TranscriptBindingManifest.validate(
        transcriptions: transcripts, inspection: inspection))
  }

  func testQualityAuditReportsEPUBComplianceSeparatelyFromAlignment() async throws {
    let epub = try makeReadAloudFixture(
      clips: """
        <par><text src="chapter.xhtml#s1"/><audio src="audio.mp4" clipBegin="0s" clipEnd="2s"/></par>
        """)
    let root = epub.deletingLastPathComponent()
    let tool = URL(fileURLWithPath: "/usr/bin/true")
    let failing = try makeEPUBCheckStub(in: root, errors: 1, exitStatus: 1)
    let report = try await ReadAloudQualityAuditor().audit(
      .init(epub: epub, useFreshASR: false),
      tools: .init(
        stalign: nil, ffmpeg: tool, ffprobe: tool, epubcheck: failing,
        epubcheckIdentity: "EPUBCheck test"))

    XCTAssertEqual(report.verdict, .broken)
    XCTAssertNil(report.epubConformance)
    XCTAssertEqual(report.findings.first?.dimension, .compatibility)
    XCTAssertEqual(report.findings.first?.code, .epubNonconforming)
  }

  func testUnboundTranscriptCannotDeclareWrongWorkOrClaimASRModel() async throws {
    let epub = try makeReadAloudFixture(
      clips: """
        <par><text src="chapter.xhtml#s1"/><audio src="audio.mp4" clipBegin="0s" clipEnd="2s"/></par>
        """, text: "one two three four five six seven eight nine ten")
    let root = epub.deletingLastPathComponent()
    let transcripts = root.appendingPathComponent("unbound")
    try FileManager.default.createDirectory(at: transcripts, withIntermediateDirectories: true)
    try Data("not even valid transcript JSON".utf8).write(
      to: transcripts.appendingPathComponent("audio.json"))
    let probe = root.appendingPathComponent("unbound-ffprobe")
    try Data(
      "#!/bin/sh\nprintf '%s' '{\"streams\":[{\"codec_name\":\"opus\",\"sample_rate\":\"48000\",\"channels\":1,\"duration\":\"3.0\"}]}'\n"
        .utf8).write(to: probe)
    _ = chmod(probe.path, 0o700)
    let epubcheck = try makeEPUBCheckStub(in: root)
    let report = try await ReadAloudQualityAuditor().audit(
      .init(
        epub: epub, mode: .thorough, retainedTranscriptions: transcripts,
        retainedTranscriptionsAreBound: false, useFreshASR: false),
      tools: .init(
        stalign: nil, ffmpeg: probe, ffprobe: probe, epubcheck: epubcheck))
    XCTAssertFalse([.broken, .likelyBroken].contains(report.verdict))
    XCTAssertNil(report.modelIdentity)
    XCTAssertNil(report.metrics.textToTranscriptCoverage)
  }

  func testPairedStemValidationSortsOrdinallyInsteadOfTrustingRawEnumeration() throws {
    // The regression this guards against: APFS readdir returns per-extension
    // stem sequences in different (hash) orders for identical stem sets.
    // stalign (Node/libuv) enumerates alphabetically, so scrambled raw orders
    // over the same set must PASS.
    XCTAssertNoThrow(
      try StalignReadAloudBackend.validatePairedStems(
        audio: ["00001-00018", "00001-00002", "00001-00025"],
        transcripts: ["00001-00002", "00001-00025", "00001-00018"]))

    // Genuine mismatches still fail: missing, extra, duplicate, or empty.
    XCTAssertThrowsError(
      try StalignReadAloudBackend.validatePairedStems(
        audio: ["00001-00001", "00001-00002"],
        transcripts: ["00001-00001"]))
    XCTAssertThrowsError(
      try StalignReadAloudBackend.validatePairedStems(
        audio: ["00001-00001"],
        transcripts: ["00001-00001", "stray-extra"]))
    XCTAssertThrowsError(
      try StalignReadAloudBackend.validatePairedStems(
        audio: ["00001-00001", "00001-00001"],
        transcripts: ["00001-00001", "00001-00001"]))
    XCTAssertThrowsError(
      try StalignReadAloudBackend.validatePairedStems(audio: [], transcripts: []))
  }
}

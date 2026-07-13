import ArgumentParser
import AudiobookKit
import BookJobKit
import CryptoKit
import Darwin
import Foundation
import ReadAloudKit
import StorytellerKit

struct BookJobsCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "jobs", abstract: "Internal durable book-production jobs.",
    shouldDisplay: false, subcommands: [Run.self])

  struct Run: AsyncParsableCommand {
    @Argument var id: String
    func run() async throws {
      guard let id = UUID(uuidString: id) else { throw ValidationError("invalid job UUID") }
      let task = Task { try await BookJobExecutor().run(id: id) }
      signal(SIGINT, SIG_IGN)
      signal(SIGTERM, SIG_IGN)
      let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
      let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
      sigint.setEventHandler { task.cancel() }
      sigterm.setEventHandler { task.cancel() }
      sigint.resume()
      sigterm.resume()
      defer {
        sigint.cancel()
        sigterm.cancel()
      }
      try await task.value
    }
  }
}

final class BookJobExecutor: @unchecked Sendable {
  private let store: BookJobStore
  private let catalogStore: BookCatalogStore
  private let audiobookExecutable: URL?
  private let executionLockURL: URL?

  init(
    store: BookJobStore = BookJobStore(root: AppPaths.productionJobRoot),
    catalogStore: BookCatalogStore = BookCatalogStore(root: AppPaths.bookCatalogRoot),
    audiobookExecutable: URL? = nil,
    executionLockURL: URL? = AppPaths.studioExecutionLockURL
  ) {
    self.store = store
    self.catalogStore = catalogStore
    self.audiobookExecutable = audiobookExecutable
    self.executionLockURL = executionLockURL
  }

  func run(id: UUID) async throws {
    let lease = try await store.acquireLease(id)
    defer { _fixLifetime(lease) }
    let executionLock = try executionLockURL.map { try BookFileLock(url: $0, nonblocking: true) }
    defer { _fixLifetime(executionLock) }
    let loaded = try await store.loadJob(id)
    let request = loaded.0
    var state = loaded.1
    guard ![.completed, .cancelled].contains(state.lifecycle) else {
      throw BookJobError.invalidRequest("completed or cancelled jobs cannot be run again")
    }
    if state.lifecycle == .running {
      // Holding the lease proves the previous runner is gone. Recover state
      // left behind by SIGKILL, a crash, or power loss before starting again.
      state.prepareForRetry()
    } else {
      state.prepareForRetry()
      try state.transition(to: .running)
    }
    state.attempt += 1
    state.runner = BookJobRunnerIdentity(
      pid: ProcessInfo.processInfo.processIdentifier, launchToken: UUID(),
      executablePath: Bundle.main.executableURL?.path ?? CommandLine.arguments[0],
      heartbeatAt: Date())
    try await store.saveState(state)
    do {
      try await checkCancellation(request.id, attempt: state.attempt)
      guard try Self.sha256(URL(fileURLWithPath: request.source.path)) == request.source.sha256
      else {
        throw BookJobError.invalidRequest("source EPUB changed after this job was created")
      }
      state.products.removeAll { $0.kind == .sourceEPUB }
      state.products.append(
        try Self.product(.sourceEPUB, URL(fileURLWithPath: request.source.path)))
      try await store.saveState(state)
      try Task.checkCancellation()
      if request.resolvedOperation == .storytellerDelivery {
        try await verifyDeliveryProducts(request, state: &state)
      } else if request.resolvedOperation == .readAloud {
        try await runReadAloudOnly(request, state: &state)
      } else {
        try await runM4B(request, state: &state)
        try await checkCancellation(request.id, attempt: state.attempt)
        if request.readAloud != nil { try await runReadAloud(request, state: &state) }
      }
      try await checkCancellation(request.id, attempt: state.attempt)
      if request.storyteller != nil { try await runStoryteller(request, state: &state) }
      try await reconcileCatalog(request, state: state)
      state.runner = nil
      try state.transition(to: .completed)
      try await store.saveState(state)
    } catch is CancellationError {
      state = (try? await store.loadState(id)) ?? state
      state.runner = nil
      if let stage = state.stages.first(where: { $0.status == .running })?.stage {
        try? state.updateStage(
          stage, status: .paused,
          fraction: state.stages.first(where: { $0.stage == stage })?.fraction)
      }
      let control = try? await store.loadControl(id)
      if state.lifecycle == .running {
        if control?.interruption?.attempt == state.attempt,
          control?.interruption?.kind == .cancel
        {
          try? state.transition(to: .cancelled)
        } else {
          try? state.transition(to: .paused)
        }
      }
      try await store.saveState(state)
      throw CLIFailure(message: "book job paused", exitCode: 130)
    } catch {
      state = (try? await store.loadState(id)) ?? state
      state.runner = nil
      state.lastError = error.localizedDescription
      if let stage = state.stages.first(where: { $0.status == .running })?.stage {
        try? state.updateStage(
          stage, status: .needsAttention,
          fraction: state.stages.first(where: { $0.stage == stage })?.fraction,
          message: error.localizedDescription)
      }
      if state.lifecycle == .running { try? state.transition(to: .needsAttention) }
      try await store.saveState(state)
      throw error
    }
  }

  private func runReadAloudOnly(
    _ request: BookJobRequest, state: inout BookJobState
  ) async throws {
    guard let audio = request.alignmentAudio else {
      throw BookJobError.invalidRequest("ReadAloud-only job has no alignment audio")
    }
    var workingRequest = request
    switch audio.mode {
    case .existingM4B:
      guard let path = audio.path, let expectedSize = audio.size, let expectedHash = audio.sha256
      else { throw BookJobError.invalidRequest("existing alignment audio is incomplete") }
      let url = URL(fileURLWithPath: path)
      guard try BookFileDigest.size(url) == expectedSize,
        try BookFileDigest.sha256(url) == expectedHash
      else { throw BookJobError.invalidRequest("cataloged audiobook changed before alignment") }
      workingRequest.m4bOutputPath = path
      for stage in [
        BookJobStage.preparation, .m4bSynthesis, .m4bAssembly, .m4bVerification,
      ] where state.stages.first(where: { $0.stage == stage })?.status == .pending {
        try state.updateStage(stage, status: .skipped, fraction: 1)
      }
      try await store.saveState(state)
    case .temporaryResynthesis:
      let staging = await store.jobDirectory(request.id).appendingPathComponent(
        "staging/alignment-audio", isDirectory: true)
      try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
      let temporaryM4B = staging.appendingPathComponent("alignment.m4b")
      workingRequest.m4bOutputPath = temporaryM4B.path
      workingRequest.m4bWorkDirectory = staging.appendingPathComponent("work").path
      workingRequest.allowOverwrite = false
      workingRequest.narration.announceTitles = false
      try await runM4B(workingRequest, state: &state)
    }
    try await checkCancellation(request.id, attempt: state.attempt)
    try await runReadAloud(workingRequest, state: &state)
    if audio.mode == .temporaryResynthesis {
      let temporaryPath = workingRequest.m4bOutputPath
      state.products.removeAll { $0.kind == .m4b && $0.path == temporaryPath }
      try? FileManager.default.removeItem(atPath: temporaryPath)
      try await store.saveState(state)
    }
  }

  private func reconcileCatalog(_ request: BookJobRequest, state: BookJobState) async throws {
    guard let catalogID = request.catalogID else { return }
    for product in state.products {
      let catalogProduct = BookCatalogProduct(
        kind: product.kind, path: product.path, size: product.size, sha256: product.sha256,
        verifiedAt: product.verifiedAt, producerJobID: request.id,
        narration: product.kind == .m4b ? request.narration : nil,
        readAloud: product.kind == .readAloudEPUB ? request.readAloud : nil)
      _ = try await catalogStore.reconcile(catalogID: catalogID, product: catalogProduct)
    }
  }

  /// A completed production request remains immutable. Sending it later is a
  /// new durable job which revalidates only the selected local products and
  /// then enters the ordinary conflict-safe Storyteller stages.
  private func verifyDeliveryProducts(
    _ request: BookJobRequest, state: inout BookJobState
  ) async throws {
    guard let delivery = request.storyteller else {
      throw BookJobError.invalidRequest("delivery-only job has no Storyteller selection")
    }

    let m4bStages: [BookJobStage] = [.preparation, .m4bSynthesis, .m4bAssembly]
    for stage in m4bStages { try state.updateStage(stage, status: .skipped, fraction: 1) }
    if delivery.products.contains(.m4b) {
      let url = URL(fileURLWithPath: request.m4bOutputPath)
      try state.updateStage(.m4bVerification, status: .running, fraction: 0)
      try await store.saveState(state)
      try await AudiobookVerifier.printReport(for: url, decodeAudio: true)
      state.products.append(try Self.product(.m4b, url))
      try state.updateStage(.m4bVerification, status: .succeeded, fraction: 1)
    } else {
      try state.updateStage(.m4bVerification, status: .skipped, fraction: 1)
    }

    let readAloudStages: [BookJobStage] = [
      .readAloudAudioProcessing, .readAloudTranscription, .readAloudMarkup,
      .readAloudAlignment,
    ]
    for stage in readAloudStages {
      try state.updateStage(stage, status: .skipped, fraction: 1)
    }
    if delivery.products.contains(.readAloudEPUB) {
      guard let path = request.readAloud?.outputPath else {
        throw BookJobError.invalidRequest("selected ReadAloud product has no path")
      }
      let tools = try await ReadAloudTools.resolve(managedStalign: AppPaths.managedStalignURL)
      let url = URL(fileURLWithPath: path)
      try state.updateStage(.readAloudVerification, status: .running, fraction: 0)
      try await store.saveState(state)
      _ = try await ReadAloudVerifier.verifyPublished(epub: url, ffprobe: tools.ffprobe)
      state.products.append(try Self.product(.readAloudEPUB, url))
      try state.updateStage(.readAloudVerification, status: .succeeded, fraction: 1)
    } else {
      try state.updateStage(.readAloudVerification, status: .skipped, fraction: 1)
    }

    if delivery.products.contains(.sourceEPUB) {
      state.products.removeAll { $0.kind == .sourceEPUB }
      state.products.append(
        try Self.product(.sourceEPUB, URL(fileURLWithPath: request.source.path)))
    }
    try await store.saveState(state)
  }

  private func checkCancellation(_ id: UUID, attempt: UInt64) async throws {
    try Task.checkCancellation()
    if try await store.loadControl(id).cancelRequestedForAttempt == attempt {
      throw CancellationError()
    }
  }

  private func runM4B(_ request: BookJobRequest, state: inout BookJobState) async throws {
    let output = URL(fileURLWithPath: request.m4bOutputPath)
    if let product = state.products.first(where: { $0.kind == .m4b }),
      FileManager.default.fileExists(atPath: product.path),
      try Self.sha256(URL(fileURLWithPath: product.path)) == product.sha256
    {
      return
    }
    let mayRecoverPublishedM4B =
      state.stages.first(where: { $0.stage == .m4bAssembly })?.status == .succeeded
      || (state.stages.first(where: { $0.stage == .m4bVerification }).map {
        $0.status != .pending
      } ?? false)
    if mayRecoverPublishedM4B, FileManager.default.fileExists(atPath: output.path) {
      try state.updateStage(.m4bVerification, status: .running, fraction: 0)
      try await store.saveState(state)
      try await AudiobookVerifier.printReport(for: output, decodeAudio: true)
      state.products.removeAll { $0.kind == .m4b }
      state.products.append(try Self.product(.m4b, output))
      try state.updateStage(.m4bVerification, status: .succeeded, fraction: 1)
      try await store.saveState(state)
      return
    }
    try state.updateStage(.preparation, status: .running, fraction: 0)
    try await store.saveState(state)
    var arguments = [request.source.path, "--output", output.path]
    arguments += ["--voice", request.narration.voiceID]
    arguments += ["--bitrate", String(request.narration.bitrateKbps)]
    arguments += ["--workers", String(request.narration.workers)]
    arguments += ["--paragraph-pause", String(request.narration.paragraphPauseSeconds)]
    arguments += ["--chapter-pause", String(request.narration.chapterPauseSeconds)]
    arguments += [request.narration.announceTitles ? "--announce-titles" : "--no-announce-titles"]
    if !request.narration.includedSectionIDs.isEmpty {
      arguments += [
        "--include-sections", request.narration.includedSectionIDs.joined(separator: ","),
      ]
    }
    if !request.narration.excludedSectionIDs.isEmpty {
      arguments += [
        "--exclude-sections", request.narration.excludedSectionIDs.joined(separator: ","),
      ]
    }
    if let workDirectory = request.m4bWorkDirectory, !workDirectory.isEmpty {
      arguments += ["--work-dir", workDirectory]
    }
    if request.allowOverwrite { arguments.append("--overwrite") }
    try state.updateStage(.preparation, status: .succeeded, fraction: 1)
    try state.updateStage(.m4bSynthesis, status: .running, fraction: 0)
    try await store.saveState(state)

    let runner = AudiobookJobRunner(executable: audiobookExecutable)
    for try await event in runner.run(arguments: arguments) {
      if try await store.loadControl(request.id).cancelRequestedForAttempt == state.attempt {
        runner.cancel()
        throw CancellationError()
      }
      switch event {
      case .started(
        let totalChapters, let totalCharacters, let reusedChapters, let chapterCharacters):
        state.audiobookProgress = BookJobAudiobookProgress(
          totalChapters: totalChapters, totalCharacters: totalCharacters,
          reusedChapters: reusedChapters, chapterCharacters: chapterCharacters)
        state.touch()
      case .chapterStarted(let index, let title):
        state.audiobookProgress?.currentChapterIndex = index
        state.audiobookProgress?.currentChapterTitle = title
        state.audiobookProgress?.completedUnits = 0
        state.audiobookProgress?.totalUnits = 0
        state.touch()
      case .unitCompleted(let chapterIndex, let completed, let total):
        state.audiobookProgress?.completedUnits = completed
        state.audiobookProgress?.totalUnits = total
        try state.updateStage(
          .m4bSynthesis, status: .running,
          fraction: total > 0 && (state.audiobookProgress?.totalChapters ?? 0) > 0
            ? (Double(chapterIndex) + Double(completed) / Double(total))
              / Double(state.audiobookProgress!.totalChapters)
            : nil)
      case .assemblyStarted:
        try state.updateStage(.m4bSynthesis, status: .succeeded, fraction: 1)
        try state.updateStage(.m4bAssembly, status: .running, fraction: 0)
      case .finished:
        try state.updateStage(.m4bAssembly, status: .succeeded, fraction: 1)
      case .warning(let warning):
        if state.warnings.count < 50 {
          state.warnings.append(warning)
          state.touch()
        }
      case .chapterCompleted:
        state.touch()
      }
      state.runner?.heartbeatAt = Date()
      try await store.saveState(state)
    }
    try state.updateStage(.m4bVerification, status: .running, fraction: 0)
    try await store.saveState(state)
    try await AudiobookVerifier.printReport(for: output, decodeAudio: true)
    let product = try Self.product(.m4b, output)
    state.products.removeAll { $0.kind == .m4b }
    state.products.append(product)
    try state.updateStage(.m4bVerification, status: .succeeded, fraction: 1)
    try await store.saveState(state)
  }

  private func runReadAloud(_ request: BookJobRequest, state: inout BookJobState) async throws {
    guard let options = request.readAloud else { return }
    if let product = state.products.first(where: { $0.kind == .readAloudEPUB }),
      FileManager.default.fileExists(atPath: product.path),
      try Self.sha256(URL(fileURLWithPath: product.path)) == product.sha256
    {
      return
    }
    let tools = try await ReadAloudTools.resolve(managedStalign: AppPaths.managedStalignURL)
    let output = URL(fileURLWithPath: options.outputPath)
    let mayRecoverPublishedReadAloud =
      state.stages.first {
        $0.stage == .readAloudAlignment
      }?.status == .succeeded
    if mayRecoverPublishedReadAloud, FileManager.default.fileExists(atPath: output.path) {
      try state.updateStage(.readAloudVerification, status: .running, fraction: 0)
      try await store.saveState(state)
      _ = try await ReadAloudVerifier.verifyPublished(epub: output, ffprobe: tools.ffprobe)
      state.products.removeAll { $0.kind == .readAloudEPUB }
      state.products.append(try Self.product(.readAloudEPUB, output))
      try state.updateStage(.readAloudVerification, status: .succeeded, fraction: 1)
      try await store.saveState(state)
      return
    }
    let backend = StalignReadAloudBackend(tools: tools)
    let progressWrites = AsyncWriteDrain()
    let store = self.store
    let attempt = state.attempt
    let report: ReadAloudVerificationReport
    do {
      report = try await withThrowingTaskGroup(of: ReadAloudVerificationReport.self) { group in
        group.addTask {
          try await backend.create(
            request: ReadAloudRequest(
              epubPath: request.source.path, audiobookPath: request.m4bOutputPath,
              outputPath: options.outputPath,
              workDirectory: await store.jobDirectory(request.id).appendingPathComponent(
                "staging/readaloud"
              ).path,
              opusBitrateKbps: options.opusBitrateKbps,
              language: options.language ?? "en-US", overwrite: request.allowOverwrite)
          ) { [store] progress in
            progressWrites.submit {
              var current = try await store.loadState(request.id)
              let stage: BookJobStage =
                switch progress.stage {
                case .preparing, .processingAudio: .readAloudAudioProcessing
                case .transcribing: .readAloudTranscription
                case .markingUp: .readAloudMarkup
                case .aligning: .readAloudAlignment
                case .verifying: .readAloudVerification
                }
              if let active = current.stages.first(where: {
                $0.status == .running && $0.stage != stage
              })?.stage {
                try? current.updateStage(active, status: .succeeded, fraction: 1)
              }
              try? current.updateStage(
                stage, status: .running, fraction: progress.stageFraction,
                message: progress.message)
              try? await store.saveState(current)
            }
          }
        }
        group.addTask {
          while true {
            try await Task.sleep(for: .milliseconds(500))
            try await self.checkCancellation(request.id, attempt: attempt)
          }
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw CancellationError() }
        return first
      }
    } catch {
      await progressWrites.drain()
      throw error
    }
    await progressWrites.drain()
    guard report.audioCount > 0 else { throw ReadAloudError.invalidArtifact("no embedded audio") }
    // Reload because progress callbacks persisted newer revisions.
    state = try await store.loadState(request.id)
    for stage in [
      BookJobStage.readAloudAudioProcessing, .readAloudTranscription, .readAloudMarkup,
      .readAloudAlignment, .readAloudVerification,
    ] { try state.updateStage(stage, status: .succeeded, fraction: 1) }
    state.products.removeAll { $0.kind == .readAloudEPUB }
    state.products.append(
      try Self.product(.readAloudEPUB, URL(fileURLWithPath: options.outputPath)))
    try await store.saveState(state)
  }

  private func runStoryteller(_ request: BookJobRequest, state: inout BookJobState) async throws {
    guard let delivery = request.storyteller else { return }
    guard
      let connection = try await StorytellerConnectionStore.shared.connections()
        .first(where: { $0.id == delivery.connectionID })
    else { throw StorytellerAPIError.authenticationRequired }
    let client = try StorytellerClient(origin: connection.origin) {
      try StorytellerConnectionStore.shared.token(delivery.connectionID)
    }
    _ = try await client.requirePermissions(create: false, update: false)
    try state.updateStage(.storytellerPreflight, status: .running, fraction: 0)
    try await store.saveState(state)
    let books = try await client.books()
    let requested = Set(
      delivery.products.map { product -> StorytellerFormat in
        switch product {
        case .sourceEPUB: .ebook
        case .m4b: .audiobook
        case .readAloudEPUB: .readaloud
        }
      })
    var remoteID = state.storytellerBookID ?? delivery.remoteBookID
    if state.storytellerBookID == nil, let baseline = state.storytellerBaselineBookIDs,
      !books.contains(where: { $0.uuid == remoteID })
    {
      let baselineIDs = Set(baseline)
      let recovered = books.filter { book in
        !baselineIDs.contains(book.uuid)
          && StorytellerConflictPlanner.normalize(book.title)
            == StorytellerConflictPlanner.normalize(request.title)
          && requested.contains(where: { book.asset($0) != nil })
      }
      if recovered.count == 1, let assigned = recovered.first?.uuid {
        remoteID = assigned
        state.storytellerBookID = assigned
        state.touch()
        try await store.saveState(state)
      }
    }
    let formats: Set<StorytellerFormat>
    let isNew: Bool
    var provenReceipts: [BookCatalogRemoteReceipt] = []
    if let target = books.first(where: { $0.uuid == remoteID }) {
      var missing = Set<StorytellerFormat>()
      let catalogLink = try await storytellerCatalogLink(request, connectionID: delivery.connectionID)
      for format in requested {
        guard let asset = target.asset(format) else {
          missing.insert(format)
          continue
        }
        let local = try localStorytellerProduct(format, request: request, state: state)
        if let receipt = catalogLink?.receipts.first(where: { $0.format == format.rawValue }),
          Self.receipt(receipt, proves: asset, local: local)
        {
          provenReceipts.append(receipt)
          continue
        }
        guard let remoteSize = asset.fileSize else {
          throw StorytellerAPIError.conflict(
            "the existing \(format.rawValue) asset has no verifiable size")
        }
        let hash = try await client.assetHash(
          bookID: target.uuid, format: format, expectedSize: remoteSize)
        guard hash == local.sha256 else {
          throw StorytellerAPIError.conflict(
            "the existing \(format.rawValue) asset is not the selected local product")
        }
        provenReceipts.append(Self.receipt(format, local: local, remote: asset, hash: hash))
      }
      formats = missing
      isNew = false
      if missing.isEmpty {
        try await reconcileStorytellerCatalog(
          request, connectionID: delivery.connectionID, remote: target,
          receipts: provenReceipts)
        try state.updateStage(.storytellerPreflight, status: .succeeded, fraction: 1)
        try state.updateStage(.storytellerUpload, status: .skipped, fraction: 1)
        try state.updateStage(.storytellerReconciliation, status: .succeeded, fraction: 1)
        state.storytellerBookID = target.uuid
        state.touch()
        try await store.saveState(state)
        return
      }
      _ = try await client.requirePermissions(create: false, update: true)
    } else {
      let localIdentifiers = CanonicalPublicationIdentifier.local(request.source.typedIdentifiers)
      let identifierMatches = books.filter {
        !localIdentifiers.isEmpty
          && !localIdentifiers.isDisjoint(
            with: CanonicalPublicationIdentifier.remote($0.identifiers))
      }
      if !identifierMatches.isEmpty {
        throw StorytellerAPIError.conflict(
          "an existing book has the same validated publication identifier")
      }
      let normalizedTitle = StorytellerConflictPlanner.normalize(request.title)
      let normalizedAuthor = request.author.map(StorytellerConflictPlanner.normalize)
      let metadataMatches = books.filter { book in
        StorytellerConflictPlanner.normalize(book.title) == normalizedTitle
          && (normalizedAuthor == nil
            || book.authors.contains {
              StorytellerConflictPlanner.normalize($0.name) == normalizedAuthor
            })
      }
      if !metadataMatches.isEmpty {
        throw StorytellerAPIError.conflict(
          "an existing book has the same title and author and requires review")
      }
      _ = try await client.requirePermissions(create: true, update: requested.count > 1)
      state.storytellerBaselineBookIDs = books.map(\.uuid)
      state.touch()
      try await store.saveState(state)
      formats = requested
      isNew = true
    }
    try state.updateStage(.storytellerPreflight, status: .succeeded, fraction: 1)
    try state.updateStage(.storytellerUpload, status: .running, fraction: 0)
    try await store.saveState(state)

    let pending = formats.sorted { Self.formatOrder($0) < Self.formatOrder($1) }
    let pendingCount = pending.count
    let uploader = StorytellerTUSUploader(client: client)
    let serverChunkLimit = try await client.maxUploadChunkSize()
    let uploadChunkSize = max(1, min(8 << 20, serverChunkLimit ?? (8 << 20)))
    let progressWrites = AsyncWriteDrain()
    let attempt = state.attempt
    for (index, format) in pending.enumerated() {
      try await checkCancellation(request.id, attempt: attempt)
      let source = try productURL(format, request: request)
      let endpoint =
        isNew && index == 0
        ? "/api/v2/books/upload"
        : "/api/v2/books/\(remoteID.uuidString.lowercased())/replace-asset/upload"
      var metadata = [
        "bookUuid": remoteID.uuidString.lowercased(),
        "filename": source.lastPathComponent,
        "filetype": format == .audiobook ? "audio/mp4" : "application/epub+zip",
      ]
      if !(isNew && index == 0) {
        metadata["format"] = format.rawValue
        metadata["batchId"] = UUID().uuidString.lowercased()
      }
      let transferURL = await store.jobDirectory(request.id).appendingPathComponent(
        "tus-\(format.rawValue).json")
      let initial = (try? Data(contentsOf: transferURL)).flatMap {
        try? JSONDecoder().decode(TUSUploadState.self, from: $0)
      }
      do {
        _ = try await uploader.upload(
          file: source, endpoint: endpoint, metadata: metadata, state: initial,
          chunkSize: uploadChunkSize,
          onState: {
            next in
            try await self.checkCancellation(request.id, attempt: attempt)
            try JSONEncoder().encode(next).write(to: transferURL, options: [.atomic])
          },
          onProgress: { fraction in
            progressWrites.submit {
              var latest = try await self.store.loadState(request.id)
              try? latest.updateStage(
                .storytellerUpload, status: .running,
                fraction: (Double(index) + fraction) / Double(max(1, pendingCount)))
              try? await self.store.saveState(latest)
            }
          })
      } catch {
        await progressWrites.drain()
        throw error
      }
      try? FileManager.default.removeItem(at: transferURL)
      if isNew && index == 0 {
        if try await client.book(remoteID) == nil {
          let previousIDs = Set(books.map(\.uuid))
          let candidates = try await client.books().filter { book in
            !previousIDs.contains(book.uuid)
              && StorytellerConflictPlanner.normalize(book.title)
                == StorytellerConflictPlanner.normalize(request.title)
          }
          guard candidates.count == 1, let assigned = candidates.first?.uuid else {
            throw StorytellerAPIError.conflict(
              "Storyteller created the product but its assigned book could not be identified uniquely"
            )
          }
          remoteID = assigned
        }
        state = try await store.loadState(request.id)
        state.storytellerBookID = remoteID
        state.touch()
        try await store.saveState(state)
        _ = try await Self.waitForBook(client, id: remoteID) {
          try await self.checkCancellation(request.id, attempt: attempt)
        }
      }
    }
    await progressWrites.drain()
    state = try await store.loadState(request.id)
    try state.updateStage(.storytellerUpload, status: .succeeded, fraction: 1)
    try state.updateStage(.storytellerReconciliation, status: .running, fraction: 0)
    let reconciled = try await Self.waitForAssets(client, id: remoteID, formats: requested) {
      try await self.checkCancellation(request.id, attempt: attempt)
    }
    for format in formats {
      let local = try localStorytellerProduct(format, request: request, state: state)
      guard let asset = reconciled.asset(format) else {
        throw StorytellerAPIError.invalidResponse("uploaded asset disappeared during reconciliation")
      }
      if let remoteSize = asset.fileSize, remoteSize != local.size {
        throw StorytellerAPIError.conflict(
          "the uploaded \(format.rawValue) asset size does not match the local product")
      }
      let hash: String?
      if let remoteSize = asset.fileSize {
        hash = try? await client.assetHash(
          bookID: remoteID, format: format, expectedSize: remoteSize)
      } else {
        hash = nil
      }
      if let hash, hash != local.sha256 {
        throw StorytellerAPIError.conflict(
          "the uploaded \(format.rawValue) asset hash does not match the local product")
      }
      provenReceipts.append(Self.receipt(format, local: local, remote: asset, hash: hash))
    }
    try await reconcileStorytellerCatalog(
      request, connectionID: delivery.connectionID, remote: reconciled,
      receipts: provenReceipts)
    state.storytellerBookID = remoteID
    state.touch()
    try state.updateStage(.storytellerReconciliation, status: .succeeded, fraction: 1)
    try await store.saveState(state)
  }

  private struct LocalStorytellerProduct {
    var kind: BookProductKind
    var size: UInt64
    var sha256: String
  }

  private func localStorytellerProduct(
    _ format: StorytellerFormat, request: BookJobRequest, state: BookJobState
  ) throws -> LocalStorytellerProduct {
    let kind: BookProductKind = switch format {
    case .ebook: .sourceEPUB
    case .audiobook: .m4b
    case .readaloud: .readAloudEPUB
    }
    guard let product = state.products.first(where: { $0.kind == kind }) else {
      throw StorytellerAPIError.invalidResponse(
        "the verified local \(format.rawValue) product is unavailable")
    }
    let expectedURL = try productURL(format, request: request).standardizedFileURL
    guard URL(fileURLWithPath: product.path).standardizedFileURL == expectedURL,
      try BookFileDigest.size(expectedURL) == product.size,
      try BookFileDigest.sha256(expectedURL) == product.sha256
    else { throw StorytellerAPIError.fileChanged }
    return .init(kind: kind, size: product.size, sha256: product.sha256)
  }

  private func storytellerCatalogLink(
    _ request: BookJobRequest, connectionID: UUID
  ) async throws -> BookCatalogRemoteLink? {
    guard let catalogID = request.catalogID else { return nil }
    return try await catalogStore.load(catalogID).remoteLinks.first {
      $0.providerID == "storyteller" && $0.connectionID == connectionID
    }
  }

  private func reconcileStorytellerCatalog(
    _ request: BookJobRequest, connectionID: UUID, remote: StorytellerBook,
    receipts: [BookCatalogRemoteReceipt]
  ) async throws {
    guard let catalogID = request.catalogID else { return }
    var record = try await catalogStore.load(catalogID)
    let expectedRevision = record.revision
    let previous = record.remoteLinks.first {
      $0.providerID == "storyteller" && $0.connectionID == connectionID
    }
    var merged = Dictionary(
      uniqueKeysWithValues: (previous?.receipts ?? []).map { ($0.format, $0) })
    for receipt in receipts { merged[receipt.format] = receipt }
    record.upsertRemoteLink(
      .init(
        providerID: "storyteller", connectionID: connectionID,
        remoteBookID: remote.uuid.uuidString.lowercased(),
        evidence: previous?.evidence ?? .legacyJob,
        linkedAt: previous?.linkedAt ?? Date(), lastObservedAt: Date(),
        remoteTitle: remote.title, remoteAuthors: remote.authors.map(\.name),
        receipts: merged.values.sorted { $0.format < $1.format },
        excludedRemoteBookIDs: previous?.excludedRemoteBookIDs ?? []))
    try await catalogStore.update(record, expectedRevision: expectedRevision)
  }

  private static func receipt(
    _ receipt: BookCatalogRemoteReceipt, proves asset: StorytellerAsset,
    local: LocalStorytellerProduct
  ) -> Bool {
    receipt.localSHA256 == local.sha256
      && receipt.remoteAssetID == asset.uuid.uuidString.lowercased()
      && receipt.remoteSize == asset.fileSize
      && (receipt.remoteFingerprint == nil || receipt.remoteFingerprint == asset.fingerprint)
      && (receipt.remoteSHA256 == nil || receipt.remoteSHA256 == local.sha256)
  }

  private static func receipt(
    _ format: StorytellerFormat, local: LocalStorytellerProduct,
    remote: StorytellerAsset, hash: String?
  ) -> BookCatalogRemoteReceipt {
    .init(
      format: format.rawValue, localSHA256: local.sha256,
      remoteAssetID: remote.uuid.uuidString.lowercased(), remoteSize: remote.fileSize,
      remoteFingerprint: remote.fingerprint, remoteSHA256: hash)
  }

  private func productURL(_ format: StorytellerFormat, request: BookJobRequest) throws -> URL {
    switch format {
    case .ebook: return URL(fileURLWithPath: request.source.path)
    case .audiobook: return URL(fileURLWithPath: request.m4bOutputPath)
    case .readaloud:
      guard let path = request.readAloud?.outputPath else {
        throw StorytellerAPIError.invalidResponse("ReadAloud output is unavailable")
      }
      return URL(fileURLWithPath: path)
    }
  }

  private static func waitForBook(
    _ client: StorytellerClient, id: UUID,
    checkCancellation: @escaping @Sendable () async throws -> Void = {}
  ) async throws
    -> StorytellerBook
  {
    for attempt in 0..<30 {
      try await checkCancellation()
      if let book = try await client.book(id) { return book }
      try await Task.sleep(for: .milliseconds(min(2_000, 200 + attempt * 100)))
    }
    throw StorytellerAPIError.invalidResponse("uploaded book did not become queryable")
  }

  private static func waitForAssets(
    _ client: StorytellerClient, id: UUID, formats: Set<StorytellerFormat>,
    checkCancellation: @escaping @Sendable () async throws -> Void = {}
  ) async throws -> StorytellerBook {
    for attempt in 0..<60 {
      try await checkCancellation()
      if let book = try await client.book(id), formats.allSatisfy({ book.asset($0) != nil }) {
        return book
      }
      try await Task.sleep(for: .milliseconds(min(2_000, 250 + attempt * 100)))
    }
    throw StorytellerAPIError.invalidResponse(
      "selected remote assets did not appear after upload")
  }

  private static func formatOrder(_ format: StorytellerFormat) -> Int {
    switch format {
    case .ebook: 0
    case .audiobook: 1
    case .readaloud: 2
    }
  }

  private static func product(_ kind: BookProductKind, _ url: URL) throws -> BookJobProduct {
    let values = try url.resourceValues(forKeys: [.fileSizeKey])
    return BookJobProduct(
      kind: kind, path: url.path, size: UInt64(values.fileSize ?? 0),
      sha256: try sha256(url), verifiedAt: Date())
  }

  private static func sha256(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hash = SHA256()
    while let data = try handle.read(upToCount: 4 << 20), !data.isEmpty { hash.update(data: data) }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }
}

private final class AsyncWriteDrain: @unchecked Sendable {
  private let lock = NSLock()
  private var pending = 0
  private var tail: Task<Void, Never>?
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func submit(_ operation: @escaping @Sendable () async throws -> Void) {
    lock.lock()
    pending += 1
    let previous = tail
    tail = Task { [weak self] in
      _ = await previous?.value
      try? await operation()
      self?.finishOne()
    }
    lock.unlock()
  }

  func drain() async {
    await withCheckedContinuation { continuation in
      let complete = lock.withLock { () -> Bool in
        guard pending > 0 else { return true }
        waiters.append(continuation)
        return false
      }
      if complete { continuation.resume() }
    }
  }

  private func finishOne() {
    let continuations = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
      pending -= 1
      guard pending == 0 else { return [] }
      tail = nil
      defer { waiters.removeAll() }
      return waiters
    }
    continuations.forEach { $0.resume() }
  }
}

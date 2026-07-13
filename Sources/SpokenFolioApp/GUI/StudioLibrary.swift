import AppKit
import BookJobKit
import Foundation
import Observation
import StorytellerKit
import SwiftUI

@MainActor
@Observable
final class StudioLibraryModel {
  private(set) var records: [BookCatalogRecord] = []
  private(set) var issues: [String] = []
  private(set) var connections: [StorytellerConnection] = []
  var error: String?
  var pendingRecord: BookCatalogRecord?
  var connectionID: UUID?
  var sendEPUB = true
  var sendM4B = true
  var sendReadAloud = true
  var candidates: [StorytellerMatchCandidate] = []
  var selectedCandidateID: UUID?
  var isBusy = false

  @ObservationIgnored private let catalogStore: BookCatalogStore
  @ObservationIgnored private let coordinator: StudioJobCoordinator

  init(
    coordinator: StudioJobCoordinator,
    catalogStore: BookCatalogStore = BookCatalogStore(root: AppPaths.bookCatalogRoot)
  ) {
    self.coordinator = coordinator
    self.catalogStore = catalogStore
  }

  func reload() async {
    do {
      let scan = try await catalogStore.scan()
      records = scan.records
      issues = scan.issues
      connections = await StorytellerConnectionStore.shared.authenticatedConnections()
      if !connections.contains(where: { $0.id == connectionID }) {
        connectionID = connections.first?.id
      }
      error = nil
    } catch { self.error = error.localizedDescription }
  }

  func createReadAloud(_ record: BookCatalogRecord) {
    guard record.product(.readAloudEPUB) == nil,
      let source = record.product(.sourceEPUB), let audiobook = record.product(.m4b),
      var narration = audiobook.narration
    else { return }
    narration.announceTitles = false
    let alignment: BookJobRequest.AlignmentAudio = audiobook.narration?.announceTitles == false
      ? .init(
        mode: .existingM4B, path: audiobook.path, size: audiobook.size,
        sha256: audiobook.sha256)
      : .init(mode: .temporaryResynthesis)
    let request = BookJobRequest(
      catalogID: record.id, managedByStudio: true, title: record.metadata.title,
      author: record.metadata.author,
      source: .init(
        path: source.path, sha256: record.source.sha256, format: "epub",
        importerVersion: record.source.importerVersion,
        identifiers: record.metadata.identifiers.map(\.value),
        typedIdentifiers: record.metadata.identifiers),
      narration: narration, m4bOutputPath: audiobook.path,
      readAloud: .init(outputPath: record.layout.readAloud.path),
      alignmentAudio: alignment, operation: .readAloud)
    isBusy = true
    Task {
      let failures = await coordinator.enqueue([request])
      isBusy = false
      if let failure = failures[request.id] { error = failure }
    }
  }

  func beginSend(_ record: BookCatalogRecord) {
    pendingRecord = record
    connectionID = connections.first?.id
    sendEPUB = record.product(.sourceEPUB) != nil
    sendM4B = record.product(.m4b) != nil
    sendReadAloud = record.product(.readAloudEPUB) != nil
    candidates = []
    selectedCandidateID = nil
    error = nil
  }

  func dismissSend() {
    pendingRecord = nil
    candidates = []
    selectedCandidateID = nil
  }

  func prepareSend() {
    guard let record = pendingRecord, let connectionID,
      let connection = connections.first(where: { $0.id == connectionID })
    else { return }
    let products = selectedProducts(record)
    guard !products.isEmpty else { error = "Select at least one available product."; return }
    isBusy = true
    Task {
      defer { isBusy = false }
      do {
        let token = try StorytellerConnectionStore.shared.token(connectionID)
        let client = try StorytellerClient(origin: connection.origin, tokenProvider: { token })
        let link = record.remoteLinks.first {
          $0.providerID == "storyteller" && $0.connectionID == connectionID
        }
        let localProducts = record.products.map { product in
          StorytellerLocalProductIdentity(
            format: Self.remoteFormat(product.kind), size: product.size, sha256: product.sha256)
        }
        let resolution = try await StorytellerIdentityResolver(client: client).resolve(
          local: .init(
            title: record.metadata.title, author: record.metadata.author,
            identifiers: record.metadata.identifiers, products: localProducts,
            excludedBookIDs: Set(
              link?.excludedRemoteBookIDs.compactMap(UUID.init(uuidString:)) ?? [])),
          linkedBookID: link.flatMap { UUID(uuidString: $0.remoteBookID) })
        switch resolution {
        case .linked(let id): try await submit(record, remoteID: id, evidence: link?.evidence)
        case .automatic(let id, let evidence):
          try await submit(
            record, remoteID: id,
            evidence: evidence == .exactAssetHash ? .exactAssetHash : .validatedIdentifier)
        case .create:
          try await submit(
            record, remoteID: DeterministicBookID.make(catalogID: record.id),
            evidence: .uploadCreated)
        case .review(let values):
          candidates = values
          selectedCandidateID = values.first?.id
        }
      } catch { self.error = error.localizedDescription }
    }
  }

  func attachSelectedCandidate() {
    guard let record = pendingRecord, let selectedCandidateID else { return }
    Task {
      do { try await submit(record, remoteID: selectedCandidateID, evidence: .userConfirmed) }
      catch { self.error = error.localizedDescription }
    }
  }

  func createSeparate() {
    guard let record = pendingRecord, let connectionID else { return }
    Task {
      do {
        var updated = record
        let exclusions = candidates.map { $0.id.uuidString.lowercased() }
        updated.upsertRemoteLink(
          .init(
            providerID: "storyteller", connectionID: connectionID,
            remoteBookID: DeterministicBookID.make(catalogID: record.id).uuidString.lowercased(),
            evidence: .uploadCreated, excludedRemoteBookIDs: exclusions))
        try await catalogStore.update(updated, expectedRevision: record.revision)
        try await submit(
          updated, remoteID: DeterministicBookID.make(catalogID: record.id),
          evidence: .uploadCreated)
      } catch { self.error = error.localizedDescription }
    }
  }

  func forgetLink(_ record: BookCatalogRecord, connectionID: UUID) {
    Task {
      do {
        var updated = record
        updated.remoteLinks.removeAll {
          $0.providerID == "storyteller" && $0.connectionID == connectionID
        }
        updated.touch()
        try await catalogStore.update(updated, expectedRevision: record.revision)
        await reload()
      } catch { self.error = error.localizedDescription }
    }
  }

  private func submit(
    _ record: BookCatalogRecord, remoteID: UUID,
    evidence: BookCatalogRemoteLink.Evidence?
  ) async throws {
    guard let connectionID else { throw StorytellerAPIError.authenticationRequired }
    var updated = record
    let previous = updated.remoteLinks.first {
      $0.providerID == "storyteller" && $0.connectionID == connectionID
    }
    updated.upsertRemoteLink(
      .init(
        providerID: "storyteller", connectionID: connectionID,
        remoteBookID: remoteID.uuidString.lowercased(),
        evidence: evidence ?? .userConfirmed,
        excludedRemoteBookIDs: previous?.excludedRemoteBookIDs ?? []))
    if updated != record {
      try await catalogStore.update(updated, expectedRevision: record.revision)
    }
    let products = selectedProducts(updated)
    let source = updated.product(.sourceEPUB)!
    let narration = updated.product(.m4b)?.narration
      ?? .init(
        backendID: "siri", modelID: "siri-private", voiceID: "delivery-only",
        includedSectionIDs: [], bitrateKbps: 256, workers: 1,
        paragraphPauseSeconds: 0.6, chapterPauseSeconds: 1.75, announceTitles: false)
    let readAloud = updated.product(.readAloudEPUB).map {
      BookJobRequest.ReadAloud(
        outputPath: $0.path, opusBitrateKbps: $0.readAloud?.opusBitrateKbps ?? 32)
    }
    let request = BookJobRequest(
      catalogID: updated.id, managedByStudio: true, title: updated.metadata.title,
      author: updated.metadata.author,
      source: .init(
        path: source.path, sha256: updated.source.sha256, format: "epub",
        importerVersion: updated.source.importerVersion,
        identifiers: updated.metadata.identifiers.map(\.value),
        typedIdentifiers: updated.metadata.identifiers),
      narration: narration, m4bOutputPath: updated.layout.audiobook.path,
      readAloud: readAloud,
      storyteller: .init(
        connectionID: connectionID, remoteBookID: remoteID, products: products),
      operation: .storytellerDelivery)
    let failures = await coordinator.enqueue([request])
    if let failure = failures[request.id] { throw BookJobError.io(failure) }
    dismissSend()
    await reload()
  }

  private func selectedProducts(_ record: BookCatalogRecord) -> Set<BookProductKind> {
    var result = Set<BookProductKind>()
    if sendEPUB, record.product(.sourceEPUB) != nil { result.insert(.sourceEPUB) }
    if sendM4B, record.product(.m4b) != nil { result.insert(.m4b) }
    if sendReadAloud, record.product(.readAloudEPUB) != nil { result.insert(.readAloudEPUB) }
    return result
  }

  private static func remoteFormat(_ kind: BookProductKind) -> StorytellerFormat {
    switch kind {
    case .sourceEPUB: .ebook
    case .m4b: .audiobook
    case .readAloudEPUB: .readaloud
    }
  }
}

struct StudioLibraryView: View {
  @Bindable var model: StudioLibraryModel
  let createAudiobook: (BookCatalogRecord) -> Void

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("Library").font(.title2.bold())
        Spacer()
        Button {
          Task { await model.reload() }
        } label: { Label("Refresh", systemImage: "arrow.clockwise") }
      }.padding(20)
      Divider()
      if model.records.isEmpty {
        ContentUnavailableView(
          "No cataloged books", systemImage: "books.vertical",
          description: Text("Books processed by the new Studio workflow appear here."))
      } else {
        List(model.records) { record in
          VStack(alignment: .leading, spacing: 7) {
            HStack {
              VStack(alignment: .leading) {
                Text(record.metadata.title).font(.headline)
                if let author = record.metadata.author {
                  Text(author).font(.caption).foregroundStyle(.secondary)
                }
              }
              Spacer()
              productBadge("E", present: record.product(.sourceEPUB) != nil)
              productBadge("A", present: record.product(.m4b) != nil)
              productBadge("R", present: record.product(.readAloudEPUB) != nil)
            }
            HStack {
              if record.product(.m4b) == nil {
                Button("Create Audiobook…") { createAudiobook(record) }
              } else if record.product(.readAloudEPUB) == nil {
                Button("Create ReadAloud") { model.createReadAloud(record) }
              }
              if !model.connections.isEmpty { Button("Send…") { model.beginSend(record) } }
              Spacer()
              Button("Reveal") { NSWorkspace.shared.open(record.layout.directory) }
            }
          }.padding(.vertical, 5)
        }
      }
      if let error = model.error {
        Text(error).foregroundStyle(.red).padding(.horizontal, 20).padding(.bottom, 10)
      }
      ForEach(model.issues, id: \.self) { issue in
        Text("Unreadable catalog entry: \(issue)")
          .font(.caption).foregroundStyle(.red)
          .padding(.horizontal, 20).padding(.bottom, 6)
      }
    }
    .task { await model.reload() }
    .sheet(item: $model.pendingRecord) { record in
      StudioLibrarySendSheet(model: model, record: record)
    }
  }

  private func productBadge(_ value: String, present: Bool) -> some View {
    Text(value).font(.caption.bold()).padding(5)
      .background(present ? Color.green.opacity(0.22) : Color.secondary.opacity(0.12), in: Capsule())
  }
}

private struct StudioLibrarySendSheet: View {
  @Bindable var model: StudioLibraryModel
  let record: BookCatalogRecord
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Send to Storyteller").font(.title2.bold())
      Text(record.metadata.title).foregroundStyle(.secondary)
      Picker("Server", selection: $model.connectionID) {
        ForEach(model.connections) { connection in
          Text("\(connection.displayName) — \(connection.username)")
            .tag(Optional(connection.id))
        }
      }
      Toggle("Original EPUB", isOn: $model.sendEPUB)
        .disabled(record.product(.sourceEPUB) == nil)
      Toggle("M4B audiobook", isOn: $model.sendM4B)
        .disabled(record.product(.m4b) == nil)
      Toggle("ReadAloud EPUB", isOn: $model.sendReadAloud)
        .disabled(record.product(.readAloudEPUB) == nil)
      if !model.candidates.isEmpty {
        Text("Possible existing books require review:").font(.headline)
        Picker("Existing book", selection: $model.selectedCandidateID) {
          ForEach(model.candidates) { candidate in
            Text("\(candidate.book.title) — \(candidate.book.authors.map(\.name).joined(separator: ", "))")
              .tag(Optional(candidate.id))
          }
        }
        HStack {
          Button("Attach Existing") { model.attachSelectedCandidate() }
          Button("Create Separate") { model.createSeparate() }
        }
      }
      if let error = model.error { Text(error).font(.caption).foregroundStyle(.red) }
      HStack {
        Button("Cancel") { model.dismissSend() }
        Spacer()
        if model.isBusy { ProgressView().controlSize(.small) }
        if model.candidates.isEmpty {
          Button("Preflight and Send") { model.prepareSend() }
            .keyboardShortcut(.defaultAction).disabled(model.isBusy)
        }
      }
    }.padding(20).frame(width: 520)
  }
}

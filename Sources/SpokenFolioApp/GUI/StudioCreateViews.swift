import AppKit
import AudiobookKit
import ReadAloudKit
import SiriTTSCore
import StorytellerKit
import SwiftUI
import TTSKit

/// Compatibility entry point for callers that still present Create directly.
struct StudioCreateView: View {
  @Bindable var model: StudioCreateModel

  var body: some View { CreateBatchView(model: model) }
}

struct CreateBatchView: View {
  @Bindable var model: StudioCreateModel
  @State private var confirmClear = false

  var body: some View {
    VStack(spacing: 0) {
      issueArea
      if model.drafts.isEmpty {
        // ContentUnavailableView is not greedy; without an explicit fill the
        // banner-plus-empty-state cluster floats vertically centered.
        emptyView.frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        batchWorkspace
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .task { await model.start() }
    .dropDestination(for: URL.self) { urls, _ in
      let epubs = urls.filter { url in
        url.isFileURL && url.pathExtension.lowercased() == "epub"
          && (try? url.checkResourceIsReachable()) == true
          && FileManager.default.isReadableFile(atPath: url.path)
      }
      guard !epubs.isEmpty else { return false }
      // The model receives everything so skipped files are reported, not
      // silently ignored; the return value only decides the drop animation.
      model.addBooks(urls)
      return true
    }
    .alert("Clear this batch?", isPresented: $confirmClear) {
      Button("Clear Batch", role: .destructive) { model.reset() }
      Button("Keep Batch", role: .cancel) {}
    } message: {
      Text("Imported selections and unqueued overrides will be discarded. Source EPUB files are not changed.")
    }
  }

  @ViewBuilder private var issueArea: some View {
    if let warning = model.permissionWarning {
      Label(warning, systemImage: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(.orange.opacity(0.08))
    }
    if let error = model.error {
      Label(error, systemImage: "xmark.octagon.fill")
        .foregroundStyle(.red)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(.red.opacity(0.08))
    }
    if let notice = model.notice {
      Label(notice, systemImage: "info.circle")
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(.quaternary.opacity(0.4))
    }
  }

  private var emptyView: some View {
    ContentUnavailableView {
      Label("Create an Audiobook", systemImage: "waveform.badge.plus")
    } description: {
      Text("Choose one EPUB or a batch. SpokenFolio imports two at a time, then processes the durable queue in order.")
    } actions: {
      Button("Add EPUBs…") { model.requestBooks() }
        .keyboardShortcut("o", modifiers: .command)
        .buttonStyle(.borderedProminent)
      Text("You can also drop EPUB files anywhere in this window.")
        .font(.callout).foregroundStyle(.secondary)
    }
  }

  private var batchWorkspace: some View {
    VStack(spacing: 0) {
      GeometryReader { geometry in
        // Splits must be forced to the available size; see ActivityView.
        if geometry.size.width >= 720 {
          HSplitView {
            draftList
              .frame(minWidth: 240, idealWidth: 320, maxWidth: 460)
              .frame(maxHeight: .infinity)
            inspector
              .frame(minWidth: 400)
              .frame(maxWidth: .infinity, maxHeight: .infinity)
              .layoutPriority(1)
          }
          .frame(width: geometry.size.width, height: geometry.size.height)
        } else {
          VSplitView {
            draftList
              .frame(minHeight: 150, idealHeight: 210, maxHeight: 340)
              .frame(maxWidth: .infinity)
            inspector
              .frame(minHeight: 220)
              .frame(maxWidth: .infinity, maxHeight: .infinity)
              .layoutPriority(1)
          }
          .frame(width: geometry.size.width, height: geometry.size.height)
        }
      }
      Divider()
      actionBar
    }
  }

  private var draftList: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        VStack(alignment: .leading, spacing: 1) {
          Text("Books").font(.headline)
          Text("\(model.readyCount) ready · \(model.loadingCount) importing")
            .font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Button("Batch Settings") {
          model.selectedDraftIDs = []
          model.selectedDraftID = nil
        }
        .controlSize(.small)
      }
      .padding(12)
      Divider()
      List(selection: $model.selectedDraftIDs) {
        ForEach(model.drafts) { draft in
          StudioDraftRow(draft: draft, ordinal: model.drafts.firstIndex(where: { $0.id == draft.id }))
            .tag(draft.id)
            .contextMenu {
              if draft.canRetryImport {
                Button("Retry Import") { model.retryImports([draft.id]) }
              }
              Button("Remove from Batch", role: .destructive) { model.removeDraft(draft.id) }
            }
        }
        .onMove(perform: model.moveDrafts)
      }
    }
  }

  private var inspector: some View {
    Group {
      if model.selectedDrafts.count == 1, let draft = model.selectedDrafts.first {
        StudioDraftInspector(model: model, draft: draft)
      } else if model.selectedDrafts.count > 1 {
        StudioMultiDraftInspector(model: model, drafts: model.selectedDrafts)
      } else {
        StudioBatchSettingsView(model: model)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var actionBar: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 10) { actionButtons; Spacer(); queueControls }
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 10) { actionButtons; Spacer() }
        HStack { Spacer(); queueControls }
      }
    }
    .padding(.horizontal, 14).padding(.vertical, 10)
    .background(.bar)
  }

  @ViewBuilder private var actionButtons: some View {
    Button("Add EPUBs…") { model.requestBooks() }
    if !model.selectedDraftIDs.isEmpty {
      Button("Remove Selected") { model.removeDrafts(model.selectedDraftIDs) }
      if model.selectedDrafts.contains(where: \.canRetryImport) {
        Button("Retry Import") { model.retryImports(model.selectedDraftIDs) }
      }
    }
    Button("Clear Batch…", role: .destructive) { confirmClear = true }
  }

  @ViewBuilder private var queueControls: some View {
    if model.phase == .queueing { ProgressView().controlSize(.small) }
    Text(model.loadingCount > 0 ? "Waiting for imports" : "\(model.readyCount) ready")
      .font(.callout).foregroundStyle(.secondary)
    Button("Add \(model.readyCount) to Queue") { model.queueReadyBooks() }
      .keyboardShortcut(.defaultAction)
      .buttonStyle(.borderedProminent)
      .disabled(model.readyCount == 0 || model.loadingCount > 0 || model.phase == .queueing)
  }
}

private struct StudioDraftRow: View {
  @Bindable var draft: StudioBookDraft
  let ordinal: Int?

  var body: some View {
    HStack(spacing: 10) {
      Text("\((ordinal ?? 0) + 1)")
        .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
        .frame(width: 22, alignment: .trailing)
      if let cover = draft.coverImage {
        Image(nsImage: cover).resizable().aspectRatio(contentMode: .fit)
          .frame(width: 34, height: 48)
          .clipShape(RoundedRectangle(cornerRadius: 3))
      } else {
        Image(systemName: "book.closed")
          .foregroundStyle(.secondary).frame(width: 34, height: 48)
      }
      VStack(alignment: .leading, spacing: 2) {
        Text(draft.title.isEmpty ? draft.sourceURL.lastPathComponent : draft.title)
          .lineLimit(1)
        if !draft.author.isEmpty {
          Text(draft.author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        Label(draft.statusTitle, systemImage: draft.statusIcon)
          .font(.caption).foregroundStyle(draft.statusColor)
          .lineLimit(1)
      }
      Spacer(minLength: 0)
    }
    .padding(.vertical, 3)
  }
}

private struct StudioBatchSettingsView: View {
  @Bindable var model: StudioCreateModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        VStack(alignment: .leading, spacing: 3) {
          Text("Batch Settings").font(.title2.bold())
          Text("These settings apply to every book that has not been customized.")
            .foregroundStyle(.secondary)
          LabeledContent("Managed output") {
            Text(model.processedDirectory.path)
              .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
          }
          .font(.callout)
        }
        ProductionOptionsForm(
          voices: model.voices, connections: model.storytellerConnections,
          voiceID: $model.voiceID, bitrateKbps: $model.bitrateKbps,
          workers: $model.workers, announceTitles: $model.announceTitles,
          paragraphPause: $model.paragraphPause, chapterPause: $model.chapterPause,
          createReadAloud: $model.createReadAloud,
          readAloudBitrateKbps: $model.readAloudBitrateKbps,
          readAloudASREngineID: $model.readAloudASREngineID,
          readAloudASRModelID: $model.readAloudASRModelID,
          storytellerConnectionID: $model.storytellerConnectionID,
          sendSourceEPUB: $model.sendSourceEPUB, sendM4B: $model.sendM4B,
          sendReadAloud: $model.sendReadAloud)
      }
      .padding(18).frame(maxWidth: 720, alignment: .leading)
    }
  }
}

private struct StudioDraftInspector: View {
  @Bindable var model: StudioCreateModel
  @Bindable var draft: StudioBookDraft

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        HStack(alignment: .top, spacing: 14) {
          if let cover = draft.coverImage {
            Image(nsImage: cover).resizable().aspectRatio(contentMode: .fit)
              .frame(width: 64, height: 92).clipShape(RoundedRectangle(cornerRadius: 4))
          }
          VStack(alignment: .leading, spacing: 3) {
            Text(draft.title.isEmpty ? draft.sourceURL.lastPathComponent : draft.title)
              .font(.title2.bold()).textSelection(.enabled)
            if !draft.author.isEmpty { Text(draft.author).foregroundStyle(.secondary) }
            Text("\(draft.chapterCount) chapters · \(draft.sourceURL.lastPathComponent)")
              .font(.caption).foregroundStyle(.secondary)
          }
          Spacer()
          if draft.usesBatchDefaults {
            Button("Customize") { model.customize(draft) }
          } else {
            Button("Use Batch Settings") { model.resetToBatchDefaults(draft) }
          }
        }
        if draft.reprocessExistingAudiobook {
          Label(
            draft.catalogRecord?.product(.readAloudEPUB) != nil && !draft.createReadAloud
              ? "The M4B will be replaced. Its existing ReadAloud becomes stale until regenerated."
              : "A new guarded job will atomically replace the cataloged audiobook.",
            systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
            .foregroundStyle(.orange)
        }
        if let warning = draft.warning {
          Label(warning, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
        }
        if !draft.usesBatchDefaults {
          ProductionOptionsForm(
            voices: model.voices, connections: model.storytellerConnections,
            voiceID: $draft.voiceID, bitrateKbps: $draft.bitrateKbps,
            workers: $draft.workers, announceTitles: $draft.announceTitles,
            paragraphPause: $draft.paragraphPause, chapterPause: $draft.chapterPause,
            createReadAloud: $draft.createReadAloud,
            readAloudBitrateKbps: $draft.readAloudBitrateKbps,
            readAloudASREngineID: $draft.readAloudASREngineID,
            readAloudASRModelID: $draft.readAloudASRModelID,
            storytellerConnectionID: $draft.storytellerConnectionID,
            sendSourceEPUB: $draft.sendSourceEPUB, sendM4B: $draft.sendM4B,
            sendReadAloud: $draft.sendReadAloud)
        } else {
          Label("Using the current batch settings", systemImage: "arrow.triangle.branch")
            .font(.callout).foregroundStyle(.secondary)
        }

        VStack(alignment: .leading, spacing: 7) {
          Text("Output").font(.headline)
          HStack {
            Text((draft.outputDirectoryOverride ?? model.processedDirectory).path)
              .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            Spacer()
            if draft.outputDirectoryOverride != nil {
              Button("Use Managed") { draft.outputDirectoryOverride = nil }
            }
            Button("Choose…") { model.chooseDirectory(for: draft) }
          }
        }

        VStack(alignment: .leading, spacing: 7) {
          HStack {
            Text("Narrated Sections").font(.headline)
            Spacer()
            Text("\(draft.sections.filter(\.included).count) of \(draft.sections.count)")
              .font(.caption).foregroundStyle(.secondary)
            Button("Restore Recommended") {
              for index in draft.sections.indices {
                draft.sections[index].included = draft.sections[index].initiallyIncluded
              }
            }
            .controlSize(.small)
          }
          LazyVStack(spacing: 0) {
            ForEach($draft.sections) { $section in
              Toggle(isOn: $section.included) {
                HStack {
                  Text(section.title).lineLimit(1)
                  Spacer()
                  Text(section.role).foregroundStyle(.secondary)
                  Text(section.characterCount.formatted())
                    .monospacedDigit().foregroundStyle(.secondary)
                }
              }
              .toggleStyle(.checkbox)
              .padding(.vertical, 5)
              Divider()
            }
          }
        }
      }
      .padding(18).frame(maxWidth: 760, alignment: .leading)
    }
  }
}

private struct StudioMultiDraftInspector: View {
  @Bindable var model: StudioCreateModel
  let drafts: [StudioBookDraft]

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("\(drafts.count) Books Selected").font(.title2.bold())
      Text("Use batch settings to remove per-book overrides, retry failed imports, or remove these books from the unqueued batch.")
        .foregroundStyle(.secondary)
      HStack {
        Button("Use Batch Settings") { drafts.forEach(model.resetToBatchDefaults) }
        if drafts.contains(where: \.canRetryImport) {
          Button("Retry Import") { model.retryImports(Set(drafts.map(\.id))) }
        }
        Button("Remove Selected", role: .destructive) {
          model.removeDrafts(Set(drafts.map(\.id)))
        }
      }
      Divider()
      List(drafts) { draft in
        HStack {
          VStack(alignment: .leading) {
            Text(draft.title.isEmpty ? draft.sourceURL.lastPathComponent : draft.title)
            if !draft.author.isEmpty {
              Text(draft.author).font(.caption).foregroundStyle(.secondary)
            }
          }
          Spacer()
          Text(draft.statusTitle).foregroundStyle(.secondary)
        }
      }
    }
    .padding(18).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}

private struct ProductionOptionsForm: View {
  let voices: [VoiceDescriptor]
  let connections: [StorytellerConnection]
  @Binding var voiceID: String
  @Binding var bitrateKbps: Int
  @Binding var workers: Int
  @Binding var announceTitles: Bool
  @Binding var paragraphPause: Double
  @Binding var chapterPause: Double
  @Binding var createReadAloud: Bool
  @Binding var readAloudBitrateKbps: Int
  @Binding var readAloudASREngineID: String
  @Binding var readAloudASRModelID: String
  @Binding var storytellerConnectionID: UUID?
  @Binding var sendSourceEPUB: Bool
  @Binding var sendM4B: Bool
  @Binding var sendReadAloud: Bool

  var body: some View {
    Form {
      Section("Audiobook") {
        AudiobookSettingsFields(
          voices: voices, voiceID: $voiceID, bitrateKbps: $bitrateKbps,
          workers: $workers, announceTitles: $announceTitles,
          paragraphPause: $paragraphPause, chapterPause: $chapterPause,
          announceTitlesLocked: createReadAloud)
      }

      Section("ReadAloud") {
        Toggle("Create synchronized ReadAloud EPUB", isOn: $createReadAloud)
        if createReadAloud {
          ReadAloudSettingsFields(
            opusBitrateKbps: $readAloudBitrateKbps,
            asrEngineID: $readAloudASREngineID,
            asrModelID: $readAloudASRModelID)
        }
      }

      if !connections.isEmpty {
        Section("Storyteller Delivery") {
          Toggle("Send finished products to Storyteller", isOn: deliveryEnabled)
          if deliveryEnabled.wrappedValue {
            Picker("Connection", selection: $storytellerConnectionID) {
              ForEach(connections) { connection in
                Text("\(connection.displayName) — \(connection.username)")
                  .tag(Optional(connection.id))
              }
            }
            Toggle("Source EPUB", isOn: $sendSourceEPUB)
            Toggle("AAC audiobook", isOn: $sendM4B)
            Toggle("ReadAloud EPUB", isOn: $sendReadAloud)
              .disabled(!createReadAloud)
          }
        }
      }
    }
    .formStyle(.grouped)
  }

  private var deliveryEnabled: Binding<Bool> {
    Binding(
      get: { sendSourceEPUB || sendM4B || sendReadAloud },
      set: { enabled in
        if enabled {
          sendSourceEPUB = true
          sendM4B = true
          sendReadAloud = createReadAloud
          if storytellerConnectionID == nil { storytellerConnectionID = connections.first?.id }
        } else {
          sendSourceEPUB = false
          sendM4B = false
          sendReadAloud = false
        }
      })
  }
}

private extension StudioBookDraft {
  var canRetryImport: Bool {
    switch status {
    case .invalid, .skipped: true
    default: false
    }
  }

  var statusTitle: String {
    switch status {
    case .loading: "Importing"
    case .ready:
      reprocessExistingAudiobook ? "Ready to Reprocess" : (catalogRecord == nil ? "Ready" : "In Library")
    case .invalid(let value): "Failed — \(value)"
    case .queued: "Added to Queue"
    case .skipped(let value): "Skipped — \(value)"
    }
  }

  var statusIcon: String {
    switch status {
    case .loading: "clock"
    case .ready: "checkmark.circle"
    case .invalid: "xmark.octagon"
    case .queued: "text.line.first.and.arrowtriangle.forward"
    case .skipped: "arrowshape.turn.up.forward"
    }
  }

  var statusColor: Color {
    switch status {
    case .invalid: .red
    case .skipped: .orange
    case .ready: .green
    default: .secondary
    }
  }
}

import AppKit
import AudiobookKit
import SwiftUI

struct StudioCreateView: View {
  @Bindable var model: StudioCreateModel

  var body: some View {
    VStack(spacing: 0) {
      if model.drafts.isEmpty {
        emptyView
      } else {
        configuration
        Divider()
        footer
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .task { await model.start() }
    .dropDestination(for: URL.self) { urls, _ in
      model.addBooks(urls)
      return urls.contains { $0.pathExtension.lowercased() == "epub" }
    }
  }

  private var emptyView: some View {
    ScrollView {
      VStack(spacing: 16) {
        Image(systemName: "books.vertical")
          .font(.system(size: 56)).foregroundStyle(.secondary)
        Text("Create audiobooks from EPUBs").font(.title2)
        Text(
          "Choose one book or an entire batch. Books are queued durably and processed one at a time."
        )
        .multilineTextAlignment(.center).foregroundStyle(.secondary)
        Button("Choose EPUBs…") { model.requestBooks() }
          .keyboardShortcut(.defaultAction)
        Text("…or drop EPUB files here").font(.callout).foregroundStyle(.tertiary)
        if let error = model.error { Text(error).foregroundStyle(.red) }
      }
      .padding(40)
      .frame(maxWidth: .infinity, minHeight: 480)
    }
  }

  private var configuration: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        HStack {
          VStack(alignment: .leading) {
            Text("Batch Settings").font(.title2.bold())
            Text("\(model.readyCount) ready · \(model.loadingCount) loading")
              .foregroundStyle(.secondary)
          }
          Spacer()
          Text(model.processedDirectory.path)
            .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
        }

        if let warning = model.permissionWarning {
          Label(warning, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.yellow)
        }
        if let error = model.error { Text(error).foregroundStyle(.red) }

        GroupBox("Defaults for books without overrides") {
          Form {
            Picker("Voice", selection: $model.voiceID) {
              ForEach(model.voices, id: \.key) { voice in
                Text("\(voice.name) — \(voice.language)").tag(voice.key.voiceID)
              }
            }
            Picker("AAC bitrate", selection: $model.bitrateKbps) {
              ForEach(AudiobookConfig.allowedBitratesKbps, id: \.self) { value in
                Text("\(value) kbps").tag(value)
              }
            }.pickerStyle(.segmented)
            Stepper("Synthesis workers: \(model.workers)", value: $model.workers, in: 1...16)
            Toggle("Announce chapter titles", isOn: $model.announceTitles)
              .disabled(model.createReadAloud)
            Toggle("Create ReadAloud EPUB", isOn: $model.createReadAloud)
            if model.createReadAloud {
              Picker("ReadAloud Opus", selection: $model.readAloudBitrateKbps) {
                ForEach([16, 32, 64, 96], id: \.self) { Text("\($0) kbps").tag($0) }
              }.pickerStyle(.segmented)
            }
            if !model.storytellerConnections.isEmpty {
              Picker("Storyteller", selection: $model.storytellerConnectionID) {
                ForEach(model.storytellerConnections) { connection in
                  Text("\(connection.displayName) — \(connection.username)")
                    .tag(Optional(connection.id))
                }
              }
              HStack {
                Toggle("Send EPUB", isOn: $model.sendSourceEPUB)
                Toggle("Send M4B", isOn: $model.sendM4B)
                Toggle("Send ReadAloud", isOn: $model.sendReadAloud)
                  .disabled(!model.createReadAloud)
              }
            }
          }
          .formStyle(.grouped)
        }

        HStack(alignment: .top, spacing: 14) {
          VStack(alignment: .leading, spacing: 8) {
            Text("Selected Books").font(.headline)
            List(model.drafts, selection: $model.selectedDraftID) { draft in
              StudioDraftRow(draft: draft).tag(draft.id)
            }
            .frame(minHeight: 200, idealHeight: 260, maxHeight: 320)
          }
          .frame(minWidth: 280, idealWidth: 360)

          if let draft = model.selectedDraft {
            StudioDraftInspector(model: model, draft: draft)
              .frame(maxWidth: .infinity, alignment: .leading)
          } else {
            ContentUnavailableView("Select a book", systemImage: "book")
              .frame(maxWidth: .infinity, minHeight: 260)
          }
        }
      }
      .padding(20)
    }
  }

  private var footer: some View {
    HStack {
      Button("Add Books…") { model.requestBooks() }
      Button("Start Over") { model.reset() }
      Spacer()
      if model.phase == .queueing { ProgressView().controlSize(.small) }
      Button("Queue \(model.readyCount) Books") { model.queueReadyBooks() }
        .keyboardShortcut(.defaultAction)
        .disabled(model.readyCount == 0 || model.loadingCount > 0 || model.phase == .queueing)
    }
    .padding(.horizontal, 20).padding(.vertical, 12)
    .background(.bar)
  }
}

private struct StudioDraftRow: View {
  @Bindable var draft: StudioBookDraft
  var body: some View {
    HStack(spacing: 10) {
      if let cover = draft.coverImage {
        Image(nsImage: cover).resizable().aspectRatio(contentMode: .fit)
          .frame(width: 32, height: 46)
      }
      VStack(alignment: .leading) {
        Text(draft.title.isEmpty ? draft.sourceURL.lastPathComponent : draft.title)
          .lineLimit(1)
        if !draft.author.isEmpty {
          Text(draft.author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        status.font(.caption).foregroundStyle(statusColor)
      }
      Spacer()
    }.padding(.vertical, 2)
  }

  private var status: Text {
    switch draft.status {
    case .loading: Text("Reading…")
    case .ready: Text(draft.catalogRecord == nil ? "Ready" : "In Library")
    case .invalid(let value): Text(value)
    case .queued: Text("Queued")
    case .skipped(let value): Text(value)
    }
  }
  private var statusColor: Color {
    switch draft.status {
    case .invalid: .red
    case .queued: .green
    default: .secondary
    }
  }
}

private struct StudioDraftInspector: View {
  @Bindable var model: StudioCreateModel
  @Bindable var draft: StudioBookDraft

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text(draft.title).font(.headline)
        Spacer()
        if draft.usesBatchDefaults {
          Button("Customize") { model.customize(draft) }
        } else {
          Button("Reset to Batch Defaults") { model.resetToBatchDefaults(draft) }
        }
      }
      Text("\(draft.chapterCount) chapters · \(draft.sourceURL.lastPathComponent)")
        .font(.caption).foregroundStyle(.secondary)
      if let warning = draft.warning {
        Text(warning).font(.caption).foregroundStyle(.orange)
      }
      if !draft.usesBatchDefaults {
        Picker("Voice", selection: $draft.voiceID) {
          ForEach(model.voices, id: \.key) { voice in
            Text("\(voice.name) — \(voice.language)").tag(voice.key.voiceID)
          }
        }
        Picker("AAC", selection: $draft.bitrateKbps) {
          ForEach(AudiobookConfig.allowedBitratesKbps, id: \.self) {
            Text("\($0) kbps").tag($0)
          }
        }.pickerStyle(.segmented)
        Toggle("Announce chapter titles", isOn: $draft.announceTitles)
          .disabled(draft.createReadAloud)
        Toggle("Create ReadAloud", isOn: $draft.createReadAloud)
      }
      HStack {
        Text("Output: \((draft.outputDirectoryOverride ?? model.processedDirectory).path)")
          .lineLimit(1).truncationMode(.middle).font(.caption).foregroundStyle(.secondary)
        Spacer()
        Button("Choose Folder…") { model.chooseDirectory(for: draft) }
      }
      DisclosureGroup("Sections") {
        LazyVStack(alignment: .leading, spacing: 5) {
          ForEach($draft.sections) { $section in
            Toggle(isOn: $section.included) {
              HStack {
                Text(section.title).lineLimit(1)
                Spacer()
                Text(section.role).font(.caption).foregroundStyle(.secondary)
                Text("\(section.characterCount)").font(.caption.monospacedDigit())
              }
            }
          }
        }
      }
    }
    .padding(12)
    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
  }
}

import AppKit
import AudiobookKit
import SwiftUI

struct AudiobookRootView: View {
  @Bindable var model: AudiobookViewModel

  var body: some View {
    Group {
      switch model.phase {
      case .pickBook:
        PickBookView(model: model)
      case .configure:
        ConfigureView(model: model)
      case .running:
        RunningView(model: model)
      case .done(let url):
        DoneView(model: model, outputURL: url)
      case .failed(let message):
        FailedView(model: model, message: message)
      }
    }
    .frame(minWidth: 560, minHeight: 480)
  }
}

private struct PickBookView: View {
  @Bindable var model: AudiobookViewModel

  var body: some View {
    VStack(spacing: 16) {
      Image(systemName: "book.closed")
        .font(.system(size: 56))
        .foregroundStyle(.secondary)
      Text("Create an audiobook from an EPUB")
        .font(.title2)
      Text("The book is narrated with an installed Siri voice into an M4B audiobook\nwith chapters, cover art, and metadata.")
        .multilineTextAlignment(.center)
        .foregroundStyle(.secondary)
      if model.isLoadingBook {
        ProgressView()
        Text("Reading \(model.loadingBookName)…")
          .font(.callout)
          .foregroundStyle(.secondary)
      } else {
        Button("Choose EPUB…") { model.requestBookPicker() }
          .keyboardShortcut(.defaultAction)
        Text("…or drop an EPUB file here")
          .font(.callout)
          .foregroundStyle(.tertiary)
      }
    }
    .padding(40)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    // A second, panel-free way in: dropping a book straight onto the window
    // involves no open-panel service at all.
    .dropDestination(for: URL.self) { urls, _ in
      guard !model.isLoadingBook,
        let url = urls.first(where: { $0.pathExtension.lowercased() == "epub" })
      else { return false }
      model.loadBook(at: url)
      return true
    }
  }
}

private struct ConfigureView: View {
  @Bindable var model: AudiobookViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top, spacing: 16) {
        if let cover = model.coverImage {
          Image(nsImage: cover)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 96, height: 144)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .shadow(radius: 2)
        }
        VStack(alignment: .leading, spacing: 4) {
          Text(model.bookTitle).font(.title2).bold()
          if !model.bookAuthor.isEmpty {
            Text(model.bookAuthor).foregroundStyle(.secondary)
          }
          Text("\(model.chapterPreviewCount) chapters with default sections")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        Spacer()
      }

      if let warning = model.permissionWarning {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.yellow)
          Text(warning)
            .font(.callout)
          Spacer()
          Button("Open Settings") { model.openFullDiskAccessSettings() }
            .controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(.yellow.opacity(0.12)))
      }

      Form {
        Picker("Voice", selection: $model.selectedVoiceID) {
          ForEach(model.voices, id: \.key) { voice in
            Text("\(voice.name) — \(voice.language)").tag(voice.key.voiceID)
          }
        }
        Picker("Bitrate", selection: $model.bitrateKbps) {
          ForEach(AudiobookConfig.allowedBitratesKbps, id: \.self) { rate in
            Text("\(rate) kbps").tag(rate)
          }
        }
        .pickerStyle(.segmented)
        Toggle("Announce chapter titles", isOn: $model.announceTitles)
        DisclosureGroup("Advanced") {
          Stepper(value: $model.workers, in: 1...16) {
            HStack {
              Text("Synthesis workers")
              Spacer()
              Text("\(model.workers)").monospacedDigit().foregroundStyle(.secondary)
            }
          }
          HStack {
            Text("Paragraph pause")
            Slider(value: $model.paragraphPause, in: 0...3, step: 0.1)
            Text(String(format: "%.1f s", model.paragraphPause)).monospacedDigit()
          }
          HStack {
            Text("Chapter pause")
            Slider(value: $model.chapterPause, in: 0...5, step: 0.25)
            Text(String(format: "%.1f s", model.chapterPause)).monospacedDigit()
          }
        }
      }

      HStack {
        Text("Sections").font(.headline)
        Spacer()
        Button("Restore Defaults") { model.restoreDefaultSections() }
          .controlSize(.small)
      }
      List($model.sections) { $section in
        HStack {
          Toggle(isOn: $section.included) {
            HStack {
              Text(section.title).lineLimit(1)
              Spacer()
              Text(section.role)
                .font(.caption)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.secondary.opacity(0.15)))
              Text("\(section.characterCount)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .trailing)
            }
          }
        }
      }
      .frame(minHeight: 140)

      HStack {
        Button("Back") { model.reset() }
        Spacer()
        if let output = model.outputURL {
          Text(output.lastPathComponent)
            .lineLimit(1)
            .truncationMode(.middle)
            .foregroundStyle(.secondary)
          Button("Change…") { model.chooseOutput() }
        }
        Button("Create Audiobook") { model.start() }
          .keyboardShortcut(.defaultAction)
          .disabled(model.outputURL == nil || model.selectedVoiceID.isEmpty)
      }
    }
    .padding(20)
  }
}

private struct RunningView: View {
  @Bindable var model: AudiobookViewModel

  var body: some View {
    VStack(spacing: 18) {
      Spacer()
      if let cover = model.coverImage {
        Image(nsImage: cover)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(maxHeight: 150)
          .clipShape(RoundedRectangle(cornerRadius: 8))
          .shadow(radius: 3)
      }
      Text(model.bookTitle).font(.title3).bold()

      VStack(spacing: 8) {
        HStack(alignment: .firstTextBaseline) {
          ProgressView(value: model.progressFraction)
          Text(model.percentText)
            .font(.title3.monospacedDigit().weight(.semibold))
            .frame(width: 56, alignment: .trailing)
        }
        Text(model.primaryStatus)
          .font(.headline)
          .lineLimit(1)
          .truncationMode(.tail)
          .frame(maxWidth: .infinity, alignment: .leading)
        // Ticks once a second so elapsed/remaining stay live between
        // pipeline events.
        TimelineView(.periodic(from: .now, by: 1)) { context in
          Text(model.secondaryStatus(now: context.date))
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .frame(maxWidth: 440)

      Spacer()
      HStack {
        Text("Closing this window keeps the job running.")
          .font(.caption)
          .foregroundStyle(.tertiary)
        Spacer()
        Button("Cancel") { model.cancel() }
      }
    }
    .padding(24)
  }
}

private struct DoneView: View {
  @Bindable var model: AudiobookViewModel
  let outputURL: URL

  var body: some View {
    VStack(spacing: 16) {
      Image(systemName: "checkmark.circle.fill")
        .font(.system(size: 56))
        .foregroundStyle(.green)
      Text("Audiobook created").font(.title2)
      Text(outputURL.lastPathComponent)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
      HStack(spacing: 12) {
        Button("Reveal in Finder") {
          NSWorkspace.shared.activateFileViewerSelecting([outputURL])
        }
        Button("Create Another") { model.reset() }
      }
    }
    .padding(40)
  }
}

private struct FailedView: View {
  @Bindable var model: AudiobookViewModel
  let message: String

  var body: some View {
    VStack(spacing: 16) {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.system(size: 48))
        .foregroundStyle(.yellow)
      Text("Audiobook not created").font(.title2)
      Text(message)
        .multilineTextAlignment(.center)
        .foregroundStyle(.secondary)
        .frame(maxWidth: 420)
      Button("Start Over") { model.reset() }
    }
    .padding(40)
  }
}

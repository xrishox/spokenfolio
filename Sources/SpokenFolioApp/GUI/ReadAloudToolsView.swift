import AppKit
import Observation
import ReadAloudKit
import SwiftUI

enum ReadAloudToolStatus: Equatable {
  case checking
  case ready(String)
  case needsAttention(String)

  var title: String {
    switch self {
    case .checking: "Checking…"
    case .ready(let detail), .needsAttention(let detail): detail
    }
  }

  var icon: String {
    switch self {
    case .checking: "clock"
    case .ready: "checkmark.circle.fill"
    case .needsAttention: "exclamationmark.triangle.fill"
    }
  }
}

@MainActor @Observable
final class ReadAloudToolsModel {
  private(set) var stalign: ReadAloudToolStatus = .checking
  private(set) var mediaTools: ReadAloudToolStatus = .checking
  private(set) var operationMessage: String?
  private(set) var isBusy = false

  @ObservationIgnored private var installTask: Task<Void, Never>?

  func refresh() async {
    stalign = .checking
    mediaTools = .checking
    operationMessage = nil

    let mediaReady: Bool
    do {
      let tools = try ReadAloudTools.resolveFFmpegOnly()
      mediaTools = .ready("ffmpeg and ffprobe found at \(tools.ffmpeg.deletingLastPathComponent().path)")
      mediaReady = true
    } catch {
      mediaTools = .needsAttention(error.localizedDescription)
      mediaReady = false
    }

    guard mediaReady else {
      if FileManager.default.isExecutableFile(atPath: AppPaths.managedStalignURL.path) {
        stalign = .needsAttention("Installed; full verification is waiting for ffmpeg and ffprobe")
      } else {
        stalign = .needsAttention("stalign \(ReadAloudTools.pinnedStalignVersion) is not installed")
      }
      return
    }

    do {
      let tools = try await ReadAloudTools.resolve(managedStalign: AppPaths.managedStalignURL)
      stalign = .ready("Version \(tools.stalignVersion), signature and checksum verified")
    } catch {
      stalign = .needsAttention(error.localizedDescription)
    }
  }

  func startInstall() {
    guard !isBusy else { return }
    isBusy = true
    operationMessage = "Downloading and verifying the pinned stalign release…"
    installTask = Task { [weak self] in
      guard let self else { return }
      do {
        try await ReadAloudTools.installStalign(destination: AppPaths.managedStalignURL)
        guard !Task.isCancelled else { throw CancellationError() }
        await refresh()
        operationMessage = "stalign was installed and verified."
      } catch is CancellationError {
        operationMessage = "Installation cancelled."
      } catch {
        stalign = .needsAttention(error.localizedDescription)
        operationMessage = "Installation failed."
      }
      isBusy = false
      installTask = nil
    }
  }

  func cancelInstall() { installTask?.cancel() }

  func copyFFmpegCommand() {
    operationMessage = PasteboardWriter.copy("brew install ffmpeg")
      ? "Copied “brew install ffmpeg”."
      : "Could not write to the clipboard. Copy “brew install ffmpeg” manually."
  }
}

struct ToolsView: View {
  @Bindable var model: ReadAloudToolsModel

  var body: some View {
    Form {
      Section {
        Text(
          "ReadAloud creation needs the pinned stalign release plus ffmpeg and ffprobe. SpokenFolio verifies stalign’s checksum, version, and Apple signing team before using it."
        )
        .foregroundStyle(.secondary)
      }

      Section("Alignment") {
        toolRow("stalign \(ReadAloudTools.pinnedStalignVersion)", status: model.stalign)
        HStack {
          if model.isBusy {
            Button("Cancel Installation", role: .cancel) { model.cancelInstall() }
            ProgressView().controlSize(.small)
          } else {
            Button("Install or Repair stalign") { model.startInstall() }
          }
        }
      }

      Section("Audio tools") {
        toolRow("ffmpeg and ffprobe", status: model.mediaTools)
        Button("Copy Homebrew Install Command") { model.copyFFmpegCommand() }
      }

      if let message = model.operationMessage {
        Section {
          Text(message).foregroundStyle(.secondary).textSelection(.enabled)
        }
      }
    }
    .formStyle(.grouped)
    .task {
      if !model.isBusy { await model.refresh() }
    }
  }

  private func toolRow(_ name: String, status: ReadAloudToolStatus) -> some View {
    LabeledContent(name) {
      Label(status.title, systemImage: status.icon)
        .foregroundStyle(statusColor(status))
        .multilineTextAlignment(.trailing)
        .textSelection(.enabled)
    }
  }

  private func statusColor(_ status: ReadAloudToolStatus) -> Color {
    switch status {
    case .checking: .secondary
    case .ready: .green
    case .needsAttention: .orange
    }
  }
}

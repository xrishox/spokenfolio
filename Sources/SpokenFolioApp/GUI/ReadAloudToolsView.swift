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
  private(set) var publicationTools: ReadAloudToolStatus = .checking
  private(set) var operationMessage: String?
  private(set) var isBusy = false
  private(set) var installedStalignVersion: String?
  private(set) var availableStalignVersion: String?

  @ObservationIgnored private var installTask: Task<Void, Never>?
  @ObservationIgnored private let services: StudioServices?

  init(services: StudioServices? = nil) {
    self.services = services
  }

  func refresh() async {
    stalign = .checking
    mediaTools = .checking
    publicationTools = .checking
    operationMessage = nil
    installedStalignVersion = nil
    availableStalignVersion = nil

    do {
      let tools = try await ReadAloudTools.resolveEPUBCompliance()
      if let calibreVersion = tools.calibreVersion {
        publicationTools = .ready("\(tools.version); \(calibreVersion)")
      } else {
        publicationTools = .needsAttention(
          "\(tools.version) is ready; Calibre is missing, so EPUB 2 cannot be upgraded.")
      }
    } catch {
      publicationTools = .needsAttention(error.localizedDescription)
    }

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
        stalign = .needsAttention("stalign is not installed")
      }
      return
    }

    do {
      let tools = try await ReadAloudTools.resolve(managedStalign: AppPaths.managedStalignURL)
      installedStalignVersion = tools.stalignVersion
      do {
        let release = try await ReadAloudTools.latestStalignRelease()
        availableStalignVersion = release.version
        if release.version == tools.stalignVersion {
          stalign = .ready(
            "Version \(tools.stalignVersion), current and compatibility verified")
        } else {
          stalign = .needsAttention(
            "Version \(tools.stalignVersion) is ready; \(release.version) is available")
        }
      } catch {
        stalign = .ready(
          "Version \(tools.stalignVersion) is compatibility verified; update check failed")
      }
    } catch {
      stalign = .needsAttention(error.localizedDescription)
      if let release = try? await ReadAloudTools.latestStalignRelease() {
        availableStalignVersion = release.version
      }
    }
  }

  func startInstall() {
    guard !isBusy else { return }
    isBusy = true
    operationMessage = "Checking whether stalign can be updated safely…"
    installTask = Task { [weak self] in
      guard let self else { return }
      do {
        if let services {
          let jobs = await services.jobs.currentSnapshot
          guard jobs.runningCount == 0, !services.quality.currentSnapshot.isBusy else {
            throw ReadAloudError.invalidRequest(
              "stalign cannot be changed while production or a quality check is active")
          }
        }
        operationMessage =
          "Downloading and compatibility-testing the latest stable stalign…"
        let release = try await ReadAloudTools.installStalign(
          destination: AppPaths.managedStalignURL)
        guard !Task.isCancelled else { throw CancellationError() }
        await refresh()
        operationMessage = "stalign \(release.version) was installed and verified."
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

  func copyPublicationToolsCommand() {
    let command = "brew install epubcheck && brew install --cask calibre"
    operationMessage = PasteboardWriter.copy(command)
      ? "Copied the EPUB tools installation command."
      : "Could not write to the clipboard. Copy “\(command)” manually."
  }
}

struct ToolsView: View {
  @Bindable var model: ReadAloudToolsModel

  var body: some View {
    Form {
      Section {
        Text(
          "ReadAloud creation uses an external, compatibility-tested stalign release plus ffmpeg/ffprobe and EPUBCheck. Calibre is used only to upgrade legacy EPUB 2 sources; EPUB 3 books bypass it."
        )
        .foregroundStyle(.secondary)
      }

      Section("Alignment") {
        toolRow("stalign", status: model.stalign)
        HStack {
          if model.isBusy {
            Button("Cancel Installation", role: .cancel) { model.cancelInstall() }
            ProgressView().controlSize(.small)
          } else {
            Button(
              model.installedStalignVersion == nil
                ? "Install Latest Stable stalign"
                : model.availableStalignVersion == model.installedStalignVersion
                  ? "Reinstall stalign"
                  : "Update stalign"
            ) { model.startInstall() }
          }
        }
      }

      Section("Audio tools") {
        toolRow("ffmpeg and ffprobe", status: model.mediaTools)
        Button("Copy Homebrew Install Command") { model.copyFFmpegCommand() }
      }

      Section("EPUB tools") {
        toolRow("EPUBCheck and Calibre", status: model.publicationTools)
        Button("Copy Homebrew Install Command") { model.copyPublicationToolsCommand() }
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

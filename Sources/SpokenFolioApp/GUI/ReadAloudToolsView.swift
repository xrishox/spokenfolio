import Observation
import ReadAloudKit
import SwiftUI

@MainActor @Observable
final class ReadAloudToolsModel {
  var status = "Checking…"
  var isBusy = false

  func refresh() async {
    do {
      let tools = try await ReadAloudTools.resolve(managedStalign: AppPaths.managedStalignURL)
      status = "stalign \(tools.stalignVersion), ffmpeg and ffprobe are ready"
    } catch { status = error.localizedDescription }
  }

  func install() async {
    guard !isBusy else { return }
    isBusy = true
    status = "Downloading and verifying stalign…"
    defer { isBusy = false }
    do {
      try await ReadAloudTools.installStalign(destination: AppPaths.managedStalignURL)
      await refresh()
    } catch { status = error.localizedDescription }
  }
}

struct ToolsView: View {
  @Bindable var model: ReadAloudToolsModel

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("ReadAloud Tools").font(.title2.bold())
      Text(model.status)
      Text(
        "ReadAloud generation uses the pinned stalign release plus ffmpeg/ffprobe. The app verifies stalign's checksum and Apple signing team before installing it."
      )
      .foregroundStyle(.secondary)
      HStack {
        Button("Install or Repair stalign") { Task { await model.install() } }.disabled(model.isBusy)
        Button("Check Again") { Task { await model.refresh() } }.disabled(model.isBusy)
      }
      Spacer()
    }.padding(20).task { await model.refresh() }
  }
}

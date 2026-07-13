import AppKit
import BookJobKit
import SwiftUI

struct ActivityView: View {
  @Bindable var coordinator: StudioJobCoordinator

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading) {
          Text("Activity").font(.title2.bold())
          Text("\(coordinator.runningCount) running · \(coordinator.queuedCount) queued")
            .font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        if coordinator.isSuspended {
          Button("Resume Queue") { coordinator.resumeQueue() }.keyboardShortcut(.defaultAction)
        } else {
          Button("Pause Queue") { coordinator.pauseQueue() }
          Button("Pause Now") { coordinator.pauseQueue(interruptActive: true) }
        }
        Button {
          Task { await coordinator.reload() }
        } label: { Label("Refresh", systemImage: "arrow.clockwise") }
      }
      .padding(20)
      Divider()
      if coordinator.rows.isEmpty && coordinator.scanIssues.isEmpty {
        ContentUnavailableView(
          "No activity", systemImage: "waveform",
          description: Text("Queued audiobook, ReadAloud, and delivery jobs appear here."))
      } else {
        List {
          ForEach(coordinator.rows) { row in
            VStack(alignment: .leading, spacing: 6) {
              HStack {
                Text(row.request.title).font(.headline)
                if let ordinal = row.request.batchOrdinal, let count = row.request.batchCount {
                  Text("\(ordinal + 1)/\(count)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(row.state.lifecycle.rawValue).foregroundStyle(.secondary)
              }
              if let stage = row.state.stages.first(where: { $0.status == .running }) {
                ProgressView(value: stage.fraction ?? 0) {
                  Text(stage.message ?? stage.stage.rawValue)
                }
              }
              if let message = row.state.lastError {
                Text(message).font(.caption).foregroundStyle(.red)
              }
              HStack {
                if [.queued, .paused, .needsAttention].contains(row.state.lifecycle) {
                  Button("Resume") { coordinator.resumeJob(row.id) }
                }
                if row.state.lifecycle == .running {
                  Button("Pause") { coordinator.pauseJob(row.id) }
                }
                if ![.completed, .cancelled].contains(row.state.lifecycle) {
                  Button("Cancel…", role: .destructive) { coordinator.cancelJob(row.id) }
                }
                Spacer()
                if let product = row.state.products.last {
                  Button("Reveal") {
                    NSWorkspace.shared.activateFileViewerSelecting([
                      URL(fileURLWithPath: product.path)
                    ])
                  }
                }
              }
            }.padding(.vertical, 4)
          }
          ForEach(coordinator.scanIssues, id: \.directory) { issue in
            VStack(alignment: .leading) {
              Text("Unreadable job \(issue.directory)").font(.headline)
              Text(issue.message).font(.caption).foregroundStyle(.red)
            }
          }
        }
      }
    }
  }
}

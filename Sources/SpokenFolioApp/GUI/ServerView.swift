import SwiftUI

struct ServerView: View {
  @Bindable var runtime: ApplicationRuntime

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        Text("TTS Server").font(.title2.bold())
        GroupBox("Status") {
          VStack(alignment: .leading, spacing: 10) {
            Label(runtime.serverState.title, systemImage: statusIcon)
            if let endpoint = runtime.serverState.endpoint {
              HStack {
                Text(endpoint).textSelection(.enabled).monospaced()
                Button("Copy") { runtime.copyEndpoint() }
              }
            }
            Text("Trusted-LAN OpenAI-compatible gateway · mono 48 kHz · Opus, AAC, WAV, and PCM")
              .foregroundStyle(.secondary)
          }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }
        HStack {
          Button("Restart Server") { runtime.restartServer() }
          Button("Run Opus + AAC Test") { runtime.runConnectionTest() }
            .disabled(!canTest || runtime.connectionTestState == .running)
          if runtime.connectionTestState == .running { ProgressView().controlSize(.small) }
        }
        switch runtime.connectionTestState {
        case .passed:
          Label("Synthesis and decoded-frame verification passed", systemImage: "checkmark.circle.fill")
            .foregroundStyle(.green)
        case .failed(let message):
          Label("Connection test failed: \(message)", systemImage: "xmark.circle.fill")
            .foregroundStyle(.red)
        default: EmptyView()
        }
        GroupBox("Diagnostics") {
          HStack {
            Button("Open Full Disk Access…") { runtime.openFullDiskAccess() }
            Button("Open Console") { runtime.openConsole() }
          }.padding(6)
        }
        Spacer()
      }.padding(20)
    }
  }

  private var canTest: Bool {
    if case .ready = runtime.serverState { return true }
    return false
  }

  private var statusIcon: String {
    switch runtime.serverState {
    case .ready: "checkmark.circle.fill"
    case .degraded, .failed: "exclamationmark.triangle.fill"
    case .starting: "clock"
    case .stopped: "stop.circle"
    }
  }
}

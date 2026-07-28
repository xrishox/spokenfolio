import SwiftUI

struct ServerView: View {
  @Bindable var runtime: ApplicationRuntime
  @State private var copiedEndpoint = false
  @State private var publicModelID = ""
  @State private var backendID = ""
  @State private var modelID = ""
  @State private var voiceID = ""
  @State private var pacePreset: Int?
  @State private var expressivityPreset: Int?
  @State private var testText = "SpokenFolio can now test every installed voice and model."

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        statusHeader

        ViewThatFits(in: .horizontal) {
          HStack(alignment: .top, spacing: 16) {
            connectionPanel
            diagnosticsPanel
          }
          VStack(alignment: .leading, spacing: 16) {
            connectionPanel
            diagnosticsPanel
          }
        }

        Label(
          "The gateway has no authentication or TLS. Use it only on a trusted LAN, VPN, or behind an authenticated HTTPS proxy.",
          systemImage: "lock.open"
        )
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(24)
      .frame(maxWidth: 1_000, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .topLeading)
    }
    .navigationTitle("TTS Server")
    .toolbar {
      ToolbarItemGroup(placement: .primaryAction) {
        Button {
          runtime.restartServer()
        } label: {
          Label(restartTitle, systemImage: "arrow.clockwise")
        }
        .help(restartTitle)
        .disabled(isStarting)

        Button {
          runTest()
        } label: {
          Label("Test Audio", systemImage: "waveform")
        }
        .help(testHelp)
        .disabled(!canTest || runtime.connectionTestState == .running)
      }
    }
    .task(id: runtime.serverState) { loadDefaultSelectionIfNeeded() }
  }

  private var statusHeader: some View {
    HStack(alignment: .top, spacing: 14) {
      if isStarting {
        ProgressView()
          .controlSize(.large)
          .frame(width: 34, height: 34)
          .accessibilityHidden(true)
      } else {
        Image(systemName: statusIcon)
          .font(.system(size: 28))
          .foregroundStyle(statusColor)
          .accessibilityHidden(true)
      }
      VStack(alignment: .leading, spacing: 5) {
        Text(runtime.serverState.title).font(.title3.weight(.semibold))
        Text(statusExplanation).foregroundStyle(.secondary)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("TTS Server: \(runtime.serverState.title). \(statusExplanation)")
  }

  private var connectionPanel: some View {
    GroupBox("Connection") {
      VStack(alignment: .leading, spacing: 12) {
        if let endpoint = runtime.serverState.endpoint {
          LabeledContent("Address") {
            HStack(spacing: 8) {
              Text(endpoint).monospaced().textSelection(.enabled)
              Button(copiedEndpoint ? "Copied" : "Copy") { copyEndpoint() }
                .controlSize(.small)
            }
          }
        } else {
          Text("The network address becomes available after the listener starts.")
            .foregroundStyle(.secondary)
        }
        LabeledContent("API", value: "OpenAI-compatible /v1/audio/speech")
        LabeledContent("Audio", value: "Mono 48 kHz · Opus, AAC, WAV, PCM")
        Text("Successful requests are finalized in memory before the server returns HTTP 200.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding(6)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
  }

  private var diagnosticsPanel: some View {
    GroupBox("Verification") {
      VStack(alignment: .leading, spacing: 12) {
        if !runtime.ttsModels.isEmpty {
          TTSSelectionFields(
            models: runtime.ttsModels, voices: runtime.ttsVoices,
            publicModelID: $publicModelID, backendID: $backendID, modelID: $modelID,
            voiceID: $voiceID, pacePreset: $pacePreset,
            expressivityPreset: $expressivityPreset)
          Text("Test text")
            .font(.subheadline.weight(.medium))
          TextEditor(text: $testText)
            .frame(minHeight: 76)
            .overlay {
              RoundedRectangle(cornerRadius: 6)
                .stroke(.quaternary)
            }
            .accessibilityLabel("Test text")
          HStack {
            Text("\(testText.count) of 4,096 characters")
              .font(.caption).foregroundStyle(testTextIsValid ? Color.secondary : Color.red)
            Spacer()
            Button {
              runTest()
            } label: {
              Label("Test & Play", systemImage: "play.waveform")
            }
            .disabled(!canTest || !testTextIsValid || runtime.connectionTestState == .running)
          }
        }
        connectionTestResult
        Divider()
        Text("A health response alone does not prove that TTS synthesis and device codecs work.")
          .font(.caption)
          .foregroundStyle(.secondary)
        HStack {
          Button("Full Disk Access…") { runtime.openFullDiskAccess() }
          Button("Open Console") { runtime.openConsole() }
        }
        if let shutdownError = runtime.shutdownError {
          Label(shutdownError, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
            .textSelection(.enabled)
        }
      }
      .padding(6)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
  }

  @ViewBuilder private var connectionTestResult: some View {
    switch runtime.connectionTestState {
    case .idle:
      Label("Not tested this launch", systemImage: "circle.dashed")
        .foregroundStyle(.secondary)
    case .running:
      HStack {
        ProgressView().controlSize(.small)
        Text("Synthesizing and decoding Opus and AAC…")
      }
    case .passed:
      Label(
        "Opus and AAC decoded successfully; playing AAC", systemImage: "checkmark.circle.fill"
      )
      .foregroundStyle(.green)
    case .failed(let message):
      Label {
        Text("Audio test failed: \(message)").textSelection(.enabled)
      } icon: {
        Image(systemName: "xmark.circle.fill")
      }
      .foregroundStyle(.red)
    }
  }

  private func loadDefaultSelectionIfNeeded() {
    guard voiceID.isEmpty, let selection = runtime.defaultTTSSelection else { return }
    publicModelID = runtime.defaultTTSModelID
    backendID = selection.voice.backendID.rawValue
    modelID = selection.voice.modelID
    voiceID = selection.voice.voiceID
    pacePreset = selection.controls.pace?.rawValue
    expressivityPreset = selection.controls.expressivity?.rawValue
  }

  private func runTest() {
    guard testTextIsValid else { return }
    runtime.runConnectionTest(
      publicModelID: publicModelID, voiceID: voiceID,
      pacePreset: pacePreset, expressivityPreset: expressivityPreset,
      text: testText)
  }

  private var testTextIsValid: Bool {
    !testText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && testText.count <= 4_096 && !voiceID.isEmpty && !publicModelID.isEmpty
  }

  private func copyEndpoint() {
    guard runtime.copyEndpoint() else { return }
    copiedEndpoint = true
    Task {
      try? await Task.sleep(for: .seconds(2))
      copiedEndpoint = false
    }
  }

  private var testHelp: String {
    if runtime.connectionTestState == .running { return "Audio test in progress…" }
    if !canTest { return "Available when the server is ready" }
    return "Synthesizes the selected text, verifies Opus and AAC, then plays AAC"
  }

  private var restartTitle: String {
    if case .stopped = runtime.serverState { return "Start Server" }
    return "Restart Server"
  }

  private var canTest: Bool {
    if case .ready = runtime.serverState { return true }
    return false
  }

  private var isStarting: Bool {
    if case .starting = runtime.serverState { return true }
    return false
  }

  private var statusExplanation: String {
    switch runtime.serverState {
    case .ready: "The gateway is accepting speech requests."
    case .degraded: "The listener is running, but TTS synthesis needs attention."
    case .failed: "The gateway could not start. Use the actions below to inspect the failure."
    case .starting: "Discovering installed voices and starting the network listener."
    case .stopped: "The gateway is not currently accepting requests."
    }
  }

  private var statusIcon: String {
    switch runtime.serverState {
    case .ready: "checkmark.circle.fill"
    case .degraded, .failed: "exclamationmark.triangle.fill"
    case .starting: "clock"
    case .stopped: "stop.circle"
    }
  }

  private var statusColor: Color {
    switch runtime.serverState {
    case .ready: .green
    case .degraded, .failed: .orange
    case .starting: .blue
    case .stopped: .secondary
    }
  }
}

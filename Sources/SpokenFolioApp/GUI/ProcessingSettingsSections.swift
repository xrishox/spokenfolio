import AudiobookKit
import ReadAloudKit
import SiriTTSCore
import SwiftUI
import TTSKit

/// The audiobook-synthesis controls, shared by the Create page's options form
/// and the Library's Process sheet so the two can never drift.
struct AudiobookSettingsFields: View {
  let voices: [VoiceDescriptor]
  @Binding var voiceID: String
  @Binding var bitrateKbps: Int
  @Binding var workers: Int
  @Binding var announceTitles: Bool
  @Binding var paragraphPause: Double
  @Binding var chapterPause: Double
  /// Announcements cannot be synthesized for ReadAloud-bearing jobs.
  var announceTitlesLocked: Bool

  var body: some View {
    Picker("Siri voice", selection: $voiceID) {
      ForEach(voices, id: \.key) { voice in
        Text("\(voice.name) — \(voice.language)").tag(voice.key.voiceID)
      }
    }
    Picker("AAC bitrate", selection: $bitrateKbps) {
      ForEach(AudiobookConfig.allowedBitratesKbps, id: \.self) {
        Text("\($0) kbps").tag($0)
      }
    }
    .pickerStyle(.segmented)
    LabeledContent("Synthesis workers") {
      Stepper(value: $workers, in: 1...16) {
        Text(workers.formatted()).monospacedDigit()
      }
    }
    Toggle("Announce chapter titles", isOn: $announceTitles)
      .disabled(announceTitlesLocked)
    LabeledContent("Paragraph pause") {
      Stepper(value: $paragraphPause, in: 0...10, step: 0.05) {
        Text("\(paragraphPause, format: .number.precision(.fractionLength(2))) s")
          .monospacedDigit()
      }
    }
    LabeledContent("Chapter pause") {
      Stepper(value: $chapterPause, in: 0...10, step: 0.05) {
        Text("\(chapterPause, format: .number.precision(.fractionLength(2))) s")
          .monospacedDigit()
      }
    }
  }
}

/// The ReadAloud controls: Opus bitrate and the alignment-transcript source.
/// Exact synthesis timing (the default) uses the audiobook digest-bound
/// timeline sidecar and runs no speech recognition; Apple Speech and Whisper
/// (with an explicit model choice) remain selectable ASR modes.
struct ReadAloudSettingsFields: View {
  @Binding var opusBitrateKbps: Int
  @Binding var asrEngineID: String
  @Binding var asrModelID: String

  var body: some View {
    Picker("Opus bitrate", selection: $opusBitrateKbps) {
      ForEach([16, 32, 64, 96], id: \.self) { Text("\($0) kbps").tag($0) }
    }
    .pickerStyle(.segmented)
    Picker("Alignment transcript", selection: $asrEngineID) {
      Text("Exact (no ASR)").tag("synthesis")
      Text("Apple Speech").tag("apple")
      Text("Whisper").tag("whisper")
    }
    .pickerStyle(.segmented)
    if asrEngineID == "whisper" {
      Picker("Whisper model", selection: $asrModelID) {
        ForEach(ReadAloudWhisperModel.allCases, id: \.self) { model in
          Text(model.rawValue).tag(model.rawValue)
        }
      }
    }
    Text("Chapter-title announcements are disabled because words absent from the EPUB cannot align.")
      .font(.caption).foregroundStyle(.secondary)
  }
}

/// Loads the installed Siri voice inventory off the main actor, with the
/// Full Disk Access preflight the desktop app surfaces as a warning.
enum SiriVoiceInventory {
  struct Inventory: Sendable {
    let voices: [VoiceDescriptor]
    let defaultVoiceID: String
    let permissionWarning: String?
  }

  static func load(configuredVoice: String?) async throws -> Inventory {
    try await Task.detached { () -> Inventory in
      let backend = try SiriTTSBackend(defaultVoice: configuredVoice)
      let warning: String?
      do {
        try SiriPermissionPreflight.verifyModelAccess()
        warning = nil
      } catch {
        warning = "Full Disk Access is required to read Apple's Siri voice models."
      }
      return Inventory(
        voices: backend.voices, defaultVoiceID: backend.defaultVoice.voiceID,
        permissionWarning: warning)
    }.value
  }
}

import AudiobookKit
import ReadAloudKit
import SwiftUI
import TTSKit

/// The backend-neutral TTS selector shared by audiobook production and the
/// server verification panel. Public model IDs remain separate from durable
/// backend/model identity because `tts-1` is an alias for `siri-private`.
struct TTSSelectionFields: View {
  let models: [TTSModelInfo]
  let voices: [VoiceDescriptor]
  @Binding var publicModelID: String
  @Binding var backendID: String
  @Binding var modelID: String
  @Binding var voiceID: String
  @Binding var pacePreset: Int?
  @Binding var expressivityPreset: Int?
  var onModelChange: ((TTSModelInfo) -> Void)? = nil

  private var selectedModel: TTSModelInfo? {
    models.first(where: { $0.id == publicModelID })
      ?? models.first(where: { $0.backendID == backendID && $0.modelID == modelID })
      ?? models.first
  }

  private var availableVoices: [VoiceDescriptor] {
    guard let selectedModel else { return [] }
    return voices.filter {
      $0.key.backendID.rawValue == selectedModel.backendID
        && $0.key.modelID == selectedModel.modelID
    }
  }

  var body: some View {
    Picker("TTS model", selection: modelSelection) {
      ForEach(models, id: \.id) { model in
        Text(model.name).tag(model.id)
      }
    }
    Picker("Voice", selection: $voiceID) {
      ForEach(availableVoices, id: \.key) { voice in
        Text("\(voice.name) — \(voice.language)").tag(voice.key.voiceID)
      }
    }
    if let model = selectedModel {
      if model.supportsPace {
        presetSlider("Pace", value: $pacePreset)
      }
      if model.supportsExpressivity {
        presetSlider("Expressivity", value: $expressivityPreset)
      }
      if !model.supportsPace && !model.supportsExpressivity {
        Text("This model does not expose pace or expressivity presets.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private var modelSelection: Binding<String> {
    Binding(
      get: { selectedModel?.id ?? publicModelID },
      set: { selectedID in
        guard let model = models.first(where: { $0.id == selectedID }) else { return }
        publicModelID = model.id
        backendID = model.backendID
        modelID = model.modelID
        voiceID = model.defaultVoiceID
        pacePreset = model.supportsPace ? 3 : nil
        expressivityPreset = model.supportsExpressivity ? 3 : nil
        onModelChange?(model)
      })
  }

  private func presetSlider(_ title: String, value: Binding<Int?>) -> some View {
    LabeledContent(title) {
      HStack {
        Slider(
          value: Binding(
            get: { Double(value.wrappedValue ?? 3) },
            set: { value.wrappedValue = Int($0.rounded()) }),
          in: 1...5, step: 1)
          .accessibilityLabel(title)
          .accessibilityValue("\(value.wrappedValue ?? 3) of 5")
        Text("\(value.wrappedValue ?? 3) of 5")
          .monospacedDigit().frame(minWidth: 42, alignment: .trailing)
      }
    }
  }
}

/// The audiobook-synthesis controls, shared by the Create page's options form
/// and the Library's Process sheet so the two can never drift.
struct AudiobookSettingsFields: View {
  let models: [TTSModelInfo]
  let voices: [VoiceDescriptor]
  @Binding var publicModelID: String
  @Binding var backendID: String
  @Binding var modelID: String
  @Binding var voiceID: String
  @Binding var pacePreset: Int?
  @Binding var expressivityPreset: Int?
  @Binding var bitrateKbps: Int
  @Binding var workers: Int
  @Binding var announceTitles: Bool
  @Binding var paragraphPause: Double
  @Binding var chapterPause: Double
  /// Announcements cannot be synthesized for ReadAloud-bearing jobs.
  var announceTitlesLocked: Bool
  /// True when the count came from what the user last queued with, which
  /// counts as user-set: remembering it and then overwriting it on the next
  /// model change would defeat the point.
  var workersUserSet: Bool = false

  /// A recommendation is only a starting point. A hard model maximum always
  /// applies, including to a remembered or manually edited value.
  @State private var workersEdited = false

  private var selectedMaximumWorkers: Int {
    let maximum = models.first {
      $0.backendID == backendID && $0.modelID == modelID
    }?.maximumAudiobookWorkers
    return min(AudiobookConfig.maximumWorkers, maximum ?? AudiobookConfig.maximumWorkers)
  }

  var body: some View {
    TTSSelectionFields(
      models: models, voices: voices,
      publicModelID: $publicModelID, backendID: $backendID, modelID: $modelID,
      voiceID: $voiceID, pacePreset: $pacePreset,
      expressivityPreset: $expressivityPreset,
      onModelChange: { model in
        let requested =
          !workersEdited && !workersUserSet
          ? (model.recommendedAudiobookWorkers ?? workers)
          : workers
        workers = min(
          AudiobookConfig.maximumWorkers,
          min(model.maximumAudiobookWorkers ?? AudiobookConfig.maximumWorkers, requested))
      })
    Picker("AAC bitrate", selection: $bitrateKbps) {
      ForEach(AudiobookConfig.allowedBitratesKbps, id: \.self) {
        Text("\($0) kbps").tag($0)
      }
    }
    .pickerStyle(.segmented)
    LabeledContent("Synthesis workers") {
      Stepper(
        value: Binding(
          get: { workers },
          set: { newValue in
            workersEdited = true
            workers = newValue
          }), in: 1...selectedMaximumWorkers
      ) {
        Text(workers.formatted()).monospacedDigit()
      }
    }
    if selectedMaximumWorkers == 1 {
      Text("Siri Expressive production is fixed at one worker for reliable synthesis.")
        .font(.caption).foregroundStyle(.secondary)
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
      ForEach(ReadAloudDefaults.allowedOpusBitratesKbps, id: \.self) {
        Text("\($0) kbps").tag($0)
      }
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

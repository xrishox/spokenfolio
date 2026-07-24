import AppKit
import SwiftUI

/// First-run sheet asking where the book library should live. Presented only
/// while `studio-settings.json` does not exist; confirming creates the folder
/// and writes the settings file, which ends onboarding forever. There is no
/// skip — confirming with the prefilled default is the skip.
struct LibraryOnboardingSheet: View {
  @Bindable var settings: AppSettingsModel
  @Binding var isPresented: Bool

  @State private var path = "~/Books/SpokenFolio"
  @State private var errorMessage: String?
  @State private var isSaving = false

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Where should SpokenFolio keep your books?")
        .font(.title3.weight(.semibold))
      Text(
        "Every book — imported EPUBs, Storyteller downloads, TTS audiobooks, and TTS ReadAlouds — gets its own folder inside this location."
      )
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)

      HStack(spacing: 8) {
        TextField("Library folder", text: $path)
          .textFieldStyle(.roundedBorder)
          .labelsHidden()
        Button("Choose…") { choose() }
      }

      if let errorMessage {
        Label {
          Text(errorMessage).textSelection(.enabled)
        } icon: {
          Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
        .font(.callout)
      }

      HStack {
        Spacer()
        Button("Use This Folder") { confirm() }
          .keyboardShortcut(.defaultAction)
          .disabled(isSaving || path.trimmingCharacters(in: .whitespaces).isEmpty)
      }
    }
    .padding(24)
    .frame(width: 480)
  }

  /// The window already hosts this sheet, so the panel must run standalone —
  /// the same fallback the Settings folder picker uses.
  private func choose() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    let expanded = (path as NSString).expandingTildeInPath
    if (expanded as NSString).isAbsolutePath {
      panel.directoryURL = URL(fileURLWithPath: expanded, isDirectory: true)
    }
    panel.begin { response in
      guard response == .OK, let url = panel.url else { return }
      Task { @MainActor in path = url.standardizedFileURL.path }
    }
  }

  private func confirm() {
    guard !isSaving else { return }
    isSaving = true
    errorMessage = nil
    let chosen = path
    Task { @MainActor in
      defer { isSaving = false }
      if let failure = await settings.completeOnboarding(path: chosen) {
        errorMessage = failure
      } else {
        isPresented = false
      }
    }
  }
}

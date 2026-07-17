import Foundation
import Observation

enum AppSection: String, CaseIterable, Identifiable {
  case production
  case library
  case quality
  case server
  case settings

  var id: Self { self }

  static let menuSections = allCases

  var title: String {
    switch self {
    case .production: "Production"
    case .library: "Library"
    case .quality: "ReadAloud Quality"
    case .server: "TTS Server"
    case .settings: "Settings"
    }
  }

  var icon: String {
    switch self {
    case .production: "waveform.badge.plus"
    case .library: "books.vertical"
    case .quality: "checkmark.shield"
    case .server: "network"
    case .settings: "gearshape"
    }
  }

  fileprivate static func restored(from value: String?) -> Self {
    guard let value else { return .production }
    if let current = Self(rawValue: value) { return current }
    switch value {
    case "Create", "Activity": return .production
    case "Library": return .library
    case "ReadAloud Quality": return .quality
    case "TTS Server": return .server
    case "Storyteller", "ReadAloud Tools", "Settings": return .settings
    default: return .production
    }
  }
}

@MainActor @Observable
final class AppNavigationModel {
  private static let key = "SpokenFolioLastSection"
  var selection: AppSection
  var productionMode: ProductionWorkspaceMode
  let initiallyShowsProductionQueue: Bool

  init(defaults: UserDefaults = .standard) {
    let stored = defaults.string(forKey: Self.key)
    selection = AppSection.restored(from: stored)
    initiallyShowsProductionQueue = stored == "Activity"
    productionMode = stored == "Activity" ? .queue : .create
    if stored == "Storyteller" {
      defaults.set(SettingsScope.storyteller.rawValue, forKey: SettingsScope.persistenceKey)
    } else if stored == "ReadAloud Tools" {
      defaults.set(SettingsScope.readAloud.rawValue, forKey: SettingsScope.persistenceKey)
    }
    defaults.set(selection.rawValue, forKey: Self.key)
  }

  func select(_ section: AppSection, defaults: UserDefaults = .standard) {
    selection = section
    defaults.set(section.rawValue, forKey: Self.key)
  }
}

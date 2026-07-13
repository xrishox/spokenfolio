import Foundation
import Observation

enum AppSection: String, CaseIterable, Identifiable {
  case create = "Create"
  case library = "Library"
  case activity = "Activity"
  case storyteller = "Storyteller"
  case server = "TTS Server"
  case tools = "ReadAloud Tools"
  case settings = "Settings"

  var id: Self { self }

  static let menuSections: [Self] = [.create, .library, .activity, .storyteller, .server, .tools]

  var icon: String {
    switch self {
    case .create: "waveform.badge.plus"
    case .library: "books.vertical"
    case .activity: "list.bullet.rectangle"
    case .storyteller: "rectangle.connected.to.line.below"
    case .server: "network"
    case .tools: "wrench.and.screwdriver"
    case .settings: "gearshape"
    }
  }
}

@MainActor @Observable
final class AppNavigationModel {
  private static let key = "SpokenFolioLastSection"
  var selection: AppSection

  init(defaults: UserDefaults = .standard) {
    selection = defaults.string(forKey: Self.key).flatMap(AppSection.init(rawValue:)) ?? .create
  }

  func select(_ section: AppSection, defaults: UserDefaults = .standard) {
    selection = section
    defaults.set(section.rawValue, forKey: Self.key)
  }
}

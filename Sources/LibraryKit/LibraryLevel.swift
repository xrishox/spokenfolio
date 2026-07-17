import Foundation

package enum LibraryLevel: Int, Codable, Sendable, CaseIterable, Comparable {
  case unavailable = 0
  case readable = 1
  case mirroredText = 2
  case listenable = 3
  case readAloudIncomplete = 4
  case localComplete = 5
  case remoteCompleteUnknown = 6
  case remoteCompleteTTS = 7
  case remoteCompleteHuman = 8
  case humanWithLocalAudioFallback = 9
  case fullyResilient = 10

  package static func < (left: Self, right: Self) -> Bool {
    left.rawValue < right.rawValue
  }

  package var label: String {
    switch self {
    case .unavailable: "Unavailable"
    case .readable: "Readable"
    case .mirroredText: "Mirrored text"
    case .listenable: "Listenable"
    case .readAloudIncomplete: "ReadAloud incomplete"
    case .localComplete: "Local complete"
    case .remoteCompleteUnknown: "Storyteller complete — unknown narration"
    case .remoteCompleteTTS: "Storyteller complete — TTS"
    case .remoteCompleteHuman: "Storyteller complete — human"
    case .humanWithLocalAudioFallback: "Human with local audio fallback"
    case .fullyResilient: "Fully resilient"
    }
  }
}

package struct LibraryPackageState: Sendable, Equatable {
  package var localEPUBReady: Bool
  package var localAudiobookReady: Bool
  package var localReadAloudReady: Bool
  package var localCoherence: PackageCoherence
  package var remoteEPUBReady: Bool
  package var remoteAudiobookReady: Bool
  package var remoteReadAloudReady: Bool
  package var remoteCoherence: PackageCoherence
  package var remoteNarration: NarrationProvenance

  package init(
    localEPUBReady: Bool = false, localAudiobookReady: Bool = false,
    localReadAloudReady: Bool = false, localCoherence: PackageCoherence = .unknown,
    remoteEPUBReady: Bool = false, remoteAudiobookReady: Bool = false,
    remoteReadAloudReady: Bool = false, remoteCoherence: PackageCoherence = .unknown,
    remoteNarration: NarrationProvenance = .unknown
  ) {
    self.localEPUBReady = localEPUBReady
    self.localAudiobookReady = localAudiobookReady
    self.localReadAloudReady = localReadAloudReady
    self.localCoherence = localCoherence
    self.remoteEPUBReady = remoteEPUBReady
    self.remoteAudiobookReady = remoteAudiobookReady
    self.remoteReadAloudReady = remoteReadAloudReady
    self.remoteCoherence = remoteCoherence
    self.remoteNarration = remoteNarration
  }

  package var localComplete: Bool {
    localEPUBReady && localAudiobookReady && localReadAloudReady
      && localCoherence == .verified
  }

  package var remoteComplete: Bool {
    remoteEPUBReady && remoteAudiobookReady && remoteReadAloudReady
      && remoteCoherence == .verified
  }

  package var level: LibraryLevel {
    // A known incoherent package is worse than an incomplete one regardless
    // of how many component files happen to exist.
    if localCoherence == .conflict || remoteCoherence == .conflict {
      return .unavailable
    }
    if remoteComplete {
      switch remoteNarration {
      case .human:
        if localComplete { return .fullyResilient }
        if localEPUBReady && localAudiobookReady {
          return .humanWithLocalAudioFallback
        }
        return .remoteCompleteHuman
      case .spokenFolioTTS, .otherTTS:
        return .remoteCompleteTTS
      case .unknown:
        return .remoteCompleteUnknown
      }
    }
    if localComplete { return .localComplete }
    let hasReadAloud = localReadAloudReady || remoteReadAloudReady
    let allComponentsExist =
      (localEPUBReady || remoteEPUBReady)
      && (localAudiobookReady || remoteAudiobookReady)
      && hasReadAloud
    if hasReadAloud || allComponentsExist { return .readAloudIncomplete }
    if localAudiobookReady || remoteAudiobookReady { return .listenable }
    if localEPUBReady && remoteEPUBReady { return .mirroredText }
    if localEPUBReady || remoteEPUBReady { return .readable }
    return .unavailable
  }
}

import Foundation

/// One installed Siri neural/natural voice that is safe to expose through the
/// server's fixed 48 kHz mono PCM contract.
package struct SiriVoiceAsset: Hashable, Sendable {
  package let id: String
  package let name: String
  package let displayName: String
  package let language: String
  package let technology: String
  package let footprint: String
  package let version: Int
  package let voicePath: String
  package let resourcePath: String
  package let styles: Set<String>
  package let sourcePriority: Int

  package var supportsNarration: Bool { styles.contains("narration") }

  package var voiceInfo: VoiceInfo {
    VoiceInfo(
      id: id,
      name: displayName,
      lang: language,
      quality: footprint.hasPrefix("premium") ? "premium" : "enhanced"
    )
  }
}

package enum SiriVoiceCatalog {
  package static let requiredSampleRate = 48_000

  /// UAF is the source of the currently installed Siri voices. Trial may
  /// contain the same selected voice, so entries are deduplicated below.
  package static func defaultSearchDirectories(
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> [URL] {
    let assetStoreRoots = [
      URL(fileURLWithPath: "/System/Library/AssetsV2", isDirectory: true),
      URL(fileURLWithPath: "/Library/AssetsV2", isDirectory: true),
      homeDirectory.appendingPathComponent("Library/AssetsV2", isDirectory: true),
    ]
    let assetTypes = [
      "com_apple_MobileAsset_UAF_Siri_TextToSpeech/purpose_auto",
      "com_apple_MobileAsset_Trial_Siri_SiriTextToSpeech/purpose_auto",
      "com_apple_MobileAsset_VoiceServices_GryphonVoice/purpose_auto",
      "com_apple_MobileAsset_VoiceServices_GryphonVoice",
    ]
    var directories = assetStoreRoots.flatMap { root in
      assetTypes.map { root.appendingPathComponent($0, isDirectory: true) }
    }
    directories.append(
      homeDirectory.appendingPathComponent(
        "Library/Application Support/SiriTTS/Voices", isDirectory: true))
    return directories
  }

  package static func discover(
    searchDirectories: [URL] = defaultSearchDirectories(),
    fileManager: FileManager = .default
  ) -> [SiriVoiceAsset] {
    var deduplicated: [String: SiriVoiceAsset] = [:]

    for (sourcePriority, directory) in searchDirectories.enumerated() {
      let entries =
        (try? fileManager.contentsOfDirectory(
          at: directory,
          includingPropertiesForKeys: [.isDirectoryKey],
          options: [.skipsHiddenFiles]
        )) ?? []

      var candidates = candidateDirectories(
        at: directory, metadataURL: nil, fileManager: fileManager)
      for entry in entries.sorted(by: { $0.path < $1.path }) {
        candidates.append(
          contentsOf: candidateDirectories(
            at: entry, metadataURL: nil, fileManager: fileManager))
      }

      for candidate in candidates {
        guard
          let asset = parseVoice(
            candidate,
            sourcePriority: sourcePriority,
            fileManager: fileManager)
        else { continue }

        // UAF and Trial can publish the same model with different outer
        // suffixes. Prefer system UAF, then the newest version.
        let semanticKey = [
          asset.language, asset.name, asset.technology, asset.footprint,
        ].joined(separator: "|")
        if let existing = deduplicated[semanticKey] {
          if (asset.sourcePriority, -asset.version)
            < (existing.sourcePriority, -existing.version)
          {
            deduplicated[semanticKey] = asset
          }
        } else {
          deduplicated[semanticKey] = asset
        }
      }
    }

    return deduplicated.values.sorted {
      ($0.language, $0.name, preferenceRank($0), -$0.version, $0.id)
        < ($1.language, $1.name, preferenceRank($1), -$1.version, $1.id)
    }
  }

  /// Best model for an ambiguous short name: natural, then neural, then the
  /// newest version within a technology tier.
  package static func preferred(_ assets: [SiriVoiceAsset]) -> SiriVoiceAsset? {
    assets.min {
      (preferenceRank($0), -$0.version, $0.sourcePriority, $0.id)
        < (preferenceRank($1), -$1.version, $1.sourcePriority, $1.id)
    }
  }

  /// Aliases resolve only when they identify exactly one installed variant;
  /// canonical asset IDs always resolve. Ambiguous short names are absent so
  /// the caller can reject them instead of guessing a Siri variant.
  package static func makeVoiceLookup(_ assets: [SiriVoiceAsset]) -> [String: String] {
    var lookup: [String: String] = [:]
    var shortNames: [String: [SiriVoiceAsset]] = [:]
    var displayNames: [String: [SiriVoiceAsset]] = [:]
    var languageNames: [String: [SiriVoiceAsset]] = [:]
    for asset in assets {
      lookup[asset.id.lowercased()] = asset.id
      shortNames[asset.name.lowercased(), default: []].append(asset)
      displayNames[asset.displayName.lowercased(), default: []].append(asset)
      languageNames["\(asset.language):\(asset.name)".lowercased(), default: []].append(asset)
    }
    for (name, matches) in shortNames where matches.count == 1 { lookup[name] = matches[0].id }
    for (name, matches) in displayNames where matches.count == 1 {
      lookup[name] = matches[0].id
    }
    for (name, matches) in languageNames where matches.count == 1 {
      lookup[name] = matches[0].id
    }
    return lookup
  }

  private struct Candidate {
    let voiceDirectory: URL
    let resourceDirectory: URL
    let metadataURL: URL
  }

  /// Supports UAF `.asset/AssetData`, a direct AssetData directory, and the
  /// legacy SiriTTS download layout (`Info.plist` beside `AssetData/`).
  private static func candidateDirectories(
    at directory: URL,
    metadataURL: URL?,
    fileManager: FileManager
  ) -> [Candidate] {
    var isDirectory: ObjCBool = false
    guard
      fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { return [] }

    let infoURL = directory.appendingPathComponent("Info.plist")
    let assetData = directory.appendingPathComponent("AssetData", isDirectory: true)
    let assetDataInfo = assetData.appendingPathComponent("Info.plist")
    let directConfig = directory.appendingPathComponent("gryphon.cfg")
    let nestedConfig = assetData.appendingPathComponent("gryphon.cfg")

    if fileManager.fileExists(atPath: assetDataInfo.path),
      fileManager.fileExists(atPath: nestedConfig.path)
    {
      // UAF outer metadata provides the stable AssetSpecifier. The
      // private engine itself must receive the inner AssetData path.
      return [
        Candidate(
          voiceDirectory: assetData,
          resourceDirectory: assetData,
          metadataURL: fileManager.fileExists(atPath: infoURL.path)
            ? infoURL : assetDataInfo)
      ]
    }
    if fileManager.fileExists(atPath: infoURL.path),
      fileManager.fileExists(atPath: nestedConfig.path)
    {
      // Legacy extracted voice: voice root + nested resource directory.
      return [
        Candidate(
          voiceDirectory: directory,
          resourceDirectory: assetData,
          metadataURL: metadataURL ?? infoURL)
      ]
    }
    if fileManager.fileExists(atPath: infoURL.path),
      fileManager.fileExists(atPath: directConfig.path)
    {
      return [
        Candidate(
          voiceDirectory: directory,
          resourceDirectory: directory,
          metadataURL: metadataURL ?? infoURL)
      ]
    }
    return []
  }

  private static func parseVoice(
    _ candidate: Candidate,
    sourcePriority: Int,
    fileManager: FileManager
  ) -> SiriVoiceAsset? {
    var isDirectory: ObjCBool = false
    guard
      fileManager.fileExists(
        atPath: candidate.voiceDirectory.path, isDirectory: &isDirectory),
      isDirectory.boolValue,
      let infoData = try? Data(
        contentsOf: candidate.voiceDirectory.appendingPathComponent("Info.plist")),
      let info = try? PropertyListSerialization.propertyList(
        from: infoData, format: nil) as? [String: Any],
      let properties = info["MobileAssetProperties"] as? [String: Any],
      let technology = (properties["Type"] as? String)?.lowercased(),
      technology == "natural" || technology == "neural" || technology == "gryphon",
      let rawName = properties["Name"] as? String,
      let footprint = (properties["Footprint"] as? String)?.lowercased(),
      let language = language(in: properties),
      let canonicalID = canonicalID(
        metadataURL: candidate.metadataURL,
        engineInfo: info),
      hasOnly48KOutput(in: candidate.resourceDirectory)
    else { return nil }

    let name = rawName.lowercased()
    let version =
      integer(properties["_ContentVersion"])
      ?? bundleVersion(in: info)
      ?? 0
    let normalizedLanguage = language.replacingOccurrences(of: "_", with: "-")
    let displayName = "\(rawName.capitalized) (\(technology.capitalized))"
    let styles = Set(
      (properties["Styles"] as? [String] ?? []).map { $0.lowercased() })

    return SiriVoiceAsset(
      id: canonicalID,
      name: name,
      displayName: displayName,
      language: normalizedLanguage,
      technology: technology,
      footprint: footprint,
      version: version,
      voicePath: candidate.voiceDirectory.path,
      resourcePath: candidate.resourceDirectory.path,
      styles: styles,
      sourcePriority: sourcePriority
    )
  }

  private static func canonicalID(
    metadataURL: URL,
    engineInfo: [String: Any]
  ) -> String? {
    if let data = try? Data(contentsOf: metadataURL),
      let metadata = try? PropertyListSerialization.propertyList(
        from: data, format: nil) as? [String: Any],
      let properties = metadata["MobileAssetProperties"] as? [String: Any]
    {
      if let specifier = properties["AssetSpecifier"] as? String {
        return specifier
      }
      if let factor = properties["Factor"] as? String {
        return factor
      }
    }

    // Legacy direct downloads predate AssetSpecifier. Preserve their own
    // bundle identity rather than inventing a versioned Siri identifier.
    if let identifier = engineInfo["CFBundleIdentifier"] as? String,
      let name = engineInfo["CFBundleName"] as? String
    {
      return "\(identifier).\(name)"
    }
    return nil
  }

  /// The private engine reports its format only after loading a several-
  /// hundred-megabyte model. Inspecting the graph first prevents exposing a
  /// voice that cannot satisfy TTSService's single 48 kHz sample rate. The
  /// runtime bridge validates the ASBD again after the voice is loaded.
  private static func hasOnly48KOutput(in engineDirectory: URL) -> Bool {
    let configURL = engineDirectory.appendingPathComponent("gryphon.cfg")
    guard
      let data = try? Data(contentsOf: configURL),
      let json = try? JSONSerialization.jsonObject(with: data)
    else { return false }

    var rates: [Int] = []
    collectSampleRates(from: json, into: &rates)
    return !rates.isEmpty && rates.allSatisfy { $0 == requiredSampleRate }
  }

  private static func collectSampleRates(from value: Any, into rates: inout [Int]) {
    if let dictionary = value as? [String: Any] {
      for (key, child) in dictionary {
        if key == "sample_rate_out", let rate = integer(child) {
          rates.append(rate)
        } else {
          collectSampleRates(from: child, into: &rates)
        }
      }
    } else if let array = value as? [Any] {
      for child in array {
        collectSampleRates(from: child, into: &rates)
      }
    }
  }

  private static func language(in properties: [String: Any]) -> String? {
    if let languages = properties["LanguagesCompatibility"] as? [String],
      let language = languages.first
    {
      return language
    }
    if let languages = properties["Languages"] as? [String], let language = languages.first {
      return language
    }
    return nil
  }

  private static func integer(_ value: Any?) -> Int? {
    if let value = value as? Int { return value }
    if let value = value as? NSNumber { return value.intValue }
    if let value = value as? String { return Int(value) }
    return nil
  }

  private static func bundleVersion(in info: [String: Any]) -> Int? {
    for key in ["CFBundleVersion", "CFBundleShortVersionString"] {
      if let raw = info[key] as? String,
        let firstComponent = raw.split(separator: ".").first,
        let value = Int(firstComponent)
      {
        return value
      }
    }
    return nil
  }

  private static func preferenceRank(_ asset: SiriVoiceAsset) -> Int {
    switch asset.technology {
    case "natural": 0
    case "neural": 1
    default: 2
    }
  }
}

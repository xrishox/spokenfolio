import Darwin
import Foundation

/// Stable, non-sensitive identity for the Apple runtime that supplies Siri
/// synthesis. This is persisted with audiobook products and also participates
/// in resume identity so artifacts are not reused across engine updates.
package struct SiriTTSRuntimeIdentity: Codable, Hashable, Sendable {
  package static let frameworkPath =
    "/System/Library/PrivateFrameworks/SiriTTSService.framework"

  package let macOSVersion: String
  package let macOSBuild: String
  package let frameworkIdentifier: String
  package let frameworkVersion: String
  package let frameworkSDKVersion: String?
  package let frameworkSDKBuild: String?

  package init(
    macOSVersion: String, macOSBuild: String, frameworkIdentifier: String,
    frameworkVersion: String, frameworkSDKVersion: String? = nil,
    frameworkSDKBuild: String? = nil
  ) {
    self.macOSVersion = macOSVersion
    self.macOSBuild = macOSBuild
    self.frameworkIdentifier = frameworkIdentifier
    self.frameworkVersion = frameworkVersion
    self.frameworkSDKVersion = frameworkSDKVersion
    self.frameworkSDKBuild = frameworkSDKBuild
  }

  package static func current() -> Self {
    let version = ProcessInfo.processInfo.operatingSystemVersion
    let info = Bundle(path: frameworkPath)?.infoDictionary ?? [:]
    return Self(
      macOSVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
      macOSBuild: systemBuild(),
      frameworkIdentifier: info["CFBundleIdentifier"] as? String
        ?? "com.apple.siri.SiriTTSService",
      frameworkVersion: info["CFBundleVersion"] as? String ?? "unknown",
      frameworkSDKVersion: info["DTPlatformVersion"] as? String,
      frameworkSDKBuild: info["DTSDKBuild"] as? String)
  }

  /// Compact value used as the backend model revision and therefore included
  /// in AudiobookKit's content fingerprint.
  package var modelRevision: String {
    "SiriTTSService:\(frameworkVersion);macOS:\(macOSVersion)(\(macOSBuild))"
  }

  private static func systemBuild() -> String {
    var size = 0
    guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 1 else {
      return "unknown"
    }
    var bytes = [CChar](repeating: 0, count: size)
    guard sysctlbyname("kern.osversion", &bytes, &size, nil, 0) == 0 else {
      return "unknown"
    }
    if bytes.last == 0 { bytes.removeLast() }
    return String(decoding: bytes.map(UInt8.init(bitPattern:)), as: UTF8.self)
  }
}

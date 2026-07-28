import Darwin
import Foundation

package struct GoldenGateRuntimeIdentity: Codable, Hashable, Sendable {
  package static let current = GoldenGateRuntimeIdentity()

  package let macOSVersion: String
  package let macOSBuild: String
  package let frameworkIdentifier: String
  package let frameworkVersion: String

  package var revision: String {
    "macOS-\(macOSVersion)-\(macOSBuild)|\(frameworkIdentifier)-\(frameworkVersion)"
  }

  package init() {
    let version = ProcessInfo.processInfo.operatingSystemVersion
    macOSVersion = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    macOSBuild = Self.sysctlString("kern.osversion") ?? "unknown"
    let bundle = Bundle(
      path: "/System/Library/PrivateFrameworks/SiriTTSService.framework")
    frameworkIdentifier = bundle?.bundleIdentifier ?? "com.apple.siri.SiriTTSService"
    frameworkVersion =
      bundle?.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
  }

  private static func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else { return nil }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
    return String(cString: buffer)
  }
}

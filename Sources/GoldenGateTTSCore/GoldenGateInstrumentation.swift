import Foundation
import TTSKit

package struct GoldenGateInstrumentation: Codable, Hashable, Sendable {
  package static let expectedAdapterIdentifier = "com.apple.fm.language.instruct_3b.voice"
  package let voiceID: String
  package let voiceType: Int
  package let resourceIdentity: String
  package let resourceRevision: String
  package let errorCode: Int
  package let pacePreset: Int
  package let expressivityPreset: Int
  package let adapterID: String
  package let audioDuration: Double

  package init(
    voiceID: String, voiceType: Int = 7,
    resourceIdentity: String, resourceRevision: String,
    errorCode: Int, pacePreset: Int, expressivityPreset: Int,
    adapterID: String, audioDuration: Double
  ) {
    self.voiceID = voiceID
    self.voiceType = voiceType
    self.resourceIdentity = resourceIdentity
    self.resourceRevision = resourceRevision
    self.errorCode = errorCode
    self.pacePreset = pacePreset
    self.expressivityPreset = expressivityPreset
    self.adapterID = adapterID
    self.audioDuration = audioDuration
  }

  package func validate(
    voiceID: String, pace: Int, expressivity: Int, allowsCachedAdapter: Bool = false
  ) throws {
    guard errorCode == 0 else {
      throw GoldenGateTTSError.invalidInstrumentation("error code \(errorCode)")
    }
    guard self.voiceID == voiceID, voiceType == 7 else {
      throw GoldenGateTTSError.invalidInstrumentation(
        "voice \(self.voiceID) type \(voiceType) did not match FM voice \(voiceID)")
    }
    guard pacePreset == pace, expressivityPreset == expressivity else {
      throw GoldenGateTTSError.invalidInstrumentation(
        "reported presets \(pacePreset)/\(expressivityPreset) did not match \(pace)/\(expressivity)")
    }
    guard adapterID == Self.expectedAdapterIdentifier
      || (allowsCachedAdapter && adapterID.isEmpty)
    else {
      throw GoldenGateTTSError.invalidInstrumentation(
        "unexpected adapter \(adapterID)")
    }
    guard !resourceIdentity.isEmpty, !resourceRevision.isEmpty,
      audioDuration.isFinite, audioDuration > 0
    else {
      throw GoldenGateTTSError.invalidInstrumentation("resource or duration was missing")
    }
  }

  package func provenance(
    runtime: GoldenGateRuntimeIdentity, voiceRevision: String?
  ) throws -> TTSRuntimeProvenance {
    try TTSRuntimeProvenance(
      backendID: GoldenGateTTSBackend.backendID,
      modelID: GoldenGateTTSBackend.modelID,
      voiceID: voiceID,
      operatingSystemVersion: runtime.macOSVersion,
      operatingSystemBuild: runtime.macOSBuild,
      frameworkIdentifier: runtime.frameworkIdentifier,
      frameworkVersion: runtime.frameworkVersion,
      adapterIdentifier: adapterID.isEmpty ? Self.expectedAdapterIdentifier : adapterID,
      backendAdapterRevision: runtime.revision,
      modelRevision: runtime.revision,
      voiceRevision: voiceRevision,
      resourceIdentity: resourceIdentity,
      resourceRevision: resourceRevision)
  }
}

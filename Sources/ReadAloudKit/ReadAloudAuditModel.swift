import Foundation

package enum ReadAloudAuditMode: String, Codable, Sendable, CaseIterable {
  case standard, thorough
}

package enum ReadAloudAuditVerdict: String, Codable, Sendable, CaseIterable {
  case likelyCorrect, needsReview, likelyBroken, broken, inconclusive
}

package enum ReadAloudAuditLifecycle: String, Codable, Sendable {
  case queued, running, completed, cancelled, failed
}

package enum ReadAloudAuditDimension: String, Codable, Sendable, CaseIterable {
  case structure, coverage, identity, timing, compatibility
}

package enum ReadAloudAuditConfidence: String, Codable, Sendable {
  case confirmed, strong, tentative
}

package enum ReadAloudEvidenceAdequacy: String, Codable, Sendable {
  case complete, sampled, advisory, insufficient
}

package enum ReadAloudFindingCode: String, Codable, Sendable, CaseIterable {
  case noFunctionalOverlay
  case missingManifestReference
  case missingTextFragment
  case missingAudio
  case orphanMedia
  case emptyOverlay
  case invalidClipClock
  case invertedClipInterval
  case overlappingClip
  case clipOutsideMedia
  case unsupportedAudio
  case formatPortability
  case safetyLimitExceeded
  case missingPrimaryNarration
  case possibleWorkTranslationOrLanguageMismatch
  case possibleAbridgedOrIncompatibleEdition
  case sourcePublicationMismatch
  case broadlyDisplacedTiming
  case localizedTimingDefect
  case ancillaryContentOmitted
  case unboundTranscriptEvidence
  case insufficientSemanticEvidence
}

package struct ReadAloudAuditFinding: Codable, Sendable, Equatable, Identifiable {
  package var id: UUID
  package var dimension: ReadAloudAuditDimension
  package var code: ReadAloudFindingCode
  package var verdict: ReadAloudAuditVerdict
  package var confidence: ReadAloudAuditConfidence
  package var summary: String
  package var documentPath: String?
  package var fragmentID: String?
  package var audioPath: String?
  package var clipBegin: Double?
  package var clipEnd: Double?
  package var metrics: [String: Double]
  package var referenceExcerpt: String?
  package var transcriptExcerpt: String?

  package init(
    id: UUID = UUID(), dimension: ReadAloudAuditDimension,
    code: ReadAloudFindingCode, verdict: ReadAloudAuditVerdict,
    confidence: ReadAloudAuditConfidence, summary: String,
    documentPath: String? = nil, fragmentID: String? = nil,
    audioPath: String? = nil, clipBegin: Double? = nil, clipEnd: Double? = nil,
    metrics: [String: Double] = [:], referenceExcerpt: String? = nil,
    transcriptExcerpt: String? = nil
  ) {
    self.id = id
    self.dimension = dimension
    self.code = code
    self.verdict = verdict
    self.confidence = confidence
    self.summary = summary
    self.documentPath = documentPath
    self.fragmentID = fragmentID
    self.audioPath = audioPath
    self.clipBegin = clipBegin
    self.clipEnd = clipEnd
    self.metrics = metrics
    self.referenceExcerpt = referenceExcerpt.map(Self.boundedExcerpt)
    self.transcriptExcerpt = transcriptExcerpt.map(Self.boundedExcerpt)
  }

  private static func boundedExcerpt(_ value: String) -> String {
    let normalized = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return normalized.count <= 240 ? normalized : String(normalized.prefix(239)) + "…"
  }
}

package struct ReadAloudAuditMetrics: Codable, Sendable, Equatable {
  package var entryCount = 0
  package var spineCount = 0
  package var smilCount = 0
  package var audioCount = 0
  package var clipCount = 0
  package var primaryTokenCount = 0
  package var coveredPrimaryTokenCount = 0
  package var primaryCoverage: Double?
  package var largestPrimaryOmissionTokens = 0
  // Optional so quality history persisted by earlier policy versions decodes.
  package var largestPrimaryOmissionRunTokens: Int?
  package var transcriptToTextCoverage: Double?
  package var textToTranscriptCoverage: Double?
  package var clipWeightedSimilarity: Double?
  package var lowClipFraction: Double?
  package var longestLowClipRun = 0
  package var freshASRWeightedSimilarity: Double?
  package var freshASRSampleCount = 0
  package var freshASRSevereSampleCount = 0
}

package struct ReadAloudAuditReport: Codable, Sendable, Equatable, Identifiable {
  package static let schemaVersion = 1
  package var id: UUID
  package var schemaVersion = Self.schemaVersion
  package var policyVersion: Int
  package var mode: ReadAloudAuditMode
  package var verdict: ReadAloudAuditVerdict
  package var evidenceAdequacy: ReadAloudEvidenceAdequacy
  package var artifactSHA256: String
  package var referenceSHA256: String?
  package var analyzerIdentity: String
  package var modelIdentity: String?
  package var toolIdentity: String?
  package var startedAt: Date
  package var completedAt: Date
  package var metrics: ReadAloudAuditMetrics
  package var findings: [ReadAloudAuditFinding]

  package init(
    id: UUID = UUID(), policyVersion: Int = 1, mode: ReadAloudAuditMode,
    verdict: ReadAloudAuditVerdict, evidenceAdequacy: ReadAloudEvidenceAdequacy,
    artifactSHA256: String, referenceSHA256: String? = nil,
    analyzerIdentity: String = "readaloud-quality-v1", modelIdentity: String? = nil,
    toolIdentity: String? = nil, startedAt: Date, completedAt: Date = Date(),
    metrics: ReadAloudAuditMetrics, findings: [ReadAloudAuditFinding]
  ) {
    self.id = id
    self.policyVersion = policyVersion
    self.mode = mode
    self.verdict = verdict
    self.evidenceAdequacy = evidenceAdequacy
    self.artifactSHA256 = artifactSHA256
    self.referenceSHA256 = referenceSHA256
    self.analyzerIdentity = analyzerIdentity
    self.modelIdentity = modelIdentity
    self.toolIdentity = toolIdentity
    self.startedAt = startedAt
    self.completedAt = completedAt
    self.metrics = metrics
    let severity: [ReadAloudAuditVerdict: Int] = [
      .broken: 5, .likelyBroken: 4, .inconclusive: 3,
      .needsReview: 2, .likelyCorrect: 1,
    ]
    self.findings = Array(
      findings.enumerated().sorted {
        let left = severity[$0.element.verdict] ?? 0
        let right = severity[$1.element.verdict] ?? 0
        return left == right ? $0.offset < $1.offset : left > right
      }.prefix(50).map(\.element))
  }
}

package struct ReadAloudAuditProgress: Sendable, Equatable {
  package var fraction: Double
  package var message: String

  package init(fraction: Double, message: String) {
    self.fraction = min(1, max(0, fraction))
    self.message = message
  }
}

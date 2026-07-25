import Foundation
import PublicationKit

package enum LibraryProductKind: String, Codable, Sendable, CaseIterable {
  case sourceEPUB
  case m4b
  case readAloudEPUB
  /// Human-narrated files downloaded from Storyteller (never produced locally).
  case humanAudiobook
  case humanReadAloudEPUB
}

package enum LibraryArtifactState: String, Codable, Sendable {
  case ready
  case missing
  case suspect
}

package enum LibraryRemoteFormat: String, Codable, Sendable, CaseIterable {
  case ebook
  case audiobook
  case readaloud
}

package enum LibraryRemoteAssetState: String, Codable, Sendable {
  case ready
  case processing
  case missing
  case broken
  case unknown
}

package enum LibraryRemoteReadAloudAutoAuditStatus: String, Codable, Sendable {
  case starting
  case waiting
  case completed
  case failed
}

/// Durable intent to audit a Storyteller ReadAloud as soon as remote processing
/// publishes the asset. This is separate from an audit run because Storyteller
/// does not assign a ReadAloud asset identity until processing is underway.
package struct LibraryRemoteReadAloudAutoAudit: Codable, Sendable, Equatable, Identifiable {
  package var id: UUID
  package var connectionID: UUID
  package var bookID: UUID
  package var status: LibraryRemoteReadAloudAutoAuditStatus
  package var startedAt: Date
  package var updatedAt: Date
  package var error: String?

  package init(
    id: UUID = UUID(), connectionID: UUID, bookID: UUID,
    status: LibraryRemoteReadAloudAutoAuditStatus = .starting,
    startedAt: Date = Date(), updatedAt: Date = Date(), error: String? = nil
  ) {
    self.id = id
    self.connectionID = connectionID
    self.bookID = bookID
    self.status = status
    self.startedAt = startedAt
    self.updatedAt = updatedAt
    self.error = error
  }
}

package enum NarrationProvenance: String, Codable, Sendable, CaseIterable {
  case unknown
  case spokenFolioTTS
  case otherTTS
  case human
}

package enum PackageCoherence: String, Codable, Sendable, CaseIterable {
  case unknown
  case verified
  case conflict
}

package enum LibraryLinkState: String, Codable, Sendable {
  case pendingCreation
  case active
  case remoteMissing
  case unlinked
}

package enum LibraryLinkEvidence: String, Codable, Sendable {
  case userConfirmed
  case exactAssetHash
  case validatedIdentifier
  case uploadCreated
  case legacyJob
}

package enum LibraryIdentifierScope: String, Codable, Sendable, CaseIterable {
  case work
  case edition
  case ebook
  case audiobook
  case readaloud
}

package enum LibraryIdentifierDisposition: String, Codable, Sendable {
  case asserted
  case suppressed
}

package struct LibraryCatalogMetadata: Codable, Sendable, Equatable {
  package var title: String
  package var author: String?
  package var language: String?
  package var publisher: String?
  package var publicationDate: String?
  package var identifiers: [PublicationIdentifier]

  package init(
    title: String, author: String?, language: String? = nil, publisher: String? = nil,
    publicationDate: String? = nil, identifiers: [PublicationIdentifier] = []
  ) {
    self.title = title
    self.author = author
    self.language = language
    self.publisher = publisher
    self.publicationDate = publicationDate
    self.identifiers = identifiers
  }
}

package struct LibrarySourceArtifact: Codable, Sendable, Equatable {
  package var id: UUID
  package var format: String
  package var path: String
  package var importerVersion: Int
  package var sha256: String
  package var size: UInt64
  package var verifiedAt: Date
  package var state: LibraryArtifactState

  package init(
    id: UUID = UUID(), format: String, path: String, importerVersion: Int,
    sha256: String, size: UInt64, verifiedAt: Date = Date(),
    state: LibraryArtifactState = .ready
  ) {
    self.id = id
    self.format = format
    self.path = path
    self.importerVersion = importerVersion
    self.sha256 = sha256
    self.size = size
    self.verifiedAt = verifiedAt
    self.state = state
  }
}

package struct LibraryLocalProduct: Codable, Sendable, Equatable {
  package var id: UUID
  package var kind: LibraryProductKind
  package var path: String
  package var size: UInt64
  package var sha256: String
  package var verifiedAt: Date
  package var state: LibraryArtifactState
  package var producerJobID: UUID?
  package var narrationData: Data?
  package var readAloudData: Data?

  package init(
    id: UUID = UUID(), kind: LibraryProductKind, path: String, size: UInt64,
    sha256: String, verifiedAt: Date, state: LibraryArtifactState = .ready,
    producerJobID: UUID? = nil, narrationData: Data? = nil, readAloudData: Data? = nil
  ) {
    self.id = id
    self.kind = kind
    self.path = path
    self.size = size
    self.sha256 = sha256
    self.verifiedAt = verifiedAt
    self.state = state
    self.producerJobID = producerJobID
    self.narrationData = narrationData
    self.readAloudData = readAloudData
  }
}

package struct LibraryProductDependency: Codable, Sendable, Equatable {
  package enum Role: String, Codable, Sendable { case source, alignmentAudio }
  package var productID: UUID
  package var role: Role
  package var inputSHA256: String

  package init(productID: UUID, role: Role, inputSHA256: String) {
    self.productID = productID
    self.role = role
    self.inputSHA256 = inputSHA256
  }
}

package struct LibraryRemoteReceipt: Codable, Sendable, Equatable {
  package var format: LibraryRemoteFormat
  package var localSHA256: String
  package var remoteAssetID: UUID?
  package var remoteSize: UInt64?
  package var remoteFingerprint: String?
  package var remoteSHA256: String?
  package var observedAt: Date

  package init(
    format: LibraryRemoteFormat, localSHA256: String, remoteAssetID: UUID? = nil,
    remoteSize: UInt64? = nil, remoteFingerprint: String? = nil,
    remoteSHA256: String? = nil, observedAt: Date = Date()
  ) {
    self.format = format
    self.localSHA256 = localSHA256
    self.remoteAssetID = remoteAssetID
    self.remoteSize = remoteSize
    self.remoteFingerprint = remoteFingerprint
    self.remoteSHA256 = remoteSHA256
    self.observedAt = observedAt
  }
}

package struct LibraryRemoteLink: Codable, Sendable, Equatable {
  package var providerID: String
  package var connectionID: UUID
  package var remoteBookID: UUID
  package var state: LibraryLinkState
  package var evidence: LibraryLinkEvidence
  package var revision: UInt64
  package var linkedAt: Date
  package var lastObservedAt: Date?
  package var remoteTitle: String?
  package var remoteAuthors: [String]
  package var receipts: [LibraryRemoteReceipt]
  package var excludedRemoteBookIDs: [UUID]

  package init(
    providerID: String, connectionID: UUID, remoteBookID: UUID,
    state: LibraryLinkState = .active, evidence: LibraryLinkEvidence,
    revision: UInt64 = 0, linkedAt: Date = Date(), lastObservedAt: Date? = nil,
    remoteTitle: String? = nil, remoteAuthors: [String] = [],
    receipts: [LibraryRemoteReceipt] = [], excludedRemoteBookIDs: [UUID] = []
  ) {
    self.providerID = providerID
    self.connectionID = connectionID
    self.remoteBookID = remoteBookID
    self.state = state
    self.evidence = evidence
    self.revision = revision
    self.linkedAt = linkedAt
    self.lastObservedAt = lastObservedAt
    self.remoteTitle = remoteTitle
    self.remoteAuthors = remoteAuthors
    self.receipts = receipts
    self.excludedRemoteBookIDs = excludedRemoteBookIDs
  }
}

package struct LibraryEdition: Codable, Sendable, Identifiable, Equatable {
  package var id: UUID
  package var workID: UUID
  package var revision: UInt64
  package var createdAt: Date
  package var updatedAt: Date
  package var metadata: LibraryCatalogMetadata
  package var outputDirectory: String
  package var outputBaseName: String
  package var source: LibrarySourceArtifact
  package var products: [LibraryLocalProduct]
  package var dependencies: [LibraryProductDependency]
  package var remoteLinks: [LibraryRemoteLink]

  package init(
    id: UUID = UUID(), workID: UUID? = nil, revision: UInt64 = 0,
    createdAt: Date = Date(), updatedAt: Date? = nil,
    metadata: LibraryCatalogMetadata, outputDirectory: String,
    outputBaseName: String, source: LibrarySourceArtifact,
    products: [LibraryLocalProduct] = [], dependencies: [LibraryProductDependency] = [],
    remoteLinks: [LibraryRemoteLink] = []
  ) {
    self.id = id
    self.workID = workID ?? id
    self.revision = revision
    self.createdAt = createdAt
    self.updatedAt = updatedAt ?? createdAt
    self.metadata = metadata
    self.outputDirectory = outputDirectory
    self.outputBaseName = outputBaseName
    self.source = source
    self.products = products
    self.dependencies = dependencies
    self.remoteLinks = remoteLinks
  }
}

package struct LibraryRemoteAssetSnapshot: Codable, Sendable, Equatable, Identifiable {
  package var id: UUID { assetID }
  package var format: LibraryRemoteFormat
  package var assetID: UUID
  package var filepath: String?
  package var fingerprint: String?
  package var fileSize: UInt64?
  package var sha256: String?
  package var updatedAt: String?
  package var state: LibraryRemoteAssetState
  package var status: String?
  package var currentStage: String?
  package var stageProgress: Double?
  package var identifiers: [LibraryRemoteIdentifier]

  package init(
    format: LibraryRemoteFormat, assetID: UUID, filepath: String? = nil,
    fingerprint: String? = nil, fileSize: UInt64? = nil, sha256: String? = nil,
    updatedAt: String? = nil, state: LibraryRemoteAssetState = .unknown,
    status: String? = nil, currentStage: String? = nil, stageProgress: Double? = nil,
    identifiers: [LibraryRemoteIdentifier] = []
  ) {
    self.format = format
    self.assetID = assetID
    self.filepath = filepath
    self.fingerprint = fingerprint
    self.fileSize = fileSize
    self.sha256 = sha256
    self.updatedAt = updatedAt
    self.state = state
    self.status = status
    self.currentStage = currentStage
    self.stageProgress = stageProgress
    self.identifiers = identifiers
  }
}

package struct LibraryRemoteIdentifier: Codable, Sendable, Equatable, Hashable {
  package var id: UUID?
  package var kind: String?
  package var name: String?
  package var value: String
  package var scope: LibraryIdentifierScope

  package init(
    id: UUID? = nil, kind: String? = nil, name: String? = nil,
    value: String, scope: LibraryIdentifierScope = .edition
  ) {
    self.id = id
    self.kind = kind
    self.name = name
    self.value = value
    self.scope = scope
  }
}

package struct LibraryRemoteBookSnapshot: Codable, Sendable, Equatable, Identifiable {
  package var id: UUID { remoteBookID }
  package var connectionID: UUID
  package var remoteBookID: UUID
  package var title: String
  package var subtitle: String?
  package var authors: [String]
  package var narrators: [String]
  package var identifiers: [LibraryRemoteIdentifier]
  package var assets: [LibraryRemoteAssetSnapshot]
  package var observedAt: Date
  package var generation: UInt64
  package var missingAt: Date?
  package var updatedAt: String?

  package init(
    connectionID: UUID, remoteBookID: UUID, title: String, subtitle: String? = nil,
    authors: [String] = [], narrators: [String] = [],
    identifiers: [LibraryRemoteIdentifier] = [], assets: [LibraryRemoteAssetSnapshot] = [],
    observedAt: Date = Date(), generation: UInt64 = 0, missingAt: Date? = nil,
    updatedAt: String? = nil
  ) {
    self.connectionID = connectionID
    self.remoteBookID = remoteBookID
    self.title = title
    self.subtitle = subtitle
    self.authors = authors
    self.narrators = narrators
    self.identifiers = identifiers
    self.assets = assets
    self.observedAt = observedAt
    self.generation = generation
    self.missingAt = missingAt
    self.updatedAt = updatedAt
  }

  package func asset(_ format: LibraryRemoteFormat) -> LibraryRemoteAssetSnapshot? {
    assets.first { $0.format == format }
  }
}

package struct LibraryConnection: Codable, Sendable, Identifiable, Equatable {
  package var id: UUID
  package var providerID: String
  package var origin: URL
  package var displayName: String
  package var username: String?
  package var remoteUserID: UUID?
  package var permissionsData: Data?
  package var connectedAt: Date
  package var disconnectedAt: Date?

  package init(
    id: UUID, providerID: String = "storyteller", origin: URL,
    displayName: String, username: String?, remoteUserID: UUID? = nil,
    permissionsData: Data? = nil, connectedAt: Date, disconnectedAt: Date? = nil
  ) {
    self.id = id
    self.providerID = providerID
    self.origin = origin
    self.displayName = displayName
    self.username = username
    self.remoteUserID = remoteUserID
    self.permissionsData = permissionsData
    self.connectedAt = connectedAt
    self.disconnectedAt = disconnectedAt
  }
}

package struct LibrarySyncResult: Sendable, Equatable {
  package var generation: UInt64
  package var observedAt: Date
  package var bookCount: Int
}

package struct LibraryAuditEvent: Codable, Sendable, Identifiable, Equatable {
  package var id: UUID
  package var occurredAt: Date
  package var kind: String
  package var editionID: UUID?
  package var connectionID: UUID?
  package var remoteBookID: UUID?
  package var detailData: Data?

  package init(
    id: UUID = UUID(), occurredAt: Date = Date(), kind: String,
    editionID: UUID? = nil, connectionID: UUID? = nil,
    remoteBookID: UUID? = nil, detailData: Data? = nil
  ) {
    self.id = id
    self.occurredAt = occurredAt
    self.kind = kind
    self.editionID = editionID
    self.connectionID = connectionID
    self.remoteBookID = remoteBookID
    self.detailData = detailData
  }
}

package struct LibraryProvenanceAssertion: Codable, Sendable, Identifiable, Equatable {
  package var id: UUID
  package var connectionID: UUID
  package var remoteBookID: UUID
  package var remoteAssetID: UUID
  package var remoteSHA256: String?
  package var provenance: NarrationProvenance
  package var coherence: PackageCoherence
  package var alignedAudioAssetID: UUID?
  package var alignedAudioSHA256: String?
  package var source: String
  package var createdAt: Date

  package init(
    id: UUID = UUID(), connectionID: UUID, remoteBookID: UUID,
    remoteAssetID: UUID, remoteSHA256: String? = nil,
    provenance: NarrationProvenance, coherence: PackageCoherence,
    alignedAudioAssetID: UUID? = nil, alignedAudioSHA256: String? = nil,
    source: String, createdAt: Date = Date()
  ) {
    self.id = id
    self.connectionID = connectionID
    self.remoteBookID = remoteBookID
    self.remoteAssetID = remoteAssetID
    self.remoteSHA256 = remoteSHA256
    self.provenance = provenance
    self.coherence = coherence
    self.alignedAudioAssetID = alignedAudioAssetID
    self.alignedAudioSHA256 = alignedAudioSHA256
    self.source = source
    self.createdAt = createdAt
  }
}

package struct LibraryIdentifierAssertion: Codable, Sendable, Identifiable, Equatable {
  package var id: UUID
  package var editionID: UUID
  package var scope: LibraryIdentifierScope
  package var kind: String?
  package var value: String
  package var disposition: LibraryIdentifierDisposition
  package var source: String
  package var note: String?
  package var createdAt: Date

  package init(
    id: UUID = UUID(), editionID: UUID, scope: LibraryIdentifierScope = .edition,
    kind: String?, value: String, disposition: LibraryIdentifierDisposition = .asserted,
    source: String, note: String? = nil, createdAt: Date = Date()
  ) {
    self.id = id
    self.editionID = editionID
    self.scope = scope
    self.kind = kind
    self.value = value
    self.disposition = disposition
    self.source = source
    self.note = note
    self.createdAt = createdAt
  }
}

// MARK: - ReadAloud quality history

/// Persistence-neutral identity for the artifact that was audited. Exactly one
/// case is stored for every run; remote audits identify the concrete asset, not
/// merely the Storyteller book containing it.
package enum LibraryReadAloudAuditTarget: Codable, Sendable, Hashable {
  case localProduct(UUID)
  case remote(connectionID: UUID, bookID: UUID, assetID: UUID)
  case standalone(path: String)
}

package enum LibraryReadAloudAuditLifecycle: String, Codable, Sendable {
  case queued, running, completed, cancelled, failed
}

package struct LibraryReadAloudAuditFinding: Codable, Sendable, Identifiable, Equatable {
  package var id: UUID
  package var dimension: String
  package var code: String
  package var verdict: String
  package var confidence: String
  package var summary: String
  package var evidenceData: Data?

  package init(
    id: UUID = UUID(), dimension: String, code: String, verdict: String,
    confidence: String, summary: String, evidenceData: Data? = nil
  ) {
    self.id = id
    self.dimension = dimension
    self.code = code
    self.verdict = verdict
    self.confidence = confidence
    self.summary = summary
    self.evidenceData = evidenceData
  }
}

package struct LibraryReadAloudAuditRun: Codable, Sendable, Identifiable, Equatable {
  package var id: UUID
  package var target: LibraryReadAloudAuditTarget
  package var artifactSHA256: String?
  package var referenceSHA256: String?
  package var analyzerIdentity: String
  package var policyVersion: Int
  package var mode: String
  package var lifecycle: LibraryReadAloudAuditLifecycle
  package var progress: Double
  package var progressMessage: String?
  package var verdict: String?
  package var evidenceAdequacy: String?
  package var modelIdentity: String?
  package var toolIdentity: String?
  package var metricsData: Data?
  package var reportData: Data?
  package var startedAt: Date
  package var updatedAt: Date
  package var completedAt: Date?
  package var error: String?
  package var findings: [LibraryReadAloudAuditFinding]

  package init(
    id: UUID = UUID(), target: LibraryReadAloudAuditTarget,
    artifactSHA256: String? = nil, referenceSHA256: String? = nil,
    analyzerIdentity: String = "readaloud-quality-v1", policyVersion: Int = 1,
    mode: String, lifecycle: LibraryReadAloudAuditLifecycle = .queued,
    progress: Double = 0, progressMessage: String? = nil, verdict: String? = nil,
    evidenceAdequacy: String? = nil, modelIdentity: String? = nil,
    toolIdentity: String? = nil, metricsData: Data? = nil, reportData: Data? = nil,
    startedAt: Date = Date(), updatedAt: Date = Date(), completedAt: Date? = nil,
    error: String? = nil, findings: [LibraryReadAloudAuditFinding] = []
  ) {
    self.id = id
    self.target = target
    self.artifactSHA256 = artifactSHA256
    self.referenceSHA256 = referenceSHA256
    self.analyzerIdentity = analyzerIdentity
    self.policyVersion = policyVersion
    self.mode = mode
    self.lifecycle = lifecycle
    self.progress = progress
    self.progressMessage = progressMessage
    self.verdict = verdict
    self.evidenceAdequacy = evidenceAdequacy
    self.modelIdentity = modelIdentity
    self.toolIdentity = toolIdentity
    self.metricsData = metricsData
    self.reportData = reportData
    self.startedAt = startedAt
    self.updatedAt = updatedAt
    self.completedAt = completedAt
    self.error = error
    self.findings = findings
  }
}

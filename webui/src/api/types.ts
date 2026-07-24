// Hand-written mirrors of the Swift DTOs in
// Sources/SpokenFolioApp/HTTP/WebAPI/WebAPIDTOs.swift.
// docs/WEBUI.md is the normative contract; keep the two in sync.

export interface ServerStatus {
  health: "starting" | "ready" | "permission_required" | "unavailable";
  endpoint: string;
  host: string;
  port: number;
  voiceCount: number;
  defaultVoice: string | null;
  studioHosted: boolean;
  schedulerState: "hosted" | "notHosted" | "lockedByOtherProcess";
  fullDiskAccessInstructions: string | null;
}

export interface QueueStatus {
  isSuspended: boolean;
  activeJobID: string | null;
  queuedCount: number;
  runningCount: number;
  error: string | null;
  scanIssueCount: number;
  sequence: number;
}

export interface JobSummary {
  id: string;
  title: string;
  author: string | null;
  kindTitle: string;
  statusTitle: string;
  lifecycle: "queued" | "running" | "paused" | "needsAttention" | "completed" | "cancelled";
  queueDisposition: string;
  queuePosition: number | null;
  progress: number | null;
  createdAt: string;
  updatedAt: string;
}

export interface Voices {
  voices: { id: string; name: string; language: string }[];
  defaultVoiceID: string | null;
}

export interface RelocationStatus {
  active: boolean;
  total: number;
  completed: number;
  currentTitle: string | null;
  destination: string | null;
  failures: { title: string; reason: string }[];
  sequence: number;
}

export interface Settings {
  processedDirectory: string;
  /** False until the user has explicitly chosen (or confirmed) the library folder. */
  configured: boolean;
  /** Present while/after a library move; null when none has happened. */
  relocation: RelocationStatus | null;
  capabilities: {
    launchAtLogin: boolean;
    revealInFinder: boolean;
    restartServer: boolean;
  };
}

export interface FSEntry {
  name: string;
  path: string;
  kind: "directory" | "file";
}

export interface FSList {
  path: string;
  parent: string | null;
  entries: FSEntry[];
}

export interface APIErrorEnvelope {
  error: { code: string; message: string };
}

export type EventTopic =
  | "server"
  | "queue"
  | "jobs"
  | "drafts"
  | "quality"
  | "tools"
  | "library";

export interface MirrorStatus {
  isBusy: boolean;
  total: number;
  completed: number;
  currentTitle: string | null;
  failures: { title: string; reason: string }[];
  sequence: number;
  /** Connection the current/most recent mirror run downloads from. */
  connectionID?: string;
}

export interface JobStage {
  stage: string;
  title: string;
  status: "pending" | "running" | "succeeded" | "needsAttention" | "skipped" | "cancelled";
  statusTitle: string;
  fraction: number | null;
  message: string | null;
}

export interface JobDetail {
  summary: JobSummary;
  stages: JobStage[];
  lastError: string | null;
  attempt: number;
  warnings: string[];
  products: {
    kind: string;
    path: string;
    sizeBytes: number;
    sha256: string;
    verifiedAt: string;
  }[];
  settings: {
    voiceID: string;
    bitrateKbps: number;
    workers: number;
    paragraphPauseSeconds: number;
    chapterPauseSeconds: number;
    announceTitles: boolean;
    readAloudBitrateKbps: number | null;
    readAloudEngine: string | null;
    readAloudModel: string | null;
    storytellerProducts: string[];
  };
  runtime: {
    backendID: string;
    modelID: string;
    voiceID: string;
    voiceRevision: string | null;
    macOSVersion: string | null;
    macOSBuild: string | null;
    frameworkVersion: string | null;
  } | null;
  audiobookProgress: {
    totalChapters: number;
    totalCharacters: number;
    reusedChapters: number;
    currentChapterIndex: number | null;
    currentChapterTitle: string | null;
  } | null;
  batch: { ordinal: number; count: number } | null;
  catalogID: string | null;
}

export interface DraftSection {
  id: number;
  title: string;
  role: string;
  characterCount: number;
  initiallyIncluded: boolean;
  included: boolean;
}

export interface Draft {
  id: string;
  displayName: string;
  status: "uploading" | "loading" | "ready" | "invalid" | "skipped" | "queued";
  statusMessage: string | null;
  title: string | null;
  author: string | null;
  language: string | null;
  chapterCount: number;
  sourceSize: number;
  sourceSHA256: string | null;
  hasCover: boolean;
  inLibrary: boolean;
  sections: DraftSection[];
}

export interface AudiobookVoices {
  voices: { id: string; name: string; language: string; quality: string }[];
  defaultVoiceID: string;
  permissionWarning: string | null;
}

export interface DraftProcessSettings {
  voiceID: string;
  bitrateKbps: number;
  workers: number;
  announceTitles: boolean;
  paragraphPauseSeconds: number;
  chapterPauseSeconds: number;
  createReadAloud: boolean;
  readAloudBitrateKbps: number;
  readAloudASREngineID: "synthesis" | "apple" | "whisper";
  readAloudASRModelID: string | null;
  storytellerConnectionID: string | null;
  sendSourceEPUB: boolean;
  sendM4B: boolean;
  sendReadAloud: boolean;
  outputDirectory: string | null;
  reprocessAudiobook: boolean;
}

export interface DraftQueueOutcome {
  draftID: string;
  status: "queued" | "skipped" | "failed";
  message: string | null;
}

export type SlotState = "verified" | "present" | "pending" | "missing";

export interface LibraryRow {
  id: string;
  title: string;
  author: string | null;
  level: number;
  levelLabel: string;
  presence: "Local" | "Storyteller" | "Both";
  narration: string;
  slots: {
    epub: SlotState;
    ttsAudiobook: SlotState;
    ttsReadAloud: SlotState;
    humanAudiobook: SlotState;
    humanReadAloud: SlotState;
  };
  ttsProvenance: string | null;
  localQualityVerdict: string | null;
  remoteQualityVerdict: string | null;
  updatedAt: string;
  inLibrary: boolean;
  recordID: string | null;
  localProducts: { kind: string; path: string; sizeBytes: number }[];
  identifiers: { kind: string; value: string }[];
  remoteEPUB: RemoteAsset | null;
  remoteAudiobook: RemoteAsset | null;
  remoteReadAloud: RemoteAsset | null;
  suggestedRemoteTitle: string | null;
  suggestedRemoteAuthors: string[];
  suggestedRemoteBookID: string | null;
  localReadAloudProductID: string | null;
  remoteBookID: string | null;
  remoteReadAloudAssetID: string | null;
  remoteReadAloudReady: boolean;
  canStartRemoteReadAloud: boolean;
  hasStorytellerLink: boolean;
}

export interface MatchFindResult {
  outcome: "linked" | "review" | "empty";
  candidates: { remoteBookID: string; title: string; authors: string[]; reason: string }[];
}

export interface RemoteAsset {
  state: string;
  sizeBytes: number | null;
  status: string | null;
  stage: string | null;
  stageProgress: number | null;
}

export interface Library {
  rows: LibraryRow[];
  issues: string[];
  editionGapCount: number;
  snapshotStale: boolean;
  error: string | null;
  connections: { id: string; label: string }[];
  /** True when the Storyteller refresh failed with a 401; `error` explains. */
  authExpired?: boolean;
  /** True when the requested `?connection=` id no longer exists; rows are still served local-only. */
  connectionMissing?: boolean;
}

export type StorytellerReplacementDisposition =
  | "reuploadedIdentical"
  | "replacedWithLocal"
  | "restorableFromLocal"
  | "lostForever";

export interface StorytellerReplacementAsset {
  /** "ebook" | "audiobook" | "readaloud" */
  format: string;
  disposition: StorytellerReplacementDisposition;
  humanNarration: boolean;
  size?: number;
}

/**
 * One book whose remote Storyteller content would be destroyed by a
 * whole-book replacement (Storyteller has no in-place overwrite; replace
 * means delete the remote book and re-create it from local products).
 */
export interface StorytellerReplacement {
  rowID: string;
  title: string;
  /** "unknown" | "spokenFolioTTS" | "otherTTS" | "human" */
  remoteNarration: string;
  losesHumanAudio: boolean;
  assets: StorytellerReplacementAsset[];
}

export type SentNarration = "spokenFolioTTS" | "human";

export interface AsinCandidate {
  asin: string;
  title: string;
  authors: string[];
  narrators: string[];
}

export interface AsinResolve {
  asin: string;
  found: boolean;
  title: string | null;
  authors: string[];
  narrators: string[];
}

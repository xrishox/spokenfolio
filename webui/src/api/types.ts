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
  deliveryActiveJobID: string | null;
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

/** Backend-neutral TTS inventory returned by GET /api/tts/catalog. `id` is
 * the public OpenAI-compatible model name; backendID/modelID are the durable
 * synthesis identity used by production jobs. */
export interface TTSModel {
  id: string;
  backendID: string;
  modelID: string;
  name: string;
  defaultVoiceID: string;
  supportsPace: boolean;
  supportsExpressivity: boolean;
  recommendedAudiobookWorkers?: number;
  maximumAudiobookWorkers?: number;
}

export interface TTSVoice {
  id: string;
  name: string;
  lang: string;
  quality: string;
  backend?: string;
  model?: string;
  supportsPace?: boolean;
  supportsExpressivity?: boolean;
}

export interface TTSCatalog {
  models: TTSModel[];
  voices: TTSVoice[];
  defaultModelID: string;
  defaultBackendID?: string;
  defaultInternalModelID?: string;
  defaultVoiceID: string;
  defaultPacePreset?: number | null;
  defaultExpressivityPreset?: number | null;
}

export interface TTSSelection {
  backendID: string;
  modelID: string;
  voiceID: string;
  pacePreset: number | null;
  expressivityPreset: number | null;
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

/** Remote format kinds the mirror endpoint can download into the local library. */
export type MirrorFormat = "ebook" | "audiobook" | "readaloud";

export interface StartMirrorRequest {
  rowIDs?: string[];
  all?: boolean;
  /** When omitted, every not-yet-local remote format downloads for each in-scope book. */
  formats?: MirrorFormat[];
}

export type DeleteScope = "local" | "storyteller" | "both";
export type DeleteSlot =
  | "sourceEPUB"
  | "m4b"
  | "readAloudEPUB"
  | "humanAudiobook"
  | "humanReadAloudEPUB";

export interface DeletePlanRequest {
  rowIDs: string[];
  slots: DeleteSlot[];
  scope: DeleteScope;
}

/** Per-book deletion manifest computed server-side. `wholeBookLocal` means the
 *  source slot was chosen and the whole local book goes; `losesHumanContent`
 *  drives the escalated warning + required acknowledgment. */
export interface DeletePlan {
  books: {
    rowID: string;
    title: string;
    wholeBookLocal: boolean;
    losesHumanContent: boolean;
    localSlots: string[];
    remoteSlots: { format: string; humanNarration: boolean; size: number | null }[];
  }[];
  skipped: { rowID: string; title: string; reason: string }[];
}

export interface DeleteRequest {
  rowIDs: string[];
  slots: DeleteSlot[];
  scope: DeleteScope;
  acknowledgedRowIDs: string[];
}

export interface DeleteResult {
  books: {
    rowID: string;
    title: string;
    blocked: string | null;
    wholeBookDeleted: boolean;
    localDeleted: string[];
    remoteDeleted: string[];
    failures: { label: string; reason: string }[];
  }[];
  library: Library;
}

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
    backendID: string;
    modelID: string;
    voiceID: string;
    pacePreset: number | null;
    expressivityPreset: number | null;
    bitrateKbps: number;
    workers: number;
    unitGranularityID: "paragraph" | "sentence";
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

export interface StorytellerConnectionSummary {
  id: string;
  label: string;
}

export type ReadAloudEngineID = "synthesis" | "apple" | "whisper";

/** The audiobook-synthesis settings shared by every production form. */
export interface AudiobookSettings extends TTSSelection {
  bitrateKbps: number;
  workers: number;
  unitGranularityID: "paragraph" | "sentence";
  announceTitles: boolean;
  paragraphPauseSeconds: number;
  chapterPauseSeconds: number;
}

/** The ReadAloud settings shared by every production form. */
export interface ReadAloudSettings {
  readAloudBitrateKbps: number;
  readAloudASREngineID: ReadAloudEngineID;
  readAloudASRModelID: string | null;
}

/** The one server-owned starting point for every production form, from
 * `GET /api/production/defaults` and embedded in the library process plan.
 * The catalog of models and voices is NOT part of it: that comes once from
 * `GET /api/tts/catalog`. */
export interface ProductionDefaults extends AudiobookSettings, ReadAloudSettings {
  publicModelID: string;
  /** Why `workers` has this value: a configured count, the selected model's
   * measured recommendation, the core-count default, or what the user last
   * queued with. `remembered` counts as user-set, so changing models must not
   * overwrite it. */
  workerSource: "explicit" | "recommended" | "hardware" | "remembered";
  workerWarning: string | null;
  /** Remembered from the last queued book. */
  createReadAloud: boolean;
  storytellerConnectionID: string | null;
  sendSourceEPUB: boolean;
  sendM4B: boolean;
  sendReadAloud: boolean;
  permissionWarning: string | null;
  connections: StorytellerConnectionSummary[];
}

export interface DraftProcessSettings extends AudiobookSettings, ReadAloudSettings {
  createReadAloud: boolean;
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
  /** Known-on-Storyteller per slot: "verified" | "present" | null (unknown/absent — display nothing). */
  storytellerSlots: {
    epub: string | null;
    ttsAudiobook: string | null;
    ttsReadAloud: string | null;
    humanAudiobook: string | null;
    humanReadAloud: string | null;
  };
  /** Remote formats this book has that are not yet stored locally. */
  downloadableFormats: string[];
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

export interface StorytellerReplacementAsset {
  /** "ebook" | "audiobook" | "readaloud" */
  format: string;
  humanNarration: boolean;
  size?: number;
}

/**
 * The remote files a send would replace for one book: only formats being
 * sent whose remote slots hold different content. Each is replaced
 * individually through Storyteller's own replace-asset API; nothing else
 * on the book is touched.
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

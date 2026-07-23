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

export interface Settings {
  processedDirectory: string;
  capabilities: {
    launchAtLogin: boolean;
    revealInFinder: boolean;
    restartServer: boolean;
  };
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
  | "tools";

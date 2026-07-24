import type { SentNarration, StorytellerReplacement } from "../../api/types";

export interface ProcessToggles {
  createMissingAudiobooks: boolean;
  recreateExistingAudiobooks: boolean;
  createMissingReadAlouds: boolean;
  recreateExistingReadAlouds: boolean;
  sendToStoryteller: boolean;
  deliveryConnectionID: string | null;
  sendEPUB: boolean;
  sendM4B: boolean;
  sendReadAloud: boolean;
}

export interface QueuePayloadInput {
  rowIDs: string[];
  toggles: ProcessToggles;
  confirmedRemoteBookID: string | null;
  voiceID: string;
  bitrateKbps: number;
  workers: number;
  announceTitles: boolean;
  paragraphPauseSeconds: number;
  chapterPauseSeconds: number;
  readAloudBitrateKbps: number;
  readAloudASREngineID: "synthesis" | "apple" | "whisper";
  readAloudASRModelID: string | null;
  /** Declares how the sent ReadAloud narration was produced. */
  assertNarration: SentNarration;
  /** The replacement manifests currently shown to the user (may be empty). */
  replacements: StorytellerReplacement[];
  /** Whether the user checked the replacement acknowledgment. */
  replaceAcknowledged: boolean;
}

/**
 * Builds the POST /api/library/process/queue body. Single builder for every
 * sheet intent ("process" | "sendOnly" | "readAloud").
 */
export function buildQueuePayload(input: QueuePayloadInput): string {
  const body: Record<string, unknown> = {
    rowIDs: input.rowIDs,
    ...input.toggles,
    confirmedRemoteBookID: input.confirmedRemoteBookID,
    voiceID: input.voiceID,
    bitrateKbps: input.bitrateKbps,
    workers: input.workers,
    announceTitles: input.announceTitles,
    paragraphPauseSeconds: input.paragraphPauseSeconds,
    chapterPauseSeconds: input.chapterPauseSeconds,
    readAloudBitrateKbps: input.readAloudBitrateKbps,
    readAloudASREngineID: input.readAloudASREngineID,
    readAloudASRModelID: input.readAloudASRModelID,
  };
  if (input.toggles.sendReadAloud) {
    body.assertNarration = input.assertNarration;
  }
  if (input.replaceAcknowledged && input.replacements.length > 0) {
    body.replaceAcknowledgedRowIDs = input.replacements.map(
      (replacement) => replacement.rowID,
    );
  }
  return JSON.stringify(body);
}

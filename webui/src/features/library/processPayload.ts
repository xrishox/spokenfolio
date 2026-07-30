import type {
  AudiobookSettings,
  ReadAloudSettings,
  SentNarration,
  StorytellerReplacement,
} from "../../api/types";

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

export interface QueuePayloadInput extends AudiobookSettings, ReadAloudSettings {
  rowIDs: string[];
  toggles: ProcessToggles;
  confirmedRemoteBookID: string | null;
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
    backendID: input.backendID,
    modelID: input.modelID,
    voiceID: input.voiceID,
    pacePreset: input.pacePreset,
    expressivityPreset: input.expressivityPreset,
    bitrateKbps: input.bitrateKbps,
    workers: input.workers,
    unitGranularityID: input.unitGranularityID,
    announceTitles: input.announceTitles,
    paragraphPauseSeconds: input.paragraphPauseSeconds,
    chapterPauseSeconds: input.chapterPauseSeconds,
    readAloudBitrateKbps: input.readAloudBitrateKbps,
    readAloudASREngineID: "synthesis",
    readAloudASRModelID: null,
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

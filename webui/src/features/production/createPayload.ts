import type {
  Draft,
  DraftProcessSettings,
  ProductionDefaults,
} from "../../api/types";

/** Every production setting starts from the server's own defaults; the web
 * client never carries production values of its own. */
export function settingsFromDefaults(defaults: ProductionDefaults): DraftProcessSettings {
  return {
    backendID: defaults.backendID,
    modelID: defaults.modelID,
    voiceID: defaults.voiceID,
    // A model without expressive controls omits the presets entirely; the
    // queue payload states their absence rather than dropping the keys.
    pacePreset: defaults.pacePreset ?? null,
    expressivityPreset: defaults.expressivityPreset ?? null,
    bitrateKbps: defaults.bitrateKbps,
    workers: defaults.workers,
    announceTitles: defaults.announceTitles,
    paragraphPauseSeconds: defaults.paragraphPauseSeconds,
    chapterPauseSeconds: defaults.chapterPauseSeconds,
    createReadAloud: defaults.createReadAloud,
    readAloudBitrateKbps: defaults.readAloudBitrateKbps,
    // ReadAloud production consumes exact sentence timings from TTS. ASR is
    // reserved for separate audit tooling, never the production payload.
    readAloudASREngineID: "synthesis",
    readAloudASRModelID: null,
    storytellerConnectionID: defaults.storytellerConnectionID ?? null,
    sendSourceEPUB: defaults.sendSourceEPUB,
    sendM4B: defaults.sendM4B,
    sendReadAloud: defaults.sendReadAloud,
    outputDirectory: null,
    reprocessAudiobook: false,
  };
}

export function buildDraftQueueEntry(
  draft: Pick<Draft, "id" | "sections">,
  settings: DraftProcessSettings,
) {
  return {
    draftID: draft.id,
    includedSections: draft.sections
      .filter((section) => section.included)
      .map((section) => section.id),
    ...settings,
  };
}

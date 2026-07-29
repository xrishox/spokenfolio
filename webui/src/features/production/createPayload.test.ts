import { describe, expect, it } from "vitest";
import type { DraftProcessSettings, ProductionDefaults } from "../../api/types";
import { buildDraftQueueEntry, settingsFromDefaults } from "./createPayload";

const settings: DraftProcessSettings = {
  backendID: "siri-fm",
  modelID: "siri-expressive",
  voiceID: "en-US-F",
  pacePreset: 2,
  expressivityPreset: 5,
  bitrateKbps: 256,
  workers: 4,
  announceTitles: true,
  paragraphPauseSeconds: 0.6,
  chapterPauseSeconds: 1.75,
  createReadAloud: false,
  readAloudBitrateKbps: 32,
  readAloudASREngineID: "synthesis",
  readAloudASRModelID: null,
  storytellerConnectionID: null,
  sendSourceEPUB: false,
  sendM4B: false,
  sendReadAloud: false,
  outputDirectory: null,
  reprocessAudiobook: false,
};

describe("buildDraftQueueEntry", () => {
  it("propagates the complete TTS selection and included sections", () => {
    const entry = buildDraftQueueEntry(
      {
        id: "draft-1",
        sections: [
          {
            id: 1,
            title: "One",
            role: "body",
            characterCount: 10,
            initiallyIncluded: true,
            included: true,
          },
          {
            id: 2,
            title: "Two",
            role: "body",
            characterCount: 20,
            initiallyIncluded: true,
            included: false,
          },
        ],
      },
      settings,
    );

    expect(entry.includedSections).toEqual([1]);
    expect(entry).toMatchObject({
      backendID: "siri-fm",
      modelID: "siri-expressive",
      voiceID: "en-US-F",
      pacePreset: 2,
      expressivityPreset: 5,
    });
  });

  it("initializes every queue setting from the server-owned production defaults", () => {
    const defaults: ProductionDefaults = {
      publicModelID: "siri-expressive",
      backendID: "siri-fm",
      modelID: "siri-expressive",
      voiceID: "configured-voice",
      pacePreset: 1,
      expressivityPreset: 4,
      bitrateKbps: 64,
      workers: 7,
      workerSource: "explicit",
      workerWarning: null,
      announceTitles: false,
      paragraphPauseSeconds: 0.25,
      chapterPauseSeconds: 2.5,
      readAloudBitrateKbps: 64,
      readAloudASREngineID: "whisper",
      readAloudASRModelID: "large-v3",
      createReadAloud: true,
      storytellerConnectionID: "11111111-2222-3333-4444-555555555555",
      sendSourceEPUB: true,
      sendM4B: true,
      sendReadAloud: false,
      permissionWarning: null,
      connections: [],
    };

    expect(settingsFromDefaults(defaults)).toMatchObject({
      backendID: defaults.backendID,
      modelID: defaults.modelID,
      voiceID: defaults.voiceID,
      pacePreset: defaults.pacePreset,
      expressivityPreset: defaults.expressivityPreset,
      bitrateKbps: defaults.bitrateKbps,
      workers: defaults.workers,
      announceTitles: defaults.announceTitles,
      paragraphPauseSeconds: defaults.paragraphPauseSeconds,
      chapterPauseSeconds: defaults.chapterPauseSeconds,
      // ReadAloud defaults come from the server too — the client keeps no
      // production values of its own.
      readAloudBitrateKbps: defaults.readAloudBitrateKbps,
      readAloudASREngineID: "synthesis",
      readAloudASRModelID: null,
      // Remembered ReadAloud and delivery intent comes back too, so the form
      // opens where the user left it rather than resetting every time.
      createReadAloud: true,
      storytellerConnectionID: defaults.storytellerConnectionID,
      sendSourceEPUB: true,
      sendM4B: true,
      sendReadAloud: false,
    });
  });

  it("never carries remembered ASR settings into production", () => {
    const defaults = {
      ...settings,
      publicModelID: "siri-expressive",
      workerSource: "recommended" as const,
      workerWarning: null,
      readAloudASREngineID: "whisper" as const,
      readAloudASRModelID: "large-v3-turbo",
      permissionWarning: null,
      connections: [],
    };

    expect(settingsFromDefaults(defaults)).toMatchObject({
      readAloudASREngineID: "synthesis",
      readAloudASRModelID: null,
    });
  });
});

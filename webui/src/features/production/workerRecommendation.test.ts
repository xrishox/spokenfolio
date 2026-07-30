import { describe, expect, it } from "vitest";
import type { AudiobookSettings, TTSCatalog } from "../../api/types";
import { workersAfterSelectionChange } from "./workerRecommendation";

const catalog: TTSCatalog = {
  models: [
    {
      id: "tts-1",
      backendID: "siri",
      modelID: "siri-private",
      name: "Siri",
      defaultVoiceID: "siri-voice",
      supportsPace: false,
      supportsExpressivity: false,
      recommendedAudiobookWorkers: 8,
      maximumAudiobookWorkers: 8,
    },
    {
      id: "siri-expressive",
      backendID: "siri-fm",
      modelID: "siri-expressive",
      name: "Siri Expressive",
      defaultVoiceID: "en-US-F",
      supportsPace: true,
      supportsExpressivity: true,
      recommendedAudiobookWorkers: 1,
      maximumAudiobookWorkers: 1,
    },
  ],
  voices: [],
  defaultModelID: "tts-1",
  defaultVoiceID: "siri-voice",
};

const previous: AudiobookSettings = {
  backendID: "siri",
  modelID: "siri-private",
  voiceID: "siri-voice",
  pacePreset: null,
  expressivityPreset: null,
  bitrateKbps: 64,
  workers: 8,
  unitGranularityID: "paragraph",
  announceTitles: true,
  paragraphPauseSeconds: 0.6,
  chapterPauseSeconds: 1.75,
};

const expressive = {
  backendID: "siri-fm",
  modelID: "siri-expressive",
  voiceID: "en-US-F",
  pacePreset: 3,
  expressivityPreset: 3,
};

describe("workersAfterSelectionChange", () => {
  it("adopts the new model's recommendation when the user has not set workers", () => {
    expect(
      workersAfterSelectionChange({
        previous,
        selection: expressive,
        catalog,
        workersEdited: false,
      }),
    ).toBe(1);
  });

  it("clamps an explicitly edited count to the new model maximum", () => {
    expect(
      workersAfterSelectionChange({
        previous: { ...previous, workers: 3 },
        selection: expressive,
        catalog,
        workersEdited: true,
      }),
    ).toBe(1);
  });

  it("leaves workers alone when only the voice changed", () => {
    expect(
      workersAfterSelectionChange({
        previous: { ...previous, workers: 5 },
        selection: { ...previous, voiceID: "other-voice" },
        catalog,
        workersEdited: false,
      }),
    ).toBe(5);
  });

  it("still enforces the maximum when the new model has no recommendation", () => {
    const withoutRecommendation: TTSCatalog = {
      ...catalog,
      models: catalog.models.map(({ recommendedAudiobookWorkers, ...model }) => {
        void recommendedAudiobookWorkers;
        return model;
      }),
    };
    expect(
      workersAfterSelectionChange({
        previous: { ...previous, workers: 6 },
        selection: expressive,
        catalog: withoutRecommendation,
        workersEdited: false,
      }),
    ).toBe(1);
  });

  it("clamps remembered expressive workers even when only the voice changes", () => {
    expect(
      workersAfterSelectionChange({
        previous: { ...expressive, bitrateKbps: 64, workers: 8,
          unitGranularityID: "paragraph", announceTitles: true,
          paragraphPauseSeconds: 0.6, chapterPauseSeconds: 1.75 },
        selection: { ...expressive, voiceID: "en-US-G" },
        catalog,
        workersEdited: true,
      }),
    ).toBe(1);
  });
});

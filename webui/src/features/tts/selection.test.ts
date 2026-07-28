import { describe, expect, it } from "vitest";
import type { TTSCatalog } from "../../api/types";
import {
  normalizeTTSSelection,
  publicModelID,
  uniqueTTSModels,
  voicesForModel,
} from "./selection";

const catalog: TTSCatalog = {
  models: [
    {
      id: "tts-1",
      backendID: "siri",
      modelID: "siri-private",
      name: "Siri",
      defaultVoiceID: "siri-a",
      supportsPace: false,
      supportsExpressivity: false,
    },
    {
      id: "tts-1-hd",
      backendID: "siri",
      modelID: "siri-private",
      name: "Siri",
      defaultVoiceID: "siri-a",
      supportsPace: false,
      supportsExpressivity: false,
    },
    {
      id: "siri-expressive",
      backendID: "siri-fm",
      modelID: "siri-expressive",
      name: "Siri Expressive",
      defaultVoiceID: "expressive-a",
      supportsPace: true,
      supportsExpressivity: true,
    },
  ],
  voices: [
    {
      id: "siri-a",
      name: "Siri A",
      lang: "en-US",
      quality: "premium",
      backend: "siri",
      model: "siri-private",
    },
    {
      id: "expressive-a",
      name: "Expressive A",
      lang: "en-US",
      quality: "premium",
      backend: "siri-fm",
      model: "siri-expressive",
      supportsPace: true,
      supportsExpressivity: true,
    },
  ],
  defaultModelID: "siri-expressive",
  defaultVoiceID: "expressive-a",
};

describe("TTS selection normalization", () => {
  it("uses the catalog default and neutral supported presets", () => {
    expect(normalizeTTSSelection(catalog, null)).toEqual({
      backendID: "siri-fm",
      modelID: "siri-expressive",
      voiceID: "expressive-a",
      pacePreset: 3,
      expressivityPreset: 3,
    });
  });

  it("honors configured expressive defaults", () => {
    expect(
      normalizeTTSSelection(
        { ...catalog, defaultPacePreset: 2, defaultExpressivityPreset: 5 },
        null,
      ),
    ).toMatchObject({ pacePreset: 2, expressivityPreset: 5 });
  });

  it("preserves a compatible selection and clears unsupported controls", () => {
    expect(
      normalizeTTSSelection(catalog, {
        backendID: "siri",
        modelID: "siri-private",
        voiceID: "siri-a",
        pacePreset: 1,
        expressivityPreset: 5,
      }),
    ).toEqual({
      backendID: "siri",
      modelID: "siri-private",
      voiceID: "siri-a",
      pacePreset: null,
      expressivityPreset: null,
    });
  });

  it("falls back from stale identities and invalid presets", () => {
    expect(
      normalizeTTSSelection(catalog, {
        backendID: "missing",
        modelID: "missing",
        voiceID: "missing",
        pacePreset: 8,
        expressivityPreset: 0,
      }),
    ).toEqual({
      backendID: "siri-fm",
      modelID: "siri-expressive",
      voiceID: "expressive-a",
      pacePreset: 3,
      expressivityPreset: 3,
    });
  });

  it("deduplicates public aliases and maps durable identities back to a public model", () => {
    expect(uniqueTTSModels(catalog)).toHaveLength(2);
    const siri = normalizeTTSSelection(catalog, {
      backendID: "siri",
      modelID: "siri-private",
      voiceID: "siri-a",
    });
    expect(publicModelID(catalog, siri)).toBe("tts-1");
  });

  it("filters voices by backend and model", () => {
    expect(voicesForModel(catalog, catalog.models[2])).toEqual([catalog.voices[1]]);
  });
});

import { describe, expect, it, vi } from "vitest";
import type { TTSCatalog, TTSSelection } from "../../api/types";
import {
  buildSpeechTestRequest,
  countGraphemes,
  requestSpeechTestAudio,
  verifySpeechTestAudio,
} from "./speechTest";

const catalog: TTSCatalog = {
  models: [
    {
      id: "siri-expressive",
      backendID: "siri-fm",
      modelID: "siri-expressive",
      name: "Siri Expressive",
      defaultVoiceID: "en-US-F",
      supportsPace: true,
      supportsExpressivity: true,
    },
  ],
  voices: [],
  defaultModelID: "siri-expressive",
  defaultVoiceID: "en-US-F",
};

const selection: TTSSelection = {
  backendID: "siri-fm",
  modelID: "siri-expressive",
  voiceID: "en-US-F",
  pacePreset: 2,
  expressivityPreset: 5,
};

describe("speech test helpers", () => {
  it("builds the OpenAI-compatible request with expressive controls", () => {
    expect(buildSpeechTestRequest(catalog, selection, "Hello.", "opus")).toEqual({
      model: "siri-expressive",
      input: "Hello.",
      voice: "en-US-F",
      response_format: "opus",
      speed: 1,
      pace: 2,
      expressivity: 5,
    });
  });

  it("rejects blank and oversized input before fetching", () => {
    expect(() => buildSpeechTestRequest(catalog, selection, "   ", "aac")).toThrow(
      "Enter text",
    );
    expect(() => buildSpeechTestRequest(catalog, selection, "x".repeat(4097), "aac")).toThrow(
      "4,096",
    );
    const family = "👨‍👩‍👧‍👦";
    expect(countGraphemes(family)).toBe(1);
    expect(() =>
      buildSpeechTestRequest(catalog, selection, family.repeat(4096), "aac"),
    ).not.toThrow();
  });

  it("posts same-origin and accepts a nonempty matching audio blob", async () => {
    const fetcher = vi.fn(async (_input: RequestInfo | URL, _init?: RequestInit) =>
      new Response(new Uint8Array([1, 2, 3]), {
        status: 200,
        headers: { "Content-Type": "audio/mp4; codecs=mp4a.40.2" },
      }),
    );

    const blob = await requestSpeechTestAudio(catalog, selection, "Hello.", "aac", {
      fetcher,
      decoder: async () => ({ length: 2400, numberOfChannels: 1, sampleRate: 48_000 }),
    });
    expect(blob.size).toBe(3);
    expect(fetcher).toHaveBeenCalledOnce();
    expect(fetcher.mock.calls[0]?.[0]).toBe("/v1/audio/speech");
    const init = fetcher.mock.calls[0]?.[1];
    expect(JSON.parse(String(init?.body))).toMatchObject({
      response_format: "aac",
      voice: "en-US-F",
      pace: 2,
      expressivity: 5,
    });
  });

  it("rejects wrong MIME types and empty blobs", async () => {
    await expect(
      requestSpeechTestAudio(
        catalog,
        selection,
        "Hello.",
        "opus",
        {
          fetcher: async () =>
            new Response(new Uint8Array([1]), {
              status: 200,
              headers: { "Content-Type": "audio/wav" },
            }),
        },
      ),
    ).rejects.toThrow("Expected audio/ogg");

    await expect(
      requestSpeechTestAudio(
        catalog,
        selection,
        "Hello.",
        "aac",
        {
          fetcher: async () =>
            new Response(new Uint8Array(), {
              status: 200,
              headers: { "Content-Type": "audio/mp4" },
            }),
        },
      ),
    ).rejects.toThrow("empty");
  });

  it("rejects undecodable, non-mono, and non-48-kHz audio", async () => {
    const blob = new Blob([new Uint8Array([1, 2, 3])], { type: "audio/ogg" });
    await expect(
      verifySpeechTestAudio(blob, "opus", async () => {
        throw new Error("unsupported codec");
      }),
    ).rejects.toThrow("could not decode");
    await expect(
      verifySpeechTestAudio(blob, "opus", async () => ({
        length: 100,
        numberOfChannels: 2,
        sampleRate: 48_000,
      })),
    ).rejects.toThrow("expected mono");
    await expect(
      verifySpeechTestAudio(blob, "opus", async () => ({
        length: 100,
        numberOfChannels: 1,
        sampleRate: 44_100,
      })),
    ).rejects.toThrow("expected 48,000 Hz");
  });
});

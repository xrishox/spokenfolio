import { describe, expect, it } from "vitest";
import { buildQueuePayload, type QueuePayloadInput } from "./processPayload";

const base: QueuePayloadInput = {
  rowIDs: ["row-1", "row-2"],
  toggles: {
    createMissingAudiobooks: true,
    recreateExistingAudiobooks: false,
    createMissingReadAlouds: true,
    recreateExistingReadAlouds: false,
    sendToStoryteller: true,
    deliveryConnectionID: "conn-1",
    sendEPUB: true,
    sendM4B: true,
    sendReadAloud: true,
  },
  confirmedRemoteBookID: null,
  backendID: "siri-fm",
  modelID: "siri-expressive",
  voiceID: "voice-1",
  pacePreset: 2,
  expressivityPreset: 5,
  bitrateKbps: 256,
  workers: 4,
  unitGranularityID: "sentence",
  announceTitles: true,
  paragraphPauseSeconds: 0.6,
  chapterPauseSeconds: 1.75,
  readAloudBitrateKbps: 32,
  readAloudASREngineID: "synthesis",
  readAloudASRModelID: null,
  assertNarration: "spokenFolioTTS",
  replacements: [],
  replaceAcknowledged: false,
};

const parse = (input: QueuePayloadInput) =>
  JSON.parse(buildQueuePayload(input)) as Record<string, unknown>;

describe("buildQueuePayload", () => {
  it("includes rowIDs, toggles, and settings", () => {
    const body = parse(base);
    expect(body.rowIDs).toEqual(["row-1", "row-2"]);
    expect(body.sendToStoryteller).toBe(true);
    expect(body.deliveryConnectionID).toBe("conn-1");
    expect(body.backendID).toBe("siri-fm");
    expect(body.modelID).toBe("siri-expressive");
    expect(body.voiceID).toBe("voice-1");
    expect(body.pacePreset).toBe(2);
    expect(body.expressivityPreset).toBe(5);
    expect(body.bitrateKbps).toBe(256);
    expect(body.workers).toBe(4);
    expect(body.unitGranularityID).toBe("sentence");
    expect(body.announceTitles).toBe(true);
    expect(body.paragraphPauseSeconds).toBe(0.6);
    expect(body.chapterPauseSeconds).toBe(1.75);
    expect(body.readAloudASREngineID).toBe("synthesis");
    expect(body.confirmedRemoteBookID).toBeNull();
  });

  it("forces exact synthesis timing even if stale UI state contains ASR", () => {
    const body = parse({
      ...base,
      readAloudASREngineID: "whisper",
      readAloudASRModelID: "large-v3-turbo",
    });
    expect(body.readAloudASREngineID).toBe("synthesis");
    expect(body.readAloudASRModelID).toBeNull();
  });

  it("sends assertNarration only when sendReadAloud is on", () => {
    expect(parse({ ...base, assertNarration: "human" }).assertNarration).toBe("human");
    const withoutReadAloud = parse({
      ...base,
      toggles: { ...base.toggles, sendReadAloud: false },
    });
    expect("assertNarration" in withoutReadAloud).toBe(false);
  });

  it("sends replaceAcknowledgedRowIDs only when acknowledged", () => {
    const replacements = [
      {
        rowID: "row-1",
        title: "A Book",
        remoteNarration: "human",
        losesHumanAudio: true,
        assets: [
          {
            format: "audiobook",
            disposition: "lostForever" as const,
            humanNarration: true,
            size: 1024,
          },
        ],
      },
    ];
    const unacknowledged = parse({ ...base, replacements });
    expect("replaceAcknowledgedRowIDs" in unacknowledged).toBe(false);

    const acknowledged = parse({
      ...base,
      replacements,
      replaceAcknowledged: true,
    });
    expect(acknowledged.replaceAcknowledgedRowIDs).toEqual(["row-1"]);
  });

  it("omits replaceAcknowledgedRowIDs when there are no replacements", () => {
    const body = parse({ ...base, replaceAcknowledged: true });
    expect("replaceAcknowledgedRowIDs" in body).toBe(false);
  });
});

import type { APIErrorEnvelope, TTSCatalog, TTSSelection } from "../../api/types";
import { publicModelID } from "../tts/selection";

export type SpeechTestFormat = "opus" | "aac";

type Fetcher = (input: RequestInfo | URL, init?: RequestInit) => Promise<Response>;

type DecodedAudio = Pick<AudioBuffer, "length" | "numberOfChannels" | "sampleRate">;
type AudioDecoder = (data: ArrayBuffer) => Promise<DecodedAudio>;

export interface SpeechTestDependencies {
  fetcher?: Fetcher;
  decoder?: AudioDecoder;
}

export interface SpeechTestRequest {
  model: string;
  input: string;
  voice: string;
  response_format: SpeechTestFormat;
  speed: number;
  pace?: number;
  expressivity?: number;
}

const EXPECTED_MIME: Record<SpeechTestFormat, string> = {
  opus: "audio/ogg",
  aac: "audio/mp4",
};

export function countGraphemes(input: string): number {
  if (typeof Intl.Segmenter === "function") {
    return [...new Intl.Segmenter(undefined, { granularity: "grapheme" }).segment(input)].length;
  }
  // Older browsers lack Segmenter. Code-point counting is still closer to
  // Swift String.count than UTF-16 .length and never splits surrogate pairs.
  return Array.from(input).length;
}

export function buildSpeechTestRequest(
  catalog: TTSCatalog,
  selection: TTSSelection,
  input: string,
  format: SpeechTestFormat,
): SpeechTestRequest {
  if (!input.trim()) throw new Error("Enter text to synthesize.");
  if (countGraphemes(input) > 4096) {
    throw new Error("Test text must be 4,096 characters or fewer.");
  }
  if (!selection.voiceID) throw new Error("Select an available TTS voice.");

  return {
    model: publicModelID(catalog, selection),
    input,
    voice: selection.voiceID,
    response_format: format,
    speed: 1,
    ...(selection.pacePreset == null ? {} : { pace: selection.pacePreset }),
    ...(selection.expressivityPreset == null
      ? {}
      : { expressivity: selection.expressivityPreset }),
  };
}

async function decodeWithWebAudio(data: ArrayBuffer): Promise<DecodedAudio> {
  const AudioContextConstructor = globalThis.AudioContext;
  if (!AudioContextConstructor) {
    throw new Error("This browser cannot decode synthesized audio with Web Audio.");
  }
  const context = new AudioContextConstructor({ sampleRate: 48_000 });
  try {
    return await context.decodeAudioData(data.slice(0));
  } finally {
    await context.close();
  }
}

export async function verifySpeechTestAudio(
  blob: Blob,
  format: SpeechTestFormat,
  decoder: AudioDecoder = decodeWithWebAudio,
): Promise<void> {
  let decoded: DecodedAudio;
  try {
    decoded = await decoder(await blob.arrayBuffer());
  } catch (error) {
    const reason = error instanceof Error ? error.message : "unknown decoder failure";
    throw new Error(`The browser could not decode the ${format.toUpperCase()} response: ${reason}`);
  }
  if (decoded.length <= 0) {
    throw new Error(`The decoded ${format.toUpperCase()} response has no audio frames.`);
  }
  if (decoded.numberOfChannels !== 1) {
    throw new Error(
      `The decoded ${format.toUpperCase()} response has ${decoded.numberOfChannels} channels; expected mono.`,
    );
  }
  if (decoded.sampleRate !== 48_000) {
    throw new Error(
      `The decoded ${format.toUpperCase()} response is ${decoded.sampleRate} Hz; expected 48,000 Hz.`,
    );
  }
}

async function responseError(response: Response): Promise<Error> {
  try {
    const envelope = (await response.json()) as APIErrorEnvelope;
    if (envelope.error?.message) return new Error(envelope.error.message);
  } catch {
    // Keep the HTTP status below for non-JSON failures.
  }
  return new Error(`${response.status} ${response.statusText}`);
}

export async function requestSpeechTestAudio(
  catalog: TTSCatalog,
  selection: TTSSelection,
  input: string,
  format: SpeechTestFormat,
  dependencies: SpeechTestDependencies = {},
): Promise<Blob> {
  const fetcher = dependencies.fetcher ?? fetch;
  const response = await fetcher("/v1/audio/speech", {
    method: "POST",
    headers: {
      Accept: EXPECTED_MIME[format],
      "Content-Type": "application/json",
    },
    body: JSON.stringify(buildSpeechTestRequest(catalog, selection, input, format)),
  });
  if (!response.ok) throw await responseError(response);

  const expected = EXPECTED_MIME[format];
  const contentType = response.headers.get("Content-Type")?.toLowerCase() ?? "";
  if (contentType.split(";", 1)[0]?.trim() !== expected) {
    throw new Error(`Expected ${expected} but the server returned ${contentType || "no MIME type"}.`);
  }

  const blob = await response.blob();
  if (blob.size === 0) throw new Error(`The ${format.toUpperCase()} response was empty.`);
  if (blob.type && blob.type.toLowerCase().split(";", 1)[0]?.trim() !== expected) {
    throw new Error(`The ${format.toUpperCase()} blob has unexpected type ${blob.type}.`);
  }
  await verifySpeechTestAudio(blob, format, dependencies.decoder);
  return blob;
}

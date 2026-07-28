import type { TTSCatalog, TTSModel, TTSSelection, TTSVoice } from "../../api/types";

export const emptyTTSSelection: TTSSelection = {
  backendID: "",
  modelID: "",
  voiceID: "",
  pacePreset: null,
  expressivityPreset: null,
};

const validPreset = (value: number | null | undefined): value is number =>
  Number.isInteger(value) && value != null && value >= 1 && value <= 5;

export function modelKey(model: Pick<TTSModel, "backendID" | "modelID">): string {
  return JSON.stringify([model.backendID, model.modelID]);
}

export function uniqueTTSModels(catalog: TTSCatalog | undefined): TTSModel[] {
  if (!catalog) return [];
  const seen = new Set<string>();
  return catalog.models.filter((model) => {
    const key = modelKey(model);
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

export function voicesForModel(
  catalog: TTSCatalog | undefined,
  model: Pick<TTSModel, "backendID" | "modelID"> | undefined,
): TTSVoice[] {
  if (!catalog || !model) return [];
  // Production selection is qualified only: an unqualified voice cannot be
  // attributed to a backend/model pair, and guessing one would queue a job
  // against a voice the server never resolved.
  return catalog.voices.filter(
    (voice) => voice.backend === model.backendID && voice.model === model.modelID,
  );
}

function defaultModel(catalog: TTSCatalog): TTSModel | undefined {
  return catalog.models.find((model) => model.id === catalog.defaultModelID) ?? catalog.models[0];
}

export function normalizeTTSSelection(
  catalog: TTSCatalog | undefined,
  requested: Partial<TTSSelection> | null | undefined,
): TTSSelection {
  if (!catalog || catalog.models.length === 0) {
    return {
      backendID: requested?.backendID ?? "",
      modelID: requested?.modelID ?? "",
      voiceID: requested?.voiceID ?? "",
      pacePreset: validPreset(requested?.pacePreset) ? requested.pacePreset : null,
      expressivityPreset: validPreset(requested?.expressivityPreset)
        ? requested.expressivityPreset
        : null,
    };
  }

  const model =
    catalog.models.find(
      (candidate) =>
        candidate.backendID === requested?.backendID && candidate.modelID === requested?.modelID,
    ) ?? defaultModel(catalog)!;
  const voices = voicesForModel(catalog, model);
  const voice =
    voices.find((candidate) => candidate.id === requested?.voiceID) ??
    voices.find((candidate) => candidate.id === model.defaultVoiceID) ??
    voices.find((candidate) => candidate.id === catalog.defaultVoiceID) ??
    voices[0];

  return {
    backendID: model.backendID,
    modelID: model.modelID,
    voiceID: voice?.id ?? model.defaultVoiceID,
    pacePreset: model.supportsPace
      ? validPreset(requested?.pacePreset)
        ? requested.pacePreset
        : validPreset(catalog.defaultPacePreset)
          ? catalog.defaultPacePreset
          : 3
      : null,
    expressivityPreset: model.supportsExpressivity
      ? validPreset(requested?.expressivityPreset)
        ? requested.expressivityPreset
        : validPreset(catalog.defaultExpressivityPreset)
          ? catalog.defaultExpressivityPreset
          : 3
      : null,
  };
}

/** Maps a durable backend/model pair back to the public model expected by the
 * OpenAI-compatible speech endpoint. Prefer the configured public default
 * when aliases such as tts-1 and tts-1-hd share one backend model. */
export function publicModelID(catalog: TTSCatalog, selection: TTSSelection): string {
  const matching = catalog.models.filter(
    (model) =>
      model.backendID === selection.backendID && model.modelID === selection.modelID,
  );
  return (
    matching.find((model) => model.id === catalog.defaultModelID)?.id ??
    matching[0]?.id ??
    catalog.defaultModelID
  );
}

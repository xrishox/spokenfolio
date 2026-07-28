import type { TTSCatalog, TTSModel, TTSSelection } from "../../api/types";
import {
  modelKey,
  normalizeTTSSelection,
  uniqueTTSModels,
  voicesForModel,
} from "./selection";
import styles from "./TTSSelectionFields.module.css";

const PRESETS = [1, 2, 3, 4, 5] as const;

function decodeModel(value: string, models: TTSModel[]): TTSModel | undefined {
  return models.find((model) => modelKey(model) === value);
}

export function TTSSelectionFields({
  catalog,
  value,
  onChange,
  onModelChange,
  disabled = false,
}: {
  catalog: TTSCatalog | undefined;
  value: TTSSelection;
  onChange: (next: TTSSelection) => void;
  onModelChange?: (model: TTSModel) => void;
  disabled?: boolean;
}) {
  const models = uniqueTTSModels(catalog);
  const normalized = normalizeTTSSelection(catalog, value);
  const selectedModel = models.find(
    (model) =>
      model.backendID === normalized.backendID && model.modelID === normalized.modelID,
  );
  const voices = voicesForModel(catalog, selectedModel);
  const unavailable = disabled || models.length === 0;

  const setPreset = (key: "pacePreset" | "expressivityPreset", rawValue: string) => {
    onChange({ ...normalized, [key]: Number(rawValue) });
  };

  return (
    <div className={styles.fields}>
      <label className={styles.field}>
        <span>TTS model</span>
        <select
          value={selectedModel ? modelKey(selectedModel) : ""}
          disabled={unavailable}
          onChange={(event) => {
            const model = decodeModel(event.target.value, models);
            if (model) {
              onChange(normalizeTTSSelection(catalog, model));
              onModelChange?.(model);
            }
          }}
        >
          {models.length === 0 && <option value="">No TTS models available</option>}
          {models.map((model) => (
            <option key={modelKey(model)} value={modelKey(model)}>
              {model.name} — {model.backendID}/{model.modelID}
            </option>
          ))}
        </select>
      </label>

      <label className={styles.field}>
        <span>Voice</span>
        <select
          value={normalized.voiceID}
          disabled={unavailable || voices.length === 0}
          onChange={(event) => onChange({ ...normalized, voiceID: event.target.value })}
        >
          {voices.length === 0 && <option value="">No voices available</option>}
          {voices.map((voice) => (
            <option key={voice.id} value={voice.id}>
              {voice.name} — {voice.lang}
            </option>
          ))}
        </select>
      </label>

      {selectedModel?.supportsPace && (
        <label className={styles.field}>
          <span>Pace</span>
          <div className={styles.sliderRow}>
            <input
              type="range"
              min={PRESETS[0]}
              max={PRESETS[PRESETS.length - 1]}
              step={1}
              value={normalized.pacePreset ?? 3}
              disabled={disabled}
              aria-label="Pace preset"
              aria-valuetext={`${normalized.pacePreset ?? 3} of 5`}
              onChange={(event) => setPreset("pacePreset", event.target.value)}
            />
            <output>{normalized.pacePreset ?? 3} of 5</output>
          </div>
        </label>
      )}

      {selectedModel?.supportsExpressivity && (
        <label className={styles.field}>
          <span>Expressivity</span>
          <div className={styles.sliderRow}>
            <input
              type="range"
              min={PRESETS[0]}
              max={PRESETS[PRESETS.length - 1]}
              step={1}
              value={normalized.expressivityPreset ?? 3}
              disabled={disabled}
              aria-label="Expressivity preset"
              aria-valuetext={`${normalized.expressivityPreset ?? 3} of 5`}
              onChange={(event) => setPreset("expressivityPreset", event.target.value)}
            />
            <output>{normalized.expressivityPreset ?? 3} of 5</output>
          </div>
        </label>
      )}
    </div>
  );
}

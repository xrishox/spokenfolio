import type { ReadAloudEngineID, ReadAloudSettings } from "../../api/types";
import styles from "./ProductionFields.module.css";

const OPUS_BITRATES = [16, 32, 64, 96];

const ENGINES: [ReadAloudEngineID, string][] = [
  ["synthesis", "Exact (no ASR)"],
  ["apple", "Apple Speech"],
  ["whisper", "Whisper"],
];

const WHISPER_MODELS = ["tiny", "base", "small", "medium", "large-v3", "large-v3-turbo"];

/** The ReadAloud controls, shared by Create and the Library's Process sheet —
 *  mirrors ReadAloudSettingsFields in ProcessingSettingsSections.swift.
 *  Exact synthesis timing (the default) uses the audiobook's digest-bound
 *  timeline sidecar and runs no speech recognition. */
export function ReadAloudSettingsFields({
  value,
  onChange,
}: {
  value: ReadAloudSettings;
  onChange: (next: ReadAloudSettings) => void;
}) {
  return (
    <>
      <label className={styles.field}>
        <span>Opus bitrate</span>
        <div className={styles.segmented} role="radiogroup" aria-label="Opus bitrate">
          {OPUS_BITRATES.map((rate) => (
            <button
              key={rate}
              role="radio"
              aria-checked={value.readAloudBitrateKbps === rate}
              data-active={value.readAloudBitrateKbps === rate || undefined}
              onClick={() => onChange({ ...value, readAloudBitrateKbps: rate })}
            >
              {rate}
            </button>
          ))}
        </div>
      </label>

      <label className={styles.field}>
        <span>Alignment transcript</span>
        <div className={styles.segmented} role="radiogroup" aria-label="Alignment transcript">
          {ENGINES.map(([engine, label]) => (
            <button
              key={engine}
              role="radio"
              aria-checked={value.readAloudASREngineID === engine}
              data-active={value.readAloudASREngineID === engine || undefined}
              onClick={() =>
                onChange({
                  ...value,
                  readAloudASREngineID: engine,
                  readAloudASRModelID:
                    engine === "whisper"
                      ? (value.readAloudASRModelID ?? "large-v3-turbo")
                      : null,
                })
              }
            >
              {label}
            </button>
          ))}
        </div>
      </label>

      {value.readAloudASREngineID === "whisper" && (
        <label className={styles.field}>
          <span>Whisper model</span>
          <select
            value={value.readAloudASRModelID ?? "large-v3-turbo"}
            onChange={(event) =>
              onChange({ ...value, readAloudASRModelID: event.target.value })
            }
          >
            {WHISPER_MODELS.map((model) => (
              <option key={model} value={model}>
                {model}
              </option>
            ))}
          </select>
        </label>
      )}

      <p className={styles.hintBlock}>
        Exact uses the audiobook's own synthesis timing (no speech recognition);
        Apple and Whisper transcribe the audio instead — needed when aligning
        audio not synthesized by this app.
      </p>
    </>
  );
}

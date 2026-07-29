import type { ReadAloudSettings } from "../../api/types";
import styles from "./ProductionFields.module.css";

const OPUS_BITRATES = [16, 32, 64, 96];

/** The ReadAloud controls, shared by Create and the Library's Process sheet —
 *  mirrors ReadAloudSettingsFields in ProcessingSettingsSections.swift.
 *  production consumes exact sentence timings from the audiobook's
 *  digest-bound synthesis timeline and runs no speech recognition. */
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

      <p className={styles.hintBlock}>
        Timing: exact sentence synthesis. SpokenFolio uses the TTS timeline
        directly; production runs no speech recognition.
      </p>
    </>
  );
}

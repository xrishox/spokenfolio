import { useState } from "react";
import type { AudiobookSettings, TTSCatalog, TTSSelection } from "../../api/types";
import { TTSSelectionFields } from "../tts/TTSSelectionFields";
import { workersAfterSelectionChange } from "./workerRecommendation";
import styles from "./ProductionFields.module.css";

const BITRATES = [32, 64, 128, 256];

/** Mirrors AudiobookConfig.maximumWorkers: the measured plateau, above which
 *  throughput falls rather than rises. */
export const MAXIMUM_WORKERS = 8;

/** The audiobook-synthesis controls, shared by Create and the Library's
 *  Process sheet — mirrors AudiobookSettingsFields in
 *  ProcessingSettingsSections.swift so the two UIs cannot drift. */
export function AudiobookSettingsFields({
  catalog,
  value,
  onChange,
  announceTitlesLocked = false,
  workersUserSet = false,
}: {
  catalog: TTSCatalog | undefined;
  value: AudiobookSettings;
  onChange: (next: AudiobookSettings) => void;
  /** Announcements cannot be synthesized for ReadAloud-bearing jobs. */
  announceTitlesLocked?: boolean;
  /** True when the count was remembered from the user's last queued book,
   *  which counts as user-set. */
  workersUserSet?: boolean;
}) {
  // A model's measured recommendation is a starting point, not an override:
  // once the user sets a worker count it survives every later model change.
  const [workersEdited, setWorkersEdited] = useState(false);
  const set = (patch: Partial<AudiobookSettings>) => onChange({ ...value, ...patch });
  const maximumWorkers =
    catalog?.models.find(
      (model) => model.backendID === value.backendID && model.modelID === value.modelID,
    )?.maximumAudiobookWorkers ?? MAXIMUM_WORKERS;

  const selectModel = (selection: TTSSelection) => {
    onChange({
      ...value,
      ...selection,
      workers: workersAfterSelectionChange({
        previous: value,
        selection,
        catalog,
        workersEdited: workersEdited || workersUserSet,
      }),
    });
  };

  return (
    <>
      <TTSSelectionFields catalog={catalog} value={value} onChange={selectModel} />

      <label className={styles.field}>
        <span>AAC bitrate</span>
        <div className={styles.segmented} role="radiogroup" aria-label="AAC bitrate">
          {BITRATES.map((rate) => (
            <button
              key={rate}
              role="radio"
              aria-checked={value.bitrateKbps === rate}
              data-active={value.bitrateKbps === rate || undefined}
              onClick={() => set({ bitrateKbps: rate })}
            >
              {rate}
            </button>
          ))}
        </div>
      </label>

      <label className={styles.field}>
        <span>Synthesis workers</span>
        <input
          type="number"
          min={1}
          max={maximumWorkers}
          value={value.workers}
          onChange={(event) => {
            setWorkersEdited(true);
            set({
              workers: Math.min(maximumWorkers, Math.max(1, Number(event.target.value) || 1)),
            });
          }}
        />
        {maximumWorkers === 1 && (
          <em className={styles.hint}>
            Siri Expressive production is fixed at one worker for reliability.
          </em>
        )}
      </label>

      <label className={styles.fieldRow}>
        <input
          type="checkbox"
          checked={announceTitlesLocked ? false : value.announceTitles}
          disabled={announceTitlesLocked}
          onChange={(event) => set({ announceTitles: event.target.checked })}
        />
        <span>
          Announce chapter titles
          {announceTitlesLocked && (
            <em className={styles.hint}> (off with ReadAloud — unalignable words)</em>
          )}
        </span>
      </label>

      <label className={styles.field}>
        <span>Paragraph pause</span>
        <input
          type="number"
          min={0}
          max={10}
          step={0.05}
          value={value.paragraphPauseSeconds}
          onChange={(event) =>
            set({ paragraphPauseSeconds: Number(event.target.value) || 0 })
          }
        />
      </label>

      <label className={styles.field}>
        <span>Chapter pause</span>
        <input
          type="number"
          min={0}
          max={10}
          step={0.05}
          value={value.chapterPauseSeconds}
          onChange={(event) =>
            set({ chapterPauseSeconds: Number(event.target.value) || 0 })
          }
        />
      </label>
    </>
  );
}

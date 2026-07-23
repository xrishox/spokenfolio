import type { AudiobookVoices, DraftProcessSettings } from "../../api/types";
import styles from "./SettingsFields.module.css";

const WHISPER_MODELS = [
  "tiny",
  "base",
  "small",
  "medium",
  "large-v3",
  "large-v3-turbo",
];

/** The audiobook + ReadAloud settings fields, shared by the Create
 *  inspector and the Library process flow — mirrors
 *  ProcessingSettingsSections.swift so the two UIs cannot drift. */
export function SettingsFields({
  value,
  onChange,
  voices,
  connections,
}: {
  value: DraftProcessSettings;
  onChange: (next: DraftProcessSettings) => void;
  voices: AudiobookVoices | undefined;
  connections: { id: string; label: string }[];
}) {
  const set = (patch: Partial<DraftProcessSettings>) => onChange({ ...value, ...patch });

  return (
    <div className={styles.fields}>
      <label className={styles.field}>
        <span>Siri voice</span>
        <select
          value={value.voiceID}
          onChange={(event) => set({ voiceID: event.target.value })}
        >
          {(voices?.voices ?? []).map((voice) => (
            <option key={voice.id} value={voice.id}>
              {voice.name} — {voice.language}
            </option>
          ))}
        </select>
      </label>

      <label className={styles.field}>
        <span>AAC bitrate</span>
        <div className={styles.segmented} role="radiogroup" aria-label="AAC bitrate">
          {[32, 64, 128, 256].map((rate) => (
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
        <span>Workers</span>
        <input
          type="number"
          min={1}
          max={16}
          value={value.workers}
          onChange={(event) =>
            set({ workers: Math.min(16, Math.max(1, Number(event.target.value) || 1)) })
          }
        />
      </label>

      <label className={styles.fieldRow}>
        <input
          type="checkbox"
          checked={value.createReadAloud ? false : value.announceTitles}
          disabled={value.createReadAloud}
          onChange={(event) => set({ announceTitles: event.target.checked })}
        />
        <span>
          Announce chapter titles
          {value.createReadAloud && (
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
          onChange={(event) => set({ paragraphPauseSeconds: Number(event.target.value) || 0 })}
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
          onChange={(event) => set({ chapterPauseSeconds: Number(event.target.value) || 0 })}
        />
      </label>

      <label className={styles.fieldRow}>
        <input
          type="checkbox"
          checked={value.createReadAloud}
          onChange={(event) => set({ createReadAloud: event.target.checked })}
        />
        <span>Create synchronized ReadAloud EPUB</span>
      </label>

      {value.createReadAloud && (
        <>
          <label className={styles.field}>
            <span>Opus bitrate</span>
            <div className={styles.segmented} role="radiogroup" aria-label="Opus bitrate">
              {[16, 32, 64, 96].map((rate) => (
                <button
                  key={rate}
                  role="radio"
                  aria-checked={value.readAloudBitrateKbps === rate}
                  data-active={value.readAloudBitrateKbps === rate || undefined}
                  onClick={() => set({ readAloudBitrateKbps: rate })}
                >
                  {rate}
                </button>
              ))}
            </div>
          </label>
          <label className={styles.field}>
            <span>Alignment transcript</span>
            <div className={styles.segmented} role="radiogroup" aria-label="Alignment transcript">
              {(
                [
                  ["synthesis", "Exact (no ASR)"],
                  ["apple", "Apple Speech"],
                  ["whisper", "Whisper"],
                ] as const
              ).map(([engine, label]) => (
                <button
                  key={engine}
                  role="radio"
                  aria-checked={value.readAloudASREngineID === engine}
                  data-active={value.readAloudASREngineID === engine || undefined}
                  onClick={() =>
                    set({
                      readAloudASREngineID: engine,
                      readAloudASRModelID: engine === "whisper" ? "large-v3-turbo" : null,
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
                onChange={(event) => set({ readAloudASRModelID: event.target.value })}
              >
                {WHISPER_MODELS.map((model) => (
                  <option key={model} value={model}>
                    {model}
                  </option>
                ))}
              </select>
            </label>
          )}
        </>
      )}

      {connections.length > 0 && (
        <>
          <label className={styles.fieldRow}>
            <input
              type="checkbox"
              checked={value.storytellerConnectionID != null}
              onChange={(event) =>
                set({
                  storytellerConnectionID: event.target.checked
                    ? (connections[0]?.id ?? null)
                    : null,
                })
              }
            />
            <span>Send finished products to Storyteller</span>
          </label>
          {value.storytellerConnectionID != null && (
            <>
              <label className={styles.field}>
                <span>Connection</span>
                <select
                  value={value.storytellerConnectionID}
                  onChange={(event) => set({ storytellerConnectionID: event.target.value })}
                >
                  {connections.map((connection) => (
                    <option key={connection.id} value={connection.id}>
                      {connection.label}
                    </option>
                  ))}
                </select>
              </label>
              <label className={styles.fieldRow}>
                <input
                  type="checkbox"
                  checked={value.sendSourceEPUB}
                  onChange={(event) => set({ sendSourceEPUB: event.target.checked })}
                />
                <span>Source EPUB</span>
              </label>
              <label className={styles.fieldRow}>
                <input
                  type="checkbox"
                  checked={value.sendM4B}
                  onChange={(event) => set({ sendM4B: event.target.checked })}
                />
                <span>AAC audiobook</span>
              </label>
              <label className={styles.fieldRow}>
                <input
                  type="checkbox"
                  checked={value.sendReadAloud && value.createReadAloud}
                  disabled={!value.createReadAloud}
                  onChange={(event) => set({ sendReadAloud: event.target.checked })}
                />
                <span>ReadAloud EPUB</span>
              </label>
            </>
          )}
        </>
      )}
    </div>
  );
}

export function defaultSettings(voices: AudiobookVoices | undefined): DraftProcessSettings {
  return {
    voiceID: voices?.defaultVoiceID ?? "",
    bitrateKbps: 256,
    workers: 4,
    announceTitles: true,
    paragraphPauseSeconds: 0.6,
    chapterPauseSeconds: 1.75,
    createReadAloud: false,
    readAloudBitrateKbps: 32,
    readAloudASREngineID: "synthesis",
    readAloudASRModelID: null,
    storytellerConnectionID: null,
    sendSourceEPUB: false,
    sendM4B: false,
    sendReadAloud: false,
    outputDirectory: null,
    reprocessAudiobook: false,
  };
}

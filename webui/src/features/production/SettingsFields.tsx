import type {
  DraftProcessSettings,
  StorytellerConnectionSummary,
  TTSCatalog,
} from "../../api/types";
import { AudiobookSettingsFields } from "./AudiobookSettingsFields";
import { ReadAloudSettingsFields } from "./ReadAloudSettingsFields";
import { StorytellerDeliveryFields } from "./StorytellerDeliveryFields";
import styles from "./ProductionFields.module.css";

/** The Create form: the same audiobook, ReadAloud, and delivery field groups
 *  the Library's Process sheet uses, so the two surfaces cannot drift. */
export function SettingsFields({
  value,
  onChange,
  catalog,
  connections,
  workersUserSet = false,
}: {
  value: DraftProcessSettings;
  onChange: (next: DraftProcessSettings) => void;
  catalog: TTSCatalog | undefined;
  connections: StorytellerConnectionSummary[];
  /** True when the worker count was remembered from the last queued book. */
  workersUserSet?: boolean;
}) {
  const set = (patch: Partial<DraftProcessSettings>) => onChange({ ...value, ...patch });

  return (
    <div className={styles.fields}>
      <AudiobookSettingsFields
        catalog={catalog}
        value={value}
        onChange={(audiobook) => onChange({ ...value, ...audiobook })}
        announceTitlesLocked={value.createReadAloud}
        workersUserSet={workersUserSet}
      />

      <label className={styles.fieldRow}>
        <input
          type="checkbox"
          checked={value.createReadAloud}
          onChange={(event) => set({ createReadAloud: event.target.checked })}
        />
        <span>Create synchronized ReadAloud EPUB</span>
      </label>

      {value.createReadAloud && (
        <ReadAloudSettingsFields
          value={value}
          onChange={(readAloud) => onChange({ ...value, ...readAloud })}
        />
      )}

      <StorytellerDeliveryFields
        connections={connections}
        readAloudAvailable={value.createReadAloud}
        value={{
          connectionID: value.storytellerConnectionID,
          sendEPUB: value.sendSourceEPUB,
          sendM4B: value.sendM4B,
          sendReadAloud: value.sendReadAloud,
        }}
        onChange={(delivery) =>
          set({
            storytellerConnectionID: delivery.connectionID,
            sendSourceEPUB: delivery.sendEPUB,
            sendM4B: delivery.sendM4B,
            sendReadAloud: delivery.sendReadAloud,
          })
        }
      />
    </div>
  );
}

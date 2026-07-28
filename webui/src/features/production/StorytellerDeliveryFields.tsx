import type { ReactNode } from "react";
import type { StorytellerConnectionSummary } from "../../api/types";
import styles from "./ProductionFields.module.css";

export interface DeliverySelection {
  connectionID: string | null;
  sendEPUB: boolean;
  sendM4B: boolean;
  sendReadAloud: boolean;
}

/** The Storyteller delivery controls, shared by Create and the Library's
 *  Process sheet — mirrors StorytellerDeliveryFields in
 *  StudioCreateViews.swift. Callers keep their own field names and adapt
 *  through `value`/`onChange`. */
export function StorytellerDeliveryFields({
  connections,
  value,
  onChange,
  readAloudAvailable = true,
  children,
}: {
  connections: StorytellerConnectionSummary[];
  value: DeliverySelection;
  onChange: (next: DeliverySelection) => void;
  /** ReadAloud cannot be sent when the run produces none. */
  readAloudAvailable?: boolean;
  /** Surface-specific extras rendered while delivery is on (narration
   *  assertion, replacement acknowledgment). */
  children?: ReactNode;
}) {
  if (connections.length === 0) {
    return (
      <p className={styles.hintBlock}>
        No Storyteller connection. Add one in Settings → Storyteller.
      </p>
    );
  }
  const enabled = value.connectionID != null;
  const set = (patch: Partial<DeliverySelection>) => onChange({ ...value, ...patch });

  return (
    <>
      <label className={styles.fieldRow}>
        <input
          type="checkbox"
          checked={enabled}
          onChange={(event) =>
            onChange(
              event.target.checked
                ? {
                    connectionID: connections[0]?.id ?? null,
                    sendEPUB: true,
                    sendM4B: true,
                    sendReadAloud: readAloudAvailable,
                  }
                : {
                    connectionID: null,
                    sendEPUB: false,
                    sendM4B: false,
                    sendReadAloud: false,
                  },
            )
          }
        />
        <span>Send finished products to Storyteller</span>
      </label>

      {enabled && (
        <>
          <label className={styles.field}>
            <span>Connection</span>
            <select
              value={value.connectionID ?? ""}
              onChange={(event) => set({ connectionID: event.target.value })}
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
              checked={value.sendEPUB}
              onChange={(event) => set({ sendEPUB: event.target.checked })}
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
              checked={value.sendReadAloud && readAloudAvailable}
              disabled={!readAloudAvailable}
              onChange={(event) => set({ sendReadAloud: event.target.checked })}
            />
            <span>ReadAloud EPUB</span>
          </label>
          {children}
        </>
      )}
    </>
  );
}

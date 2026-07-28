import { BookUp, RefreshCcw, Trash2, X } from "lucide-react";
import { useEffect, useState } from "react";
import { useDraftActions, useDrafts, useProductionDefaults } from "../../api/drafts";
import { useTTSCatalog } from "../../api/queries";
import type { Draft, DraftProcessSettings } from "../../api/types";
import {
  cancelUpload,
  dismissUpload,
  enqueueUploads,
  hasActiveUploads,
  useUploads,
} from "../../stores/uploads";
import { buildDraftQueueEntry, settingsFromDefaults } from "./createPayload";
import { SettingsFields } from "./SettingsFields";
import styles from "./CreatePage.module.css";

function bytes(value: number): string {
  if (value >= 1 << 20) return `${(value / (1 << 20)).toFixed(1)} MB`;
  return `${Math.max(1, Math.round(value / 1024))} KB`;
}

export function CreatePage() {
  const { data: drafts, refetch } = useDrafts();
  const { data: defaults } = useProductionDefaults();
  const { data: ttsCatalog } = useTTSCatalog();
  const actions = useDraftActions();
  const uploads = useUploads((s) => s.uploads);
  const [selectedID, setSelectedID] = useState<string | null>(null);
  const [batch, setBatch] = useState<DraftProcessSettings | null>(null);
  const [overrides, setOverrides] = useState<Record<string, DraftProcessSettings>>({});
  const [queueMessage, setQueueMessage] = useState<string | null>(null);
  const [dragging, setDragging] = useState(false);

  const settings = batch;
  useEffect(() => {
    if (!batch && defaults) setBatch(settingsFromDefaults(defaults));
  }, [defaults, batch]);

  // Mirror the desktop's discard warning while uploads or unqueued drafts exist.
  useEffect(() => {
    const handler = (event: BeforeUnloadEvent) => {
      const pending = (drafts ?? []).some(
        (draft) => draft.status === "ready" || draft.status === "loading",
      );
      if (pending || hasActiveUploads()) event.preventDefault();
    };
    window.addEventListener("beforeunload", handler);
    return () => window.removeEventListener("beforeunload", handler);
  }, [drafts]);

  const list = drafts ?? [];
  const readyCount = list.filter((draft) => draft.status === "ready").length;
  const loadingCount = list.filter(
    (draft) => draft.status === "loading" || draft.status === "uploading",
  ).length;
  const selected = list.find((draft) => draft.id === selectedID) ?? null;

  const addFiles = (files: File[]) => {
    enqueueUploads(files, () => void refetch());
  };

  const queueAll = async () => {
    if (!settings) return;
    const ready = list.filter((draft) => draft.status === "ready");
    const payload = ready.map((draft) =>
      buildDraftQueueEntry(draft, overrides[draft.id] ?? settings),
    );
    const result = await actions.queue.mutateAsync(payload);
    const queued = result.outcomes.filter((outcome) => outcome.status === "queued").length;
    const problems = result.outcomes.filter((outcome) => outcome.status !== "queued");
    setQueueMessage(
      `Queued ${queued} book${queued === 1 ? "" : "s"}` +
        (problems.length > 0
          ? `; ${problems.length} not queued (${problems[0]?.message ?? ""})`
          : ""),
    );
  };

  const inspected: Draft | null = selected;
  const inspectedSettings = inspected
    ? (overrides[inspected.id] ?? settings)
    : settings;

  return (
    <div
      className={styles.page}
      data-dragging={dragging || undefined}
      onDragOver={(event) => {
        event.preventDefault();
        setDragging(true);
      }}
      onDragLeave={() => setDragging(false)}
      onDrop={(event) => {
        event.preventDefault();
        setDragging(false);
        addFiles([...event.dataTransfer.files]);
      }}
    >
      <div className={styles.listPane}>
        <div className={styles.actions}>
          <label className={styles.button}>
            Add EPUBs…
            <input
              type="file"
              accept=".epub"
              multiple
              hidden
              onChange={(event) => {
                addFiles([...(event.target.files ?? [])]);
                event.target.value = "";
              }}
            />
          </label>
          <span className={styles.counts}>
            {loadingCount > 0 ? `${loadingCount} importing · ` : ""}
            {readyCount} ready
          </span>
          <span className={styles.spacer} />
          <button
            className={styles.primary}
            disabled={
              readyCount === 0 || loadingCount > 0 || actions.queue.isPending || !settings
            }
            onClick={() => void queueAll()}
          >
            <BookUp size={14} aria-hidden /> Add {readyCount} to Queue
          </button>
        </div>

        {queueMessage && (
          <div className={styles.notice} role="status">
            {queueMessage}
            <button onClick={() => setQueueMessage(null)} aria-label="Dismiss">
              <X size={12} />
            </button>
          </div>
        )}

        {uploads.length > 0 && (
          <div className={styles.uploadTray}>
            {uploads.map((upload) => (
              <div key={upload.key} className={styles.upload}>
                <span className={styles.uploadName}>{upload.filename}</span>
                {upload.error ? (
                  <span className={styles.uploadError}>{upload.error}</span>
                ) : (
                  <div className={styles.track}>
                    <div
                      className={styles.fill}
                      style={{ width: `${upload.fraction * 100}%` }}
                    />
                  </div>
                )}
                <button
                  aria-label="Cancel upload"
                  onClick={() =>
                    upload.error ? dismissUpload(upload.key) : cancelUpload(upload.key)
                  }
                >
                  <X size={12} />
                </button>
              </div>
            ))}
          </div>
        )}

        {list.length === 0 && uploads.length === 0 ? (
          <div className={styles.empty}>
            <h2>Create an Audiobook</h2>
            <p>Drop EPUBs here, or use Add EPUBs…</p>
          </div>
        ) : (
          <ul className={styles.drafts}>
            {list.map((draft) => (
              <li
                key={draft.id}
                className={styles.draft}
                data-selected={draft.id === selectedID || undefined}
                onClick={() => setSelectedID(draft.id)}
              >
                {draft.hasCover ? (
                  <img
                    className={styles.cover}
                    src={`/api/drafts/${draft.id}/cover`}
                    alt=""
                  />
                ) : (
                  <div className={styles.coverPlaceholder} aria-hidden />
                )}
                <div className={styles.draftBody}>
                  <div className={styles.draftTitle}>
                    {draft.title ?? draft.displayName}
                  </div>
                  <div className={styles.draftMeta}>
                    {draft.author ?? ""}
                    {draft.status === "ready" &&
                      ` · ${draft.chapterCount} chapters · ${bytes(draft.sourceSize)}`}
                    {draft.inLibrary && " · In Library"}
                  </div>
                  <div className={styles.draftStatus} data-status={draft.status}>
                    {draft.status === "loading" || draft.status === "uploading"
                      ? "Importing…"
                      : draft.statusMessage ?? draft.status}
                  </div>
                </div>
                <div className={styles.draftActions}>
                  {(draft.status === "invalid" || draft.status === "skipped") && (
                    <button
                      aria-label="Retry import"
                      onClick={(event) => {
                        event.stopPropagation();
                        void actions.retry.mutateAsync(draft.id);
                      }}
                    >
                      <RefreshCcw size={14} />
                    </button>
                  )}
                  <button
                    aria-label="Remove from batch"
                    onClick={(event) => {
                      event.stopPropagation();
                      void actions.remove.mutateAsync(draft.id);
                      if (selectedID === draft.id) setSelectedID(null);
                    }}
                  >
                    <Trash2 size={14} />
                  </button>
                </div>
              </li>
            ))}
          </ul>
        )}
      </div>

      <aside className={styles.inspector}>
        {inspected ? (
          <>
            <header className={styles.inspectorHeader}>
              <h2>{inspected.title ?? inspected.displayName}</h2>
              <label className={styles.fieldRow}>
                <input
                  type="checkbox"
                  checked={overrides[inspected.id] != null}
                  onChange={(event) =>
                    setOverrides((prev) => {
                      const next = { ...prev };
                      if (event.target.checked && settings) {
                        next[inspected.id] = { ...settings };
                      } else {
                        delete next[inspected.id];
                      }
                      return next;
                    })
                  }
                />
                <span>Customize (otherwise batch settings apply)</span>
              </label>
            </header>
            {overrides[inspected.id] != null && ttsCatalog && inspectedSettings && (
              <SettingsFields
                value={inspectedSettings}
                onChange={(next) =>
                  setOverrides((prev) => ({ ...prev, [inspected.id]: next }))
                }
                catalog={ttsCatalog}
                connections={defaults?.connections ?? []}
                workersUserSet={defaults?.workerSource === "remembered"}
              />
            )}
            {inspected.sections.length > 0 && (
              <section className={styles.sections}>
                <h3>
                  Narrated Sections (
                  {inspected.sections.filter((section) => section.included).length} of{" "}
                  {inspected.sections.length})
                </h3>
                <ul>
                  {inspected.sections.map((section) => (
                    <li key={section.id}>
                      <label className={styles.fieldRow}>
                        <input
                          type="checkbox"
                          checked={section.included}
                          onChange={(event) =>
                            void actions.toggleSection.mutateAsync({
                              id: inspected.id,
                              sectionID: section.id,
                              included: event.target.checked,
                            })
                          }
                        />
                        <span className={styles.sectionTitle}>
                          {section.title || `Section ${section.id}`}
                        </span>
                        <span className={styles.sectionMeta}>
                          {section.role} · {section.characterCount.toLocaleString()}
                        </span>
                      </label>
                    </li>
                  ))}
                </ul>
              </section>
            )}
          </>
        ) : (
          <>
            <header className={styles.inspectorHeader}>
              <h2>Batch Settings</h2>
              <p className={styles.hint}>Applied to every book without custom settings.</p>
            </header>
            {defaults?.permissionWarning && (
              <div className={styles.warning}>{defaults.permissionWarning}</div>
            )}
            {defaults?.workerWarning && (
              <div className={styles.warning}>{defaults.workerWarning}</div>
            )}
            {ttsCatalog && settings && (
              <SettingsFields
                value={settings}
                onChange={setBatch}
                catalog={ttsCatalog}
                connections={defaults?.connections ?? []}
                workersUserSet={defaults?.workerSource === "remembered"}
              />
            )}
          </>
        )}
      </aside>
    </div>
  );
}

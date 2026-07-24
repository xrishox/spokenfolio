import { useMutation, useQueryClient } from "@tanstack/react-query";
import { useState } from "react";
import { api } from "../api/client";
import type { Settings } from "../api/types";
import { FolderPicker } from "./FolderPicker";
import styles from "./OnboardingModal.module.css";

/** Blocking first-visit dialog: the server has no confirmed library folder
 *  yet, so nothing else is usable until one is chosen. There is no skip. */
export function OnboardingModal({ settings }: { settings: Settings }) {
  const queryClient = useQueryClient();
  const [path, setPath] = useState(settings.processedDirectory);

  const save = useMutation({
    mutationFn: () =>
      api<Settings>("/api/settings/processed-directory", {
        method: "PUT",
        body: JSON.stringify({ path: path.trim() }),
      }),
    onSuccess: (fresh) => {
      queryClient.setQueryData(["settings"], fresh);
      void queryClient.invalidateQueries({ queryKey: ["settings"] });
    },
  });

  return (
    <div
      className={styles.overlay}
      role="dialog"
      aria-modal="true"
      aria-label="Choose the book library folder"
    >
      <div className={styles.sheet}>
        <h2 className={styles.title}>Where should SpokenFolio keep your books?</h2>
        <p className={styles.dim}>
          All book files — imported EPUBs, Storyteller downloads, TTS audiobooks, and TTS
          ReadAlouds — are stored here, one folder per book.
        </p>
        <input
          className={styles.input}
          value={path}
          onChange={(event) => setPath(event.target.value)}
          placeholder="Folder path on the Mac (e.g. ~/Books/SpokenFolio)"
          aria-label="Library folder path"
        />
        <FolderPicker initialPath={settings.processedDirectory} onPick={setPath} />
        {save.isError && (
          <p className={styles.error} role="alert">
            {save.error instanceof Error ? save.error.message : String(save.error)}
          </p>
        )}
        <div className={styles.footer}>
          <button
            className={styles.primary}
            disabled={!path.trim() || save.isPending}
            onClick={() => save.mutate()}
          >
            {save.isPending ? "Saving…" : "Use This Folder"}
          </button>
        </div>
      </div>
    </div>
  );
}

import { X } from "lucide-react";
import { useState } from "react";
import type { MirrorFormat } from "../../api/types";
import styles from "./MirrorDialog.module.css";

const formatOptions: readonly { value: MirrorFormat; label: string }[] = [
  { value: "ebook", label: "EPUB" },
  { value: "audiobook", label: "Human Audiobook" },
  { value: "readaloud", label: "Human ReadAloud" },
];

/** Chooser for which remote formats a Storyteller download should pull.
 *  Formats already in the local library are skipped server-side, so the
 *  checked set is an upper bound, not a promise. */
export function MirrorDialog({
  bookCount,
  busy,
  error,
  onConfirm,
  onClose,
}: {
  /** null downloads every Storyteller book; otherwise the selected count. */
  bookCount: number | null;
  busy: boolean;
  error: string | null;
  onConfirm: (formats: MirrorFormat[]) => void;
  onClose: () => void;
}) {
  const [checked, setChecked] = useState<Record<MirrorFormat, boolean>>({
    ebook: true,
    audiobook: true,
    readaloud: true,
  });
  const formats = formatOptions.filter((option) => checked[option.value]).map((option) => option.value);
  const scope =
    bookCount == null
      ? "every Storyteller book"
      : bookCount === 1
        ? "this book"
        : `${bookCount} selected books`;

  return (
    <div className={styles.overlay} role="dialog" aria-modal="true" aria-label="Download from Storyteller">
      <div className={styles.dialog}>
        <header className={styles.header}>
          <h2>Download from Storyteller</h2>
          <button className={styles.close} onClick={onClose} aria-label="Close">
            <X size={16} />
          </button>
        </header>
        <p className={styles.dim}>
          Choose which formats to download for {scope}. Formats already in the local library are
          skipped.
        </p>
        <div className={styles.formats}>
          {formatOptions.map((option) => (
            <label key={option.value} className={styles.row}>
              <input
                type="checkbox"
                checked={checked[option.value]}
                onChange={(event) =>
                  setChecked((prev) => ({ ...prev, [option.value]: event.target.checked }))
                }
              />
              {option.label}
            </label>
          ))}
        </div>
        {error && <p className={styles.error}>{error}</p>}
        <footer className={styles.footer}>
          <button className={styles.button} onClick={onClose}>
            Cancel
          </button>
          <button
            className={styles.primary}
            disabled={busy || formats.length === 0}
            onClick={() => onConfirm(formats)}
          >
            {busy ? "Starting…" : "Download"}
          </button>
        </footer>
      </div>
    </div>
  );
}

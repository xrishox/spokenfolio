import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { RefreshCcw, X } from "lucide-react";
import { useMemo, useState } from "react";
import { api } from "../../api/client";
import type { Library, LibraryRow, SlotState } from "../../api/types";
import { ProcessSheet } from "./ProcessSheet";
import styles from "./LibraryPage.module.css";

const filters = [
  ["all", "All Books"],
  ["attention", "Needs Attention"],
  ["local", "Local Only"],
  ["remote", "Storyteller Only"],
  ["both", "Local + Storyteller"],
] as const;
type Filter = (typeof filters)[number][0];

function levelTint(level: number): string {
  if (level >= 9) return "var(--ok)";
  if (level >= 7) return "color-mix(in srgb, var(--ok) 70%, var(--text-secondary))";
  if (level >= 5) return "var(--info)";
  if (level >= 3) return "var(--warn)";
  return "var(--text-tertiary)";
}

export function LevelBadge({ level, label }: { level: number; label: string }) {
  return (
    <span
      className={styles.levelBadge}
      style={{ background: `color-mix(in srgb, ${levelTint(level)} 18%, transparent)`, color: levelTint(level) }}
      title={label}
    >
      L{level}
    </span>
  );
}

const slotMark: Record<SlotState, string> = {
  verified: "✓",
  present: "✓",
  pending: "?",
  missing: "–",
};

export function SlotChips({ row }: { row: LibraryRow }) {
  const slots = [
    ["E", row.slots.epub, "EPUB"],
    ["Aᵀ", row.slots.ttsAudiobook, "TTS audiobook"],
    ["Rᵀ", row.slots.ttsReadAloud, "TTS ReadAloud"],
    ["Aᴴ", row.slots.humanAudiobook, "Human audiobook"],
    ["Rᴴ", row.slots.humanReadAloud, "Human ReadAloud"],
  ] as const;
  return (
    <span className={styles.slots}>
      {slots.map(([letter, state, label]) => (
        <span
          key={letter}
          className={styles.slot}
          data-state={state}
          title={`${label}: ${state}`}
        >
          {letter}
          {slotMark[state]}
        </span>
      ))}
    </span>
  );
}

export function LibraryPage() {
  const queryClient = useQueryClient();
  const [connection, setConnection] = useState<string | "local">("local");
  const [filter, setFilter] = useState<Filter>("all");
  const [query, setQuery] = useState("");
  const [selectedID, setSelectedID] = useState<string | null>(null);
  const [selection, setSelection] = useState<Set<string>>(new Set());
  const [processing, setProcessing] = useState<string[] | null>(null);

  const connectionParam = connection === "local" ? "" : `?connection=${connection}`;
  const { data, isLoading } = useQuery<Library>({
    queryKey: ["library", connection],
    queryFn: () => api<Library>(`/api/library${connectionParam}`),
    staleTime: 15_000,
    retry: false,
  });

  const refresh = useMutation({
    mutationFn: () =>
      api<Library>(`/api/library/refresh${connectionParam}`, { method: "POST" }),
    onSuccess: (fresh) => queryClient.setQueryData(["library", connection], fresh),
  });

  const narration = useMutation({
    mutationFn: ({ rowIDs, provenance }: { rowIDs: string[]; provenance: string }) =>
      api<Library>(`/api/library/narration${connectionParam}`, {
        method: "POST",
        body: JSON.stringify({ rowIDs, provenance }),
      }),
    onSuccess: (fresh) => queryClient.setQueryData(["library", connection], fresh),
  });

  const rows = data?.rows ?? [];
  const visible = useMemo(() => {
    const trimmed = query.trim().toLowerCase();
    return rows.filter((row) => {
      const matches = switchFilter(row, filter);
      if (!matches) return false;
      if (!trimmed) return true;
      return (
        row.title.toLowerCase().includes(trimmed) ||
        row.author?.toLowerCase().includes(trimmed) ||
        row.identifiers.some((identifier) => identifier.value.includes(trimmed))
      );
    });
  }, [rows, filter, query]);

  const selected = rows.find((row) => row.id === selectedID) ?? null;
  const selectedIDs = [...selection].filter((id) => visible.some((row) => row.id === id));

  return (
    <div className={styles.page}>
      <header className={styles.header}>
        <h1 className={styles.title}>Library</h1>
        <span className={styles.counts}>
          {visible.length} of {rows.length}
        </span>
        <label className={styles.compareLabel}>
          Compare with
          <select value={connection} onChange={(event) => setConnection(event.target.value)}>
            <option value="local">Local only</option>
            {(data?.connections ?? []).map((c) => (
              <option key={c.id} value={c.id}>
                {c.label}
              </option>
            ))}
          </select>
        </label>
        <input
          className={styles.search}
          placeholder="Search title, author, ISBN"
          value={query}
          onChange={(event) => setQuery(event.target.value)}
        />
        <span className={styles.spacer} />
        <button
          className={styles.button}
          disabled={refresh.isPending}
          onClick={() => void refresh.mutateAsync()}
        >
          <RefreshCcw size={14} aria-hidden /> Refresh
        </button>
      </header>

      <div className={styles.scopeBar} role="radiogroup" aria-label="Filter">
        {filters.map(([key, label]) => (
          <button
            key={key}
            role="radio"
            aria-checked={filter === key}
            data-active={filter === key || undefined}
            onClick={() => setFilter(key)}
          >
            {label}
          </button>
        ))}
      </div>

      {(data?.snapshotStale || data?.error) && (
        <div className={styles.stale} role="status">
          {data.error ?? "The Storyteller snapshot may be stale."}
        </div>
      )}

      {selectedIDs.length > 1 && (
        <div className={styles.selectionBar}>
          <span>{selectedIDs.length} selected</span>
          <button className={styles.button} onClick={() => setProcessing(selectedIDs)}>
            Process Books…
          </button>
          <span className={styles.spacer} />
          <label>
            Narration:
            <select
              defaultValue=""
              onChange={(event) => {
                if (event.target.value)
                  void narration.mutateAsync({
                    rowIDs: selectedIDs,
                    provenance: event.target.value,
                  });
                event.target.value = "";
              }}
            >
              <option value="" disabled>
                Assert…
              </option>
              <option value="human">Human</option>
              <option value="spokenFolioTTS">TTS</option>
              <option value="unknown">Unknown</option>
            </select>
          </label>
        </div>
      )}

      <div className={styles.splitRegion}>
        <div className={styles.tableWrap}>
          <table className={styles.table}>
            <thead>
              <tr>
                <th>Title</th>
                <th className={styles.thLevel}>Completeness</th>
                <th>Slots</th>
                <th>Narration</th>
                <th>Quality</th>
              </tr>
            </thead>
            <tbody>
              {visible.map((row) => (
                <tr
                  key={row.id}
                  data-selected={row.id === selectedID || selection.has(row.id) || undefined}
                  onClick={(event) => {
                    if (event.metaKey || event.ctrlKey) {
                      setSelection((prev) => {
                        const next = new Set(prev);
                        if (next.has(row.id)) next.delete(row.id);
                        else next.add(row.id);
                        return next;
                      });
                    } else {
                      setSelection(new Set([row.id]));
                      setSelectedID(row.id);
                    }
                  }}
                >
                  <td>
                    <div className={styles.rowTitle}>{row.title}</div>
                    <div className={styles.rowAuthor}>
                      {row.author ?? ""}
                      {row.suggestedRemoteTitle && (
                        <em> · Storyteller match — confirm</em>
                      )}
                    </div>
                  </td>
                  <td>
                    <LevelBadge level={row.level} label={row.levelLabel} />{" "}
                    <span className={styles.levelLabel}>{row.levelLabel}</span>
                  </td>
                  <td>
                    <SlotChips row={row} />
                  </td>
                  <td className={styles.tdSecondary}>
                    {row.narration === "spokenFolioTTS"
                      ? "TTS"
                      : row.narration === "human"
                        ? "Human"
                        : "—"}
                  </td>
                  <td className={styles.tdSecondary}>
                    {row.localQualityVerdict ?? row.remoteQualityVerdict ?? "Not run"}
                  </td>
                </tr>
              ))}
              {visible.length === 0 && !isLoading && (
                <tr>
                  <td colSpan={5} className={styles.empty}>
                    No books match.
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        </div>

        {selected && (
          <aside className={styles.inspector} aria-label={selected.title}>
            <header className={styles.inspectorHeader}>
              <div>
                <h2>{selected.title}</h2>
                <div className={styles.rowAuthor}>{selected.author}</div>
                <div className={styles.levelLine}>
                  <LevelBadge level={selected.level} label={selected.levelLabel} />{" "}
                  {selected.levelLabel}
                </div>
              </div>
              <button
                className={styles.close}
                onClick={() => setSelectedID(null)}
                aria-label="Close"
              >
                <X size={16} />
              </button>
            </header>

            <section className={styles.section}>
              <button
                className={styles.processButton}
                onClick={() => setProcessing([selected.id])}
              >
                Process…
              </button>
            </section>

            <section className={styles.section}>
              <h3>Products</h3>
              {selected.localProducts.map((product) => (
                <div key={product.kind} className={styles.product}>
                  <span>{product.kind}</span>
                  <code title={product.path}>{product.path}</code>
                </div>
              ))}
              {selected.localProducts.length === 0 && (
                <p className={styles.dim}>No local products.</p>
              )}
              {selected.ttsProvenance && (
                <p className={styles.provenance}>{selected.ttsProvenance}</p>
              )}
            </section>

            {(selected.remoteEPUB || selected.remoteAudiobook || selected.remoteReadAloud) && (
              <section className={styles.section}>
                <h3>Storyteller</h3>
                {(
                  [
                    ["EPUB", selected.remoteEPUB],
                    ["Audiobook", selected.remoteAudiobook],
                    ["ReadAloud", selected.remoteReadAloud],
                  ] as const
                ).map(
                  ([label, asset]) =>
                    asset && (
                      <div key={label} className={styles.remoteAsset}>
                        <span>{label}</span>
                        <span className={styles.dim}>
                          {asset.state}
                          {asset.status ? ` · ${asset.status}` : ""}
                          {asset.stageProgress != null
                            ? ` · ${Math.round(asset.stageProgress * 100)}%`
                            : ""}
                        </span>
                      </div>
                    ),
                )}
                {selected.remoteReadAloud?.state === "ready" && (
                  <label className={styles.narrationRow}>
                    Narration:
                    <select
                      value={selected.narration}
                      onChange={(event) =>
                        void narration.mutateAsync({
                          rowIDs: [selected.id],
                          provenance: event.target.value,
                        })
                      }
                    >
                      <option value="unknown">Unknown</option>
                      <option value="human">Human</option>
                      <option value="spokenFolioTTS">TTS</option>
                      <option value="otherTTS">Other TTS</option>
                    </select>
                  </label>
                )}
              </section>
            )}

            {selected.identifiers.length > 0 && (
              <section className={styles.section}>
                <h3>Edition Identity</h3>
                {selected.identifiers.map((identifier) => (
                  <div key={identifier.kind + identifier.value} className={styles.identifier}>
                    <span className={styles.dim}>{identifier.kind}</span>
                    <code>{identifier.value}</code>
                  </div>
                ))}
              </section>
            )}
          </aside>
        )}
      </div>

      {processing && (
        <ProcessSheet
          rowIDs={processing}
          connection={connection}
          onClose={() => setProcessing(null)}
          onQueued={() => {
            void queryClient.invalidateQueries({ queryKey: ["jobs"] });
            void queryClient.invalidateQueries({ queryKey: ["queue"] });
          }}
        />
      )}
    </div>
  );
}

function switchFilter(row: LibraryRow, filter: Filter): boolean {
  switch (filter) {
    case "all":
      return true;
    case "attention":
      return (
        row.suggestedRemoteTitle != null ||
        row.localQualityVerdict === "needsReview" ||
        row.localQualityVerdict === "broken" ||
        row.localQualityVerdict === "likelyBroken" ||
        row.remoteQualityVerdict === "needsReview" ||
        row.remoteQualityVerdict === "broken" ||
        row.remoteQualityVerdict === "likelyBroken"
      );
    case "local":
      return row.presence === "Local";
    case "remote":
      return row.presence === "Storyteller";
    case "both":
      return row.presence === "Both";
  }
}

import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { CheckCircle2, Download, Link2, RefreshCcw, X } from "lucide-react";
import { useEffect, useMemo, useState } from "react";
import { api } from "../../api/client";
import type {
  AsinCandidate,
  AsinResolve,
  Library,
  LibraryRow,
  MatchFindResult,
  MirrorStatus,
  SlotState,
} from "../../api/types";
import { useConnection } from "../../stores/connection";
import { clearSelection, clickRow, emptySelection, selectAll, type SelectionState } from "../../lib/selection";
import { enqueueUploads, useUploads } from "../../stores/uploads";
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

const CONNECTION_KEY = "spokenfolio.libraryConnection";

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
        <span key={letter} className={styles.slot} data-state={state} title={`${label}: ${state}`}>
          {letter}
          {slotMark[state]}
        </span>
      ))}
    </span>
  );
}

function narrationLabel(value: string): string {
  switch (value) {
    case "spokenFolioTTS":
      return "TTS";
    case "otherTTS":
      return "Other TTS";
    case "human":
      return "Human";
    default:
      return "—";
  }
}

export function LibraryPage() {
  const queryClient = useQueryClient();
  const [connection, setConnection] = useState<string | "local">(
    () => localStorage.getItem(CONNECTION_KEY) ?? "",
  );
  const [filter, setFilter] = useState<Filter>("all");
  const [query, setQuery] = useState("");
  const [selection, setSelection] = useState<SelectionState>(emptySelection);
  const [processing, setProcessing] = useState<{ rowIDs: string[]; intent: "process" | "sendOnly" } | null>(null);
  const [isbnDraft, setISBNDraft] = useState<{ recordID: string; value: string; push: boolean } | null>(null);
  const [matchDialog, setMatchDialog] = useState<{ recordID: string; result: MatchFindResult | null; selected: string | null } | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const sseConnected = useConnection((s) => s.sseConnected);
  const uploads = useUploads((s) => s.uploads);

  const connectionParam = connection && connection !== "local" ? `?connection=${connection}` : "";
  const { data, isLoading } = useQuery<Library>({
    queryKey: ["library", connection],
    queryFn: () => api<Library>(`/api/library${connectionParam}`),
    staleTime: 15_000,
    retry: false,
    enabled: connection !== "",
  });

  // Bootstrap: with no stored choice, default to the first connection (the
  // desktop persists the same choice in UserDefaults).
  const { data: bootstrap } = useQuery<Library>({
    queryKey: ["library-bootstrap"],
    queryFn: () => api<Library>("/api/library"),
    staleTime: Infinity,
    retry: false,
    enabled: connection === "",
  });
  useEffect(() => {
    if (connection === "" && bootstrap) {
      const first = bootstrap.connections[0]?.id ?? "local";
      setConnection(first);
      localStorage.setItem(CONNECTION_KEY, first);
    }
  }, [connection, bootstrap]);

  const setLibraryData = (fresh: Library) =>
    queryClient.setQueryData(["library", connection], fresh);

  const refresh = useMutation({
    mutationFn: () => api<Library>(`/api/library/refresh${connectionParam}`, { method: "POST" }),
    onSuccess: setLibraryData,
  });

  // The desktop refreshes remote inventory whenever a connection is chosen.
  const [refreshedFor, setRefreshedFor] = useState<string>("");
  useEffect(() => {
    if (connection && connection !== "local" && refreshedFor !== connection) {
      setRefreshedFor(connection);
      refresh.mutate();
    }
  }, [connection, refreshedFor, refresh]);

  const narration = useMutation({
    mutationFn: ({ rowIDs, provenance }: { rowIDs: string[]; provenance: string }) =>
      api<Library>(`/api/library/narration${connectionParam}`, {
        method: "POST",
        body: JSON.stringify({ rowIDs, provenance }),
      }),
    onSuccess: setLibraryData,
  });

  const qualityCheck = useMutation({
    mutationFn: ({ rowIDs, scope }: { rowIDs: string[]; scope: string }) =>
      api<{ status: string }>(`/api/library/quality-check${connectionParam}`, {
        method: "POST",
        body: JSON.stringify({ rowIDs, scope }),
      }),
    onSuccess: (queue) => {
      setNotice(queue.status || "Quality checks queued.");
      void queryClient.invalidateQueries({ queryKey: ["quality"] });
    },
  });

  const saveISBN = useMutation({
    mutationFn: ({ recordID, isbn, push }: { recordID: string; isbn: string; push: boolean }) =>
      api<Library>(`/api/library/editions/${recordID}/identifier${connectionParam}`, {
        method: "PUT",
        body: JSON.stringify({ isbn, pushToStoryteller: push }),
      }),
    onSuccess: (fresh) => {
      setLibraryData(fresh);
      setISBNDraft(null);
    },
  });

  const suggested = useMutation({
    mutationFn: ({ rowID, action }: { rowID: string; action: "confirm" | "decline" }) =>
      api<Library>(`/api/library/match/${action}-suggested${connectionParam}`, {
        method: "POST",
        body: JSON.stringify({ rowID }),
      }),
    onSuccess: setLibraryData,
  });

  const unlink = useMutation({
    mutationFn: (recordID: string) =>
      api<Library>(`/api/library/match${connectionParam}`, {
        method: "DELETE",
        body: JSON.stringify({ recordID }),
      }),
    onSuccess: setLibraryData,
  });

  const matchFind = useMutation({
    mutationFn: (recordID: string) =>
      api<MatchFindResult>(`/api/library/match/find${connectionParam}`, {
        method: "POST",
        body: JSON.stringify({ recordID }),
      }),
  });

  const matchLink = useMutation({
    mutationFn: ({ recordID, remoteBookID }: { recordID: string; remoteBookID: string }) =>
      api<Library>(`/api/library/match/link${connectionParam}`, {
        method: "POST",
        body: JSON.stringify({ recordID, remoteBookID }),
      }),
    onSuccess: (fresh) => {
      setLibraryData(fresh);
      setMatchDialog(null);
    },
  });

  const { data: mirror } = useQuery<MirrorStatus>({
    queryKey: ["library"],
    queryFn: () => api<MirrorStatus>("/api/library/mirror"),
    refetchInterval: sseConnected ? false : 4000,
    staleTime: Infinity,
    retry: false,
  });
  const [mirrorSeen, setMirrorSeen] = useState(0);
  useEffect(() => {
    // Refresh rows as each download lands so mirrored books appear live.
    if (mirror && mirror.completed !== mirrorSeen) {
      setMirrorSeen(mirror.completed);
      void queryClient.invalidateQueries({ queryKey: ["library", connection] });
    }
  }, [mirror, mirrorSeen, queryClient, connection]);

  const startMirror = useMutation({
    mutationFn: (body: { rowIDs?: string[]; all?: boolean }) =>
      api<MirrorStatus>(`/api/library/mirror${connectionParam}`, {
        method: "POST",
        body: JSON.stringify(body),
      }),
    onSuccess: (fresh) => queryClient.setQueryData(["library"], fresh),
  });

  const remoteReadAloud = useMutation({
    mutationFn: (rowID: string) =>
      api<Library>(`/api/library/remote-readaloud${connectionParam}`, {
        method: "POST",
        body: JSON.stringify({ rowID }),
      }),
    onSuccess: (fresh) => {
      setLibraryData(fresh);
      setNotice("Storyteller is creating the ReadAloud; a quality check queues automatically when it finishes.");
    },
  });

  const rows = data?.rows ?? [];
  const visible = useMemo(() => {
    const trimmed = query.trim().toLowerCase();
    return rows.filter((row) => {
      if (!matchesFilter(row, filter)) return false;
      if (!trimmed) return true;
      return (
        row.title.toLowerCase().includes(trimmed) ||
        row.author?.toLowerCase().includes(trimmed) ||
        row.identifiers.some((identifier) => identifier.value.includes(trimmed))
      );
    });
  }, [rows, filter, query]);

  const visibleIDs = useMemo(() => visible.map((row) => row.id), [visible]);
  const selectedIDs = [...selection.ids].filter((id) => visibleIDs.includes(id));
  const selectedRows = visible.filter((row) => selection.ids.has(row.id));
  const inspected = selectedIDs.length === 1 ? (rows.find((row) => row.id === selectedIDs[0]) ?? null) : null;

  const qualityCounts = useMemo(() => {
    let local = 0;
    let remote = 0;
    for (const row of selectedRows) {
      if (row.localReadAloudProductID) local += 1;
      if (row.remoteReadAloudReady) remote += 1;
    }
    return { local, remote, all: local + remote };
  }, [selectedRows]);

  // Keyboard: ⌘A select-all-visible, Esc clear.
  useEffect(() => {
    const handler = (event: KeyboardEvent) => {
      const target = event.target as HTMLElement;
      if (target.tagName === "INPUT" || target.tagName === "SELECT" || target.tagName === "TEXTAREA") return;
      if ((event.metaKey || event.ctrlKey) && event.key === "a") {
        event.preventDefault();
        setSelection(selectAll(visibleIDs));
      } else if (event.key === "Escape") {
        setSelection(clearSelection());
      }
    };
    window.addEventListener("keydown", handler);
    return () => window.removeEventListener("keydown", handler);
  }, [visibleIDs]);

  return (
    <div className={styles.page}>
      <header className={styles.header}>
        <h1 className={styles.title}>Library</h1>
        <span className={styles.counts}>
          {visible.length} of {rows.length}
        </span>
        <label className={styles.compareLabel}>
          Compare with
          <select
            value={connection}
            onChange={(event) => {
              setConnection(event.target.value);
              localStorage.setItem(CONNECTION_KEY, event.target.value);
              setSelection(clearSelection());
            }}
          >
            <option value="local">Local only</option>
            {(data?.connections ?? bootstrap?.connections ?? []).map((c) => (
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
          <RefreshCcw size={14} aria-hidden /> {refresh.isPending ? "Refreshing…" : "Refresh"}
        </button>
        <label className={styles.button}>
          Import Books…
          <input
            type="file"
            accept=".epub"
            multiple
            hidden
            onChange={(event) => {
              enqueueUploads(
                [...(event.target.files ?? [])],
                () => void queryClient.invalidateQueries({ queryKey: ["library", connection] }),
                (name) =>
                  `/api/library/upload?filename=${encodeURIComponent(name)}${connection !== "local" ? `&connection=${connection}` : ""}`,
              );
              event.target.value = "";
            }}
          />
        </label>
        {connection !== "local" && (
          <button
            className={styles.button}
            disabled={mirror?.isBusy || startMirror.isPending}
            onClick={() => {
              const count = rows.filter(
                (row) => !row.inLibrary && row.remoteEPUB?.state === "ready",
              ).length;
              if (count === 0) {
                setNotice("Every Storyteller book with a ready ebook is already in the library.");
                return;
              }
              if (
                confirm(
                  `Download ${count} Storyteller ebook${count === 1 ? "" : "s"} into the local library? Audiobooks stay on the server by design; mirrored books can be processed locally afterward.`,
                )
              )
                void startMirror.mutateAsync({ all: true });
            }}
          >
            <Download size={14} aria-hidden /> Download All…
          </button>
        )}
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
      {uploads.length > 0 && (
        <div className={styles.stale} role="status" aria-live="polite">
          Importing {uploads.length} upload{uploads.length === 1 ? "" : "s"}…{" "}
          {uploads[0] && `${uploads[0].filename} ${Math.round(uploads[0].fraction * 100)}%`}
          {uploads.some((u) => u.error) && ` — ${uploads.find((u) => u.error)?.error}`}
        </div>
      )}
      {mirror && (mirror.isBusy || (mirror.failures.length > 0 && mirror.completed > 0)) && (
        <div className={styles.stale} role="status" aria-live="polite">
          {mirror.isBusy
            ? `Downloading from Storyteller… ${mirror.completed} of ${mirror.total}${mirror.currentTitle ? ` — ${mirror.currentTitle}` : ""}`
            : `Download finished with ${mirror.failures.length} failure${mirror.failures.length === 1 ? "" : "s"}: ${mirror.failures[0]?.title} — ${mirror.failures[0]?.reason}`}
        </div>
      )}
      {notice && (
        <div className={styles.notice} role="status">
          {notice}
          <button onClick={() => setNotice(null)} aria-label="Dismiss">
            <X size={12} />
          </button>
        </div>
      )}

      {selectedIDs.length >= 1 && (
        <div className={styles.selectionBar}>
          <span>{selectedIDs.length} selected</span>
          <button className={styles.button} onClick={() => setProcessing({ rowIDs: selectedIDs, intent: "process" })}>
            Process Books…
          </button>
          {selectedRows.some((row) => !row.inLibrary && row.remoteEPUB?.state === "ready") && (
            <button
              className={styles.button}
              disabled={mirror?.isBusy || startMirror.isPending}
              onClick={() => void startMirror.mutateAsync({ rowIDs: selectedIDs })}
            >
              <Download size={13} aria-hidden /> Download to Library
            </button>
          )}
          <label>
            Check Quality:
            <select
              defaultValue=""
              onChange={(event) => {
                if (event.target.value)
                  void qualityCheck.mutateAsync({ rowIDs: selectedIDs, scope: event.target.value });
                event.target.value = "";
              }}
            >
              <option value="" disabled>
                Scope…
              </option>
              <option value="local" disabled={qualityCounts.local === 0}>
                Local ({qualityCounts.local})
              </option>
              <option value="storyteller" disabled={qualityCounts.remote === 0}>
                Storyteller ({qualityCounts.remote})
              </option>
              <option value="all" disabled={qualityCounts.all === 0}>
                All Available ({qualityCounts.all})
              </option>
            </select>
          </label>
          <label>
            Narration:
            <select
              defaultValue=""
              onChange={(event) => {
                if (event.target.value)
                  void narration.mutateAsync({ rowIDs: selectedIDs, provenance: event.target.value });
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
          <span className={styles.spacer} />
          <button className={styles.buttonSmall} onClick={() => setSelection(clearSelection())}>
            Clear
          </button>
        </div>
      )}

      <div className={styles.splitRegion}>
        <div className={styles.tableWrap}>
          <table className={styles.table} aria-multiselectable="true">
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
                  data-selected={selection.ids.has(row.id) || undefined}
                  aria-selected={selection.ids.has(row.id)}
                  onMouseDown={(event) => {
                    if (event.shiftKey) event.preventDefault();
                  }}
                  onClick={(event) =>
                    setSelection((prev) =>
                      clickRow(prev, visibleIDs, row.id, {
                        meta: event.metaKey || event.ctrlKey,
                        shift: event.shiftKey,
                      }),
                    )
                  }
                >
                  <td>
                    <div className={styles.rowTitle}>{row.title}</div>
                    <div className={styles.rowAuthor}>
                      {row.author ?? ""}
                      {row.suggestedRemoteTitle && <em> · Storyteller match — confirm</em>}
                    </div>
                  </td>
                  <td>
                    <LevelBadge level={row.level} label={row.levelLabel} />{" "}
                    <span className={styles.levelLabel}>{row.levelLabel}</span>
                  </td>
                  <td>
                    <SlotChips row={row} />
                  </td>
                  <td className={styles.tdSecondary}>{narrationLabel(row.narration)}</td>
                  <td className={styles.tdSecondary}>
                    {row.localQualityVerdict ?? row.remoteQualityVerdict ?? "Not run"}
                  </td>
                </tr>
              ))}
              {visible.length === 0 && !isLoading && (
                <tr>
                  <td colSpan={5} className={styles.empty}>
                    {connection === "local" && (bootstrap?.connections.length ?? data?.connections.length ?? 0) > 0
                      ? "Compare with a Storyteller connection to see remote books."
                      : "No books match."}
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        </div>

        {inspected && (
          <aside className={styles.inspector} aria-label={inspected.title}>
            <header className={styles.inspectorHeader}>
              <div>
                <h2>{inspected.title}</h2>
                <div className={styles.rowAuthor}>{inspected.author}</div>
                <div className={styles.levelLine}>
                  <LevelBadge level={inspected.level} label={inspected.levelLabel} /> {inspected.levelLabel}
                </div>
              </div>
              <button className={styles.close} onClick={() => setSelection(clearSelection())} aria-label="Close">
                <X size={16} />
              </button>
            </header>

            {inspected.suggestedRemoteTitle && (
              <section className={styles.suggestion}>
                <p>
                  Storyteller has <strong>{inspected.suggestedRemoteTitle}</strong>
                  {inspected.suggestedRemoteAuthors.length > 0 && ` — ${inspected.suggestedRemoteAuthors.join(", ")}`}.
                  Same edition?
                </p>
                <div className={styles.row}>
                  <button
                    className={styles.button}
                    disabled={suggested.isPending}
                    onClick={() => void suggested.mutateAsync({ rowID: inspected.id, action: "confirm" })}
                  >
                    <Link2 size={13} aria-hidden /> Same Edition — Link
                  </button>
                  <button
                    className={styles.button}
                    disabled={suggested.isPending}
                    onClick={() => void suggested.mutateAsync({ rowID: inspected.id, action: "decline" })}
                  >
                    Different Edition
                  </button>
                </div>
              </section>
            )}

            <section className={styles.section}>
              <div className={styles.row}>
                <button
                  className={styles.processButton}
                  onClick={() => setProcessing({ rowIDs: [inspected.id], intent: "process" })}
                >
                  Process…
                </button>
                {!inspected.inLibrary && inspected.remoteEPUB?.state === "ready" && (
                  <button
                    className={styles.button}
                    disabled={mirror?.isBusy || startMirror.isPending}
                    onClick={() => void startMirror.mutateAsync({ rowIDs: [inspected.id] })}
                  >
                    <Download size={13} aria-hidden /> Download to Library
                  </button>
                )}
                {inspected.inLibrary && connection !== "local" && (
                  <button
                    className={styles.button}
                    onClick={() => setProcessing({ rowIDs: [inspected.id], intent: "sendOnly" })}
                  >
                    Send to Storyteller…
                  </button>
                )}
              </div>
              {(inspected.localReadAloudProductID || inspected.remoteReadAloudReady) && (
                <label className={styles.row}>
                  Check Quality:
                  <select
                    defaultValue=""
                    onChange={(event) => {
                      if (event.target.value)
                        void qualityCheck.mutateAsync({ rowIDs: [inspected.id], scope: event.target.value });
                      event.target.value = "";
                    }}
                  >
                    <option value="" disabled>
                      Scope…
                    </option>
                    <option value="local" disabled={!inspected.localReadAloudProductID}>
                      Local
                    </option>
                    <option value="storyteller" disabled={!inspected.remoteReadAloudReady}>
                      Storyteller
                    </option>
                    <option value="all">All Available</option>
                  </select>
                </label>
              )}
              {inspected.canStartRemoteReadAloud && (
                <button
                  className={styles.button}
                  disabled={remoteReadAloud.isPending}
                  onClick={() => {
                    if (
                      confirm(
                        "Ask Storyteller to create a ReadAloud on the server from its ebook and audiobook? A quality check queues automatically when alignment finishes.",
                      )
                    )
                      void remoteReadAloud.mutateAsync(inspected.id);
                  }}
                >
                  <CheckCircle2 size={13} aria-hidden /> Create ReadAloud on Server…
                </button>
              )}
            </section>

            <section className={styles.section}>
              <h3>Products</h3>
              {inspected.localProducts.map((product) => (
                <div key={product.kind} className={styles.product}>
                  <span>{product.kind}</span>
                  <code title={product.path}>{product.path}</code>
                </div>
              ))}
              {inspected.localProducts.length === 0 && <p className={styles.dim}>No local products.</p>}
              {inspected.ttsProvenance && <p className={styles.provenance}>{inspected.ttsProvenance}</p>}
            </section>

            {(inspected.remoteEPUB || inspected.remoteAudiobook || inspected.remoteReadAloud) && (
              <section className={styles.section}>
                <h3>Storyteller</h3>
                {(
                  [
                    ["EPUB", inspected.remoteEPUB],
                    ["Audiobook", inspected.remoteAudiobook],
                    ["ReadAloud", inspected.remoteReadAloud],
                  ] as const
                ).map(
                  ([label, asset]) =>
                    asset && (
                      <div key={label} className={styles.remoteAsset}>
                        <span>{label}</span>
                        <span className={styles.dim}>
                          {asset.state}
                          {asset.status ? ` · ${asset.status}` : ""}
                          {asset.stageProgress != null ? ` · ${Math.round(asset.stageProgress * 100)}%` : ""}
                        </span>
                      </div>
                    ),
                )}
                {inspected.remoteReadAloudReady && (
                  <label className={styles.narrationRow}>
                    Narration:
                    <select
                      value={inspected.narration}
                      onChange={(event) =>
                        void narration.mutateAsync({ rowIDs: [inspected.id], provenance: event.target.value })
                      }
                    >
                      <option value="unknown">Unknown</option>
                      <option value="human">Human</option>
                      <option value="spokenFolioTTS">TTS</option>
                      <option value="otherTTS">Other TTS</option>
                    </select>
                  </label>
                )}
                {inspected.hasStorytellerLink && inspected.recordID && (
                  <button
                    className={styles.buttonSmall}
                    onClick={() => {
                      if (confirm("Unlink this edition from Storyteller? Snapshots and history are kept."))
                        void unlink.mutateAsync(inspected.recordID!);
                    }}
                  >
                    Unlink Storyteller
                  </button>
                )}
              </section>
            )}

            <section className={styles.section}>
              <h3>Edition Identity</h3>
              {inspected.identifiers
                .filter((identifier) => !identifier.kind.toLowerCase().includes("asin"))
                .map((identifier) => (
                  <div key={identifier.kind + identifier.value} className={styles.identifier}>
                    <span className={styles.dim}>{identifier.kind}</span>
                    <code>{identifier.value}</code>
                  </div>
                ))}
              <AsinSection
                row={inspected}
                connection={connection}
                onSaved={setLibraryData}
              />
              {inspected.recordID && (
                <>
                  {isbnDraft?.recordID === inspected.recordID ? (
                    <div className={styles.isbnEditor}>
                      <input
                        className={styles.input}
                        placeholder="ISBN-10 or ISBN-13"
                        value={isbnDraft.value}
                        onChange={(event) => setISBNDraft({ ...isbnDraft, value: event.target.value })}
                      />
                      {inspected.hasStorytellerLink && (
                        <label className={styles.row}>
                          <input
                            type="checkbox"
                            checked={isbnDraft.push}
                            onChange={(event) => setISBNDraft({ ...isbnDraft, push: event.target.checked })}
                          />
                          Also update linked Storyteller edition
                        </label>
                      )}
                      <div className={styles.row}>
                        <button className={styles.buttonSmall} onClick={() => setISBNDraft(null)}>
                          Cancel
                        </button>
                        <button
                          className={styles.buttonSmall}
                          disabled={saveISBN.isPending || !isbnDraft.value.trim()}
                          onClick={() =>
                            void saveISBN.mutateAsync({
                              recordID: isbnDraft.recordID,
                              isbn: isbnDraft.value.trim(),
                              push: isbnDraft.push,
                            })
                          }
                        >
                          Save ISBN
                        </button>
                      </div>
                      {saveISBN.isError && <p className={styles.error}>{String(saveISBN.error)}</p>}
                    </div>
                  ) : (
                    <div className={styles.row}>
                      <button
                        className={styles.buttonSmall}
                        onClick={() =>
                          setISBNDraft({
                            recordID: inspected.recordID!,
                            value:
                              inspected.identifiers.find((identifier) =>
                                identifier.kind.toLowerCase().includes("isbn"),
                              )?.value ?? "",
                            push: inspected.hasStorytellerLink,
                          })
                        }
                      >
                        Correct ISBN…
                      </button>
                      {connection !== "local" && !inspected.hasStorytellerLink && (
                        <button
                          className={styles.buttonSmall}
                          onClick={() => {
                            setMatchDialog({ recordID: inspected.recordID!, result: null, selected: null });
                            void matchFind.mutateAsync(inspected.recordID!).then((result) =>
                              setMatchDialog({ recordID: inspected.recordID!, result, selected: null }),
                            );
                          }}
                        >
                          Match Edition…
                        </button>
                      )}
                    </div>
                  )}
                </>
              )}
            </section>
          </aside>
        )}
      </div>

      {processing && (
        <ProcessSheet
          rowIDs={processing.rowIDs}
          intent={processing.intent}
          connection={connection}
          onClose={() => setProcessing(null)}
          onQueued={() => {
            void queryClient.invalidateQueries({ queryKey: ["jobs"] });
            void queryClient.invalidateQueries({ queryKey: ["queue"] });
          }}
        />
      )}

      {matchDialog && (
        <div className={styles.overlay} role="dialog" aria-modal="true" aria-label="Match edition">
          <div className={styles.dialog}>
            <header className={styles.inspectorHeader}>
              <h2>Match Edition</h2>
              <button className={styles.close} onClick={() => setMatchDialog(null)} aria-label="Close">
                <X size={16} />
              </button>
            </header>
            {!matchDialog.result ? (
              <p className={styles.dim}>Resolving identity on Storyteller…</p>
            ) : matchDialog.result.outcome === "linked" ? (
              <>
                <p>The edition matched and is now linked.</p>
                <button className={styles.button} onClick={() => {
                  setMatchDialog(null);
                  void refresh.mutateAsync();
                }}>
                  Done
                </button>
              </>
            ) : matchDialog.result.candidates.length === 0 ? (
              <p className={styles.dim}>The selected Storyteller library is empty.</p>
            ) : (
              <>
                <p className={styles.dim}>Pick the matching Storyteller edition:</p>
                <ul className={styles.candidateList}>
                  {matchDialog.result.candidates.map((candidate) => (
                    <li key={candidate.remoteBookID}>
                      <label className={styles.row}>
                        <input
                          type="radio"
                          name="match-candidate"
                          checked={matchDialog.selected === candidate.remoteBookID}
                          onChange={() => setMatchDialog({ ...matchDialog, selected: candidate.remoteBookID })}
                        />
                        <span>
                          <strong>{candidate.title}</strong>
                          {candidate.authors.length > 0 && ` — ${candidate.authors.join(", ")}`}
                          {candidate.reason && <em className={styles.dim}> ({candidate.reason})</em>}
                        </span>
                      </label>
                    </li>
                  ))}
                </ul>
                <div className={styles.row}>
                  <button className={styles.button} onClick={() => setMatchDialog(null)}>
                    Cancel
                  </button>
                  <button
                    className={styles.processButton}
                    disabled={!matchDialog.selected || matchLink.isPending}
                    onClick={() =>
                      void matchLink.mutateAsync({
                        recordID: matchDialog.recordID,
                        remoteBookID: matchDialog.selected!,
                      })
                    }
                  >
                    Link Selected
                  </button>
                </div>
              </>
            )}
          </div>
        </div>
      )}
    </div>
  );
}

function AsinSection({
  row,
  connection,
  onSaved,
}: {
  row: LibraryRow;
  connection: string;
  onSaved: (fresh: Library) => void;
}) {
  const asin = row.identifiers.find((identifier) =>
    identifier.kind.toLowerCase().includes("asin"),
  )?.value;
  const [mode, setMode] = useState<"idle" | "manual" | "search">("idle");
  const [manualValue, setManualValue] = useState("");
  const [searchTitle, setSearchTitle] = useState(row.title);
  const [searchAuthor, setSearchAuthor] = useState(row.author ?? "");
  const [candidates, setCandidates] = useState<AsinCandidate[] | null>(null);
  const [selectedAsin, setSelectedAsin] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const connectionParam = connection !== "local" ? `?connection=${connection}` : "";

  // What does this ASIN identify, according to the online catalog?
  const { data: resolved } = useQuery<AsinResolve>({
    queryKey: ["asin-resolve", asin],
    queryFn: () => api<AsinResolve>(`/api/library/asin/resolve?asin=${asin}`),
    enabled: !!asin,
    staleTime: 24 * 3600 * 1000,
    retry: false,
  });

  const save = useMutation({
    mutationFn: (value: string) =>
      api<Library>(`/api/library/editions/${row.recordID}/identifier${connectionParam}`, {
        method: "PUT",
        body: JSON.stringify({ kind: "asin", value, pushToStoryteller: false }),
      }),
    onSuccess: (fresh) => {
      onSaved(fresh);
      setMode("idle");
      setError(null);
    },
    onError: (err) => setError(String(err)),
  });

  const search = useMutation({
    mutationFn: () =>
      api<{ candidates: AsinCandidate[] }>(
        `/api/library/asin/search?title=${encodeURIComponent(searchTitle)}${searchAuthor ? `&author=${encodeURIComponent(searchAuthor)}` : ""}`,
      ),
    onSuccess: (result) => {
      setCandidates(result.candidates);
      setSelectedAsin(result.candidates[0]?.asin ?? null);
      setError(result.candidates.length === 0 ? "No matches found in the catalog." : null);
    },
    onError: (err) => setError(String(err)),
  });

  if (!row.recordID) return null;

  return (
    <div className={styles.asinBlock}>
      {asin ? (
        <div className={styles.asinKnown}>
          <div className={styles.identifier}>
            <span className={styles.dim}>asin</span>
            <code>{asin}</code>
          </div>
          <p className={styles.dim}>
            {resolved == null
              ? "Checking what this ASIN identifies…"
              : resolved.found
                ? `Identifies: ${resolved.title}${resolved.authors.length > 0 ? ` — ${resolved.authors.join(", ")}` : ""}${resolved.narrators.length > 0 ? ` (narrated by ${resolved.narrators.join(", ")})` : ""}`
                : "This ASIN was not found in the online catalog."}
          </p>
          {resolved?.found && resolved.title && resolved.title !== row.title && (
            <p className={styles.asinMismatch}>
              Note: the book is named “{row.title}” locally but the ASIN identifies “
              {resolved.title}”.
            </p>
          )}
        </div>
      ) : (
        <p className={styles.dim}>No known ASIN for this book.</p>
      )}

      {mode === "idle" && (
        <div className={styles.row}>
          <button className={styles.buttonSmall} onClick={() => setMode("search")}>
            {asin ? "Find Different ASIN…" : "Find ASIN…"}
          </button>
          <button
            className={styles.buttonSmall}
            onClick={() => {
              setManualValue(asin ?? "");
              setMode("manual");
            }}
          >
            Set ASIN Manually…
          </button>
        </div>
      )}

      {mode === "manual" && (
        <div className={styles.isbnEditor}>
          <input
            className={styles.input}
            placeholder="ASIN (10 characters, e.g. B0ABC12DEF)"
            value={manualValue}
            onChange={(event) => setManualValue(event.target.value)}
          />
          <div className={styles.row}>
            <button className={styles.buttonSmall} onClick={() => setMode("idle")}>
              Cancel
            </button>
            <button
              className={styles.buttonSmall}
              disabled={!manualValue.trim() || save.isPending}
              onClick={() => void save.mutateAsync(manualValue.trim())}
            >
              Save ASIN
            </button>
          </div>
        </div>
      )}

      {mode === "search" && (
        <div className={styles.isbnEditor}>
          <input
            className={styles.input}
            placeholder="Title"
            value={searchTitle}
            onChange={(event) => setSearchTitle(event.target.value)}
          />
          <input
            className={styles.input}
            placeholder="Author (optional)"
            value={searchAuthor}
            onChange={(event) => setSearchAuthor(event.target.value)}
          />
          <div className={styles.row}>
            <button className={styles.buttonSmall} onClick={() => setMode("idle")}>
              Cancel
            </button>
            <button
              className={styles.buttonSmall}
              disabled={!searchTitle.trim() || search.isPending}
              onClick={() => void search.mutateAsync()}
            >
              {search.isPending ? "Searching…" : "Search Catalog"}
            </button>
          </div>
          {candidates && candidates.length > 0 && (
            <>
              <ul className={styles.candidateList}>
                {candidates.map((candidate) => (
                  <li key={candidate.asin}>
                    <label className={styles.row}>
                      <input
                        type="radio"
                        name="asin-candidate"
                        checked={selectedAsin === candidate.asin}
                        onChange={() => setSelectedAsin(candidate.asin)}
                      />
                      <span>
                        <strong>{candidate.title}</strong>
                        {candidate.authors.length > 0 && ` — ${candidate.authors.join(", ")}`}
                        {candidate.narrators.length > 0 && (
                          <em className={styles.dim}> · narrated by {candidate.narrators.join(", ")}</em>
                        )}{" "}
                        <code>{candidate.asin}</code>
                      </span>
                    </label>
                  </li>
                ))}
              </ul>
              <button
                className={styles.buttonSmall}
                disabled={!selectedAsin || save.isPending}
                onClick={() => selectedAsin && void save.mutateAsync(selectedAsin)}
              >
                Save Selected ASIN
              </button>
            </>
          )}
        </div>
      )}
      {error && <p className={styles.error}>{error}</p>}
    </div>
  );
}

function matchesFilter(row: LibraryRow, filter: Filter): boolean {
  switch (filter) {
    case "all":
      return true;
    case "attention":
      return (
        row.suggestedRemoteTitle != null ||
        ["needsReview", "broken", "likelyBroken"].includes(row.localQualityVerdict ?? "") ||
        ["needsReview", "broken", "likelyBroken"].includes(row.remoteQualityVerdict ?? "")
      );
    case "local":
      return row.presence === "Local";
    case "remote":
      return row.presence === "Storyteller";
    case "both":
      return row.presence === "Both";
  }
}

import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { X, XCircle } from "lucide-react";
import { useMemo, useState } from "react";
import { api } from "../../api/client";
import { useConnection } from "../../stores/connection";
import styles from "./QualityPage.module.css";

interface Target {
  kind: "local" | "remote" | "standalone";
  productID: string | null;
  connectionID: string | null;
  bookID: string | null;
  assetID: string | null;
  path: string | null;
}

interface Run {
  id: string;
  lifecycle: string;
  mode: string;
  verdict: string | null;
  evidenceAdequacy: string | null;
  progress: number;
  progressMessage: string | null;
  error: string | null;
  startedAt: string;
  updatedAt: string;
  completedAt: string | null;
  epubCompliance: {
    epubVersion: string;
    checkerVersion: string;
    fatalCount: number;
    errorCount: number;
    warningCount: number;
  } | null;
  metrics: Record<string, number>;
  findings: {
    dimension: string;
    code: string;
    verdict: string;
    confidence: string;
    summary: string;
  }[];
}

interface Artifact {
  id: string;
  target: Target;
  title: string;
  author: string | null;
  source: string;
  checkedAt: string | null;
  history: Run[];
}

interface QueueState {
  currentRunID: string | null;
  isBusy: boolean;
  progress: number | null;
  status: string;
  error: string | null;
  revision: number;
}

const scopes = [
  ["all", "All"],
  ["attention", "Needs Attention"],
  ["unchecked", "Not Checked"],
  ["passed", "Likely Correct"],
] as const;
type Scope = (typeof scopes)[number][0];

const verdictLabels: Record<string, string> = {
  likelyCorrect: "Likely correct",
  needsReview: "Review needed",
  inconclusive: "Inconclusive",
  likelyBroken: "Likely broken",
  broken: "Broken",
};

function presented(artifact: Artifact): Run | null {
  return (
    artifact.history.find((run) => run.lifecycle === "running" || run.lifecycle === "queued") ??
    artifact.history.find((run) => run.lifecycle === "completed") ??
    artifact.history[0] ??
    null
  );
}

function outcomeLabel(artifact: Artifact): string {
  const run = presented(artifact);
  if (!run) return "Not checked";
  switch (run.lifecycle) {
    case "queued":
      return "Queued";
    case "running":
      return "Checking";
    case "failed":
      return "Audit failed";
    case "cancelled":
      return "Cancelled";
    default:
      return verdictLabels[run.verdict ?? ""] ?? "Complete";
  }
}

function isProblem(run: Run | null): boolean {
  if (!run) return false;
  if (run.lifecycle === "failed") return true;
  return ["broken", "likelyBroken", "needsReview", "inconclusive"].includes(run.verdict ?? "");
}

const metricLabels: [string, string][] = [
  ["primaryCoverage", "Primary coverage"],
  ["weightedSimilarity", "Clip similarity"],
  ["clipCount", "Timed clips"],
  ["audioCount", "Audio files"],
  ["largestPrimaryOmissionRunTokens", "Largest omission run"],
];

export function QualityPage() {
  const queryClient = useQueryClient();
  const connected = useConnection((s) => s.sseConnected);
  const [scope, setScope] = useState<Scope>("all");
  const [query, setQuery] = useState("");
  const [selectedID, setSelectedID] = useState<string | null>(null);
  const [thorough, setThorough] = useState(false);

  const { data: queue } = useQuery<QueueState>({
    queryKey: ["quality"],
    queryFn: () => api<QueueState>("/api/quality/queue"),
    refetchInterval: connected ? false : 5000,
    staleTime: Infinity,
    retry: false,
  });

  const { data: artifacts } = useQuery<Artifact[]>({
    queryKey: ["quality-artifacts", queue?.revision ?? 0],
    queryFn: () => api<Artifact[]>("/api/quality/artifacts"),
    staleTime: Infinity,
    retry: false,
  });

  const enqueue = useMutation({
    mutationFn: (targets: Target[]) =>
      api<QueueState>("/api/quality/enqueue", {
        method: "POST",
        body: JSON.stringify({ targets, thorough }),
      }),
    onSuccess: (fresh) => {
      queryClient.setQueryData(["quality"], fresh);
    },
  });

  const cancel = useMutation({
    mutationFn: (path: string) => api<QueueState>(path, { method: "POST", body: "{}" }),
    onSuccess: (fresh) => queryClient.setQueryData(["quality"], fresh),
  });

  const list = artifacts ?? [];
  const counts = useMemo(
    () => ({
      all: list.length,
      attention: list.filter((artifact) => isProblem(presented(artifact))).length,
      unchecked: list.filter((artifact) => artifact.history.length === 0).length,
      passed: list.filter((artifact) => presented(artifact)?.verdict === "likelyCorrect").length,
    }),
    [list],
  );

  const visible = useMemo(() => {
    const trimmed = query.trim().toLowerCase();
    return list.filter((artifact) => {
      const run = presented(artifact);
      const scopeMatch =
        scope === "all"
          ? true
          : scope === "attention"
            ? isProblem(run)
            : scope === "unchecked"
              ? artifact.history.length === 0
              : run?.verdict === "likelyCorrect";
      if (!scopeMatch) return false;
      if (!trimmed) return true;
      return (
        artifact.title.toLowerCase().includes(trimmed) ||
        artifact.author?.toLowerCase().includes(trimmed) ||
        artifact.source.toLowerCase().includes(trimmed)
      );
    });
  }, [list, scope, query]);

  const selected = list.find((artifact) => artifact.id === selectedID) ?? null;
  const selectedRun = selected ? presented(selected) : null;

  return (
    <div className={styles.page}>
      <header className={styles.header}>
        <h1 className={styles.title}>ReadAloud Quality</h1>
        <span className={styles.counts}>
          {visible.length} of {list.length} ReadAlouds
        </span>
        <input
          className={styles.search}
          placeholder="Search title, author, source"
          value={query}
          onChange={(event) => setQuery(event.target.value)}
        />
        <span className={styles.spacer} />
        <label className={styles.depth}>
          <span>Depth</span>
          <div className={styles.segmented} role="radiogroup" aria-label="Audit depth">
            <button
              role="radio"
              aria-checked={!thorough}
              data-active={!thorough || undefined}
              onClick={() => setThorough(false)}
            >
              Standard
            </button>
            <button
              role="radio"
              aria-checked={thorough}
              data-active={thorough || undefined}
              onClick={() => setThorough(true)}
            >
              Thorough
            </button>
          </div>
        </label>
      </header>

      <div className={styles.scopeBar} role="radiogroup" aria-label="Scope">
        {scopes.map(([key, label]) => (
          <button
            key={key}
            role="radio"
            aria-checked={scope === key}
            data-active={scope === key || undefined}
            onClick={() => setScope(key)}
          >
            {label} {counts[key] > 0 && <em>{counts[key]}</em>}
          </button>
        ))}
      </div>

      <div className={styles.statusBar} aria-live="polite">
        {queue?.isBusy ? (
          <>
            <span className={styles.statusText}>{queue.status}</span>
            {queue.progress != null && (
              <div className={styles.track}>
                <div className={styles.fill} style={{ width: `${queue.progress * 100}%` }} />
              </div>
            )}
            <button
              className={styles.buttonSmall}
              onClick={() => void cancel.mutateAsync("/api/quality/cancel-current")}
            >
              <XCircle size={13} aria-hidden /> Cancel Current
            </button>
            <button
              className={styles.buttonSmall}
              onClick={() => {
                if (confirm("Cancel every queued and running quality check?"))
                  void cancel.mutateAsync("/api/quality/cancel-all");
              }}
            >
              Cancel All
            </button>
          </>
        ) : (
          <span className={styles.statusIdle}>{queue?.status || "Quality queue idle"}</span>
        )}
      </div>

      <div className={styles.splitRegion}>
        <div className={styles.tableWrap}>
          <table className={styles.table}>
            <thead>
              <tr>
                <th>ReadAloud</th>
                <th>Outcome</th>
                <th>Source</th>
                <th>Checked</th>
              </tr>
            </thead>
            <tbody>
              {visible.map((artifact) => (
                <tr
                  key={artifact.id}
                  data-selected={artifact.id === selectedID || undefined}
                  onClick={() => setSelectedID(artifact.id)}
                >
                  <td>
                    <div className={styles.rowTitle}>{artifact.title}</div>
                    {artifact.author && (
                      <div className={styles.rowAuthor}>{artifact.author}</div>
                    )}
                  </td>
                  <td>
                    <span
                      className={styles.outcome}
                      data-problem={isProblem(presented(artifact)) || undefined}
                    >
                      {outcomeLabel(artifact)}
                    </span>
                  </td>
                  <td className={styles.tdSecondary}>{artifact.source}</td>
                  <td className={styles.tdSecondary}>
                    {artifact.checkedAt
                      ? new Date(artifact.checkedAt).toLocaleDateString()
                      : "—"}
                  </td>
                </tr>
              ))}
              {visible.length === 0 && (
                <tr>
                  <td colSpan={4} className={styles.empty}>
                    No ReadAlouds in this scope.
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
                <div className={styles.rowAuthor}>{selected.source}</div>
              </div>
              <button
                className={styles.close}
                onClick={() => setSelectedID(null)}
                aria-label="Close"
              >
                <X size={16} />
              </button>
            </header>

            <button
              className={styles.primary}
              disabled={enqueue.isPending}
              onClick={() => void enqueue.mutateAsync([selected.target])}
            >
              {selected.history.length > 0 ? "Check Again" : "Queue Check"}
            </button>

            {selectedRun && (
              <>
                <section className={styles.section}>
                  <h3>Result</h3>
                  <p
                    className={styles.verdict}
                    data-problem={isProblem(selectedRun) || undefined}
                  >
                    {selectedRun.lifecycle === "completed"
                      ? (verdictLabels[selectedRun.verdict ?? ""] ?? "Complete")
                      : selectedRun.lifecycle}
                  </p>
                  <p className={styles.dim}>
                    Mode {selectedRun.mode}
                    {selectedRun.evidenceAdequacy &&
                      ` · Evidence ${selectedRun.evidenceAdequacy}`}
                    {selectedRun.epubCompliance &&
                      ` · EPUB ${selectedRun.epubCompliance.epubVersion} compliant (EPUBCheck ${selectedRun.epubCompliance.checkerVersion}${
                        selectedRun.epubCompliance.warningCount > 0
                          ? `, ${selectedRun.epubCompliance.warningCount} warnings`
                          : ""
                      })`}
                    {" · "}
                    {new Date(selectedRun.updatedAt).toLocaleString()}
                  </p>
                  {selectedRun.error && (
                    <p className={styles.errorCard}>{selectedRun.error}</p>
                  )}
                </section>

                {Object.keys(selectedRun.metrics).length > 0 && (
                  <section className={styles.section}>
                    <h3>Evidence</h3>
                    <dl className={styles.metrics}>
                      {metricLabels
                        .filter(([key]) => selectedRun.metrics[key] != null)
                        .map(([key, label]) => (
                          <div key={key} className={styles.metric}>
                            <dt>{label}</dt>
                            <dd>
                              {key.toLowerCase().includes("coverage") ||
                              key.toLowerCase().includes("similarity")
                                ? `${(selectedRun.metrics[key]! * 100).toFixed(1)}%`
                                : selectedRun.metrics[key]!.toLocaleString()}
                            </dd>
                          </div>
                        ))}
                    </dl>
                  </section>
                )}

                {selectedRun.findings.length > 0 && (
                  <section className={styles.section}>
                    <h3>Findings</h3>
                    {selectedRun.findings.map((finding, index) => (
                      <div key={index} className={styles.finding}>
                        <div className={styles.findingHead}>
                          <span>{finding.code}</span>
                          <span className={styles.dim}>
                            {finding.dimension} · {finding.confidence}
                          </span>
                        </div>
                        <p>{finding.summary}</p>
                      </div>
                    ))}
                  </section>
                )}

                {selected.history.length > 1 && (
                  <section className={styles.section}>
                    <h3>History</h3>
                    {selected.history.slice(0, 8).map((run) => (
                      <div key={run.id} className={styles.historyRow}>
                        <span>{new Date(run.updatedAt).toLocaleDateString()}</span>
                        <span className={styles.dim}>
                          {run.lifecycle === "completed"
                            ? (verdictLabels[run.verdict ?? ""] ?? "Complete")
                            : run.lifecycle}{" "}
                          · {run.mode}
                        </span>
                      </div>
                    ))}
                  </section>
                )}
              </>
            )}
          </aside>
        )}
      </div>
    </div>
  );
}

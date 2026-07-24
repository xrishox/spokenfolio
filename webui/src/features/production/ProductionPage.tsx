import { Link, useNavigate, useParams, useSearch } from "@tanstack/react-router";
import { Pause, Play, XCircle } from "lucide-react";
import { useMemo, useState } from "react";
import { useJobControls } from "../../api/jobs";
import { useJobs, useQueueStatus } from "../../api/queries";
import type { JobSummary } from "../../api/types";
import { clickRow, emptySelection, type SelectionState } from "../../lib/selection";
import { CreatePage } from "./CreatePage";
import { JobInspector } from "./JobInspector";
import styles from "./ProductionPage.module.css";

const modes = ["create", "queue", "history"] as const;
type Mode = (typeof modes)[number];

function relative(dateString: string): string {
  const seconds = (Date.now() - Date.parse(dateString)) / 1000;
  if (seconds < 90) return "just now";
  if (seconds < 3600) return `${Math.round(seconds / 60)}m ago`;
  if (seconds < 86400) return `${Math.round(seconds / 3600)}h ago`;
  return `${Math.round(seconds / 86400)}d ago`;
}

export function ProductionPage() {
  const params = useParams({ strict: false }) as { mode?: Mode };
  const mode: Mode = modes.includes(params.mode as Mode) ? (params.mode as Mode) : "queue";
  const search = useSearch({ strict: false }) as { job?: string };
  const navigate = useNavigate();
  const { data: queue } = useQueueStatus();
  const { data: jobs } = useJobs();
  const controls = useJobControls();
  const [selection, setSelection] = useState<SelectionState>(emptySelection);
  const [query, setQuery] = useState("");

  const terminal = (job: JobSummary) =>
    job.lifecycle === "completed" || job.lifecycle === "cancelled";
  const visible = useMemo(() => {
    const scoped = (jobs ?? []).filter((job) =>
      mode === "history" ? terminal(job) : !terminal(job),
    );
    const trimmed = query.trim().toLowerCase();
    if (!trimmed) return scoped;
    return scoped.filter(
      (job) =>
        job.title.toLowerCase().includes(trimmed) ||
        job.author?.toLowerCase().includes(trimmed),
    );
  }, [jobs, mode, query]);

  const active = (jobs ?? []).find((job) => job.lifecycle === "running");
  const openJob = search.job;
  const visibleIDs = visible.map((job) => job.id);
  const selectedIDs = [...selection.ids].filter((id) => visibleIDs.includes(id));

  const toggleRow = (id: string, event: React.MouseEvent) => {
    const plain = !event.metaKey && !event.ctrlKey && !event.shiftKey;
    setSelection((prev) =>
      clickRow(prev, visibleIDs, id, {
        meta: event.metaKey || event.ctrlKey,
        shift: event.shiftKey,
      }),
    );
    if (plain) {
      void navigate({
        to: "/production/$mode",
        params: { mode },
        search: { job: id },
      });
    }
  };

  if (mode === "create") {
    return <CreatePage />;
  }

  return (
    <div className={styles.page}>
      <header className={styles.header}>
        <h1 className={styles.title}>Production</h1>
        <span className={styles.counts}>
          {queue ? `${queue.runningCount} running · ${queue.queuedCount} waiting` : ""}
        </span>
        <nav className={styles.modes} aria-label="Production mode">
          {modes.map((m) => (
            <Link
              key={m}
              to="/production/$mode"
              params={{ mode: m }}
              className={styles.modeTab}
              data-active={m === mode || undefined}
            >
              {m[0].toUpperCase() + m.slice(1)}
            </Link>
          ))}
        </nav>
        <span className={styles.spacer} />
        {queue?.isSuspended ? (
          <button className={styles.button} disabled={controls.busy} onClick={() => void controls.resumeQueue()}>
            <Play size={14} aria-hidden /> Resume Queue
          </button>
        ) : (
          <button className={styles.button} disabled={controls.busy} onClick={() => void controls.pauseQueue(false)}>
            <Pause size={14} aria-hidden /> Pause After Current
          </button>
        )}
      </header>

      {active && (
        <div className={styles.activeBanner} aria-live="polite">
          <span className={styles.activeTitle}>{active.title}</span>
          <span className={styles.activeStatus}>{active.statusTitle}</span>
          {active.progress != null && (
            <div className={styles.track}>
              <div className={styles.fill} style={{ width: `${active.progress * 100}%` }} />
            </div>
          )}
          <button
            className={styles.buttonSmall}
            disabled={controls.busy}
            onClick={() => void controls.pauseQueue(true)}
          >
            Pause Now
          </button>
        </div>
      )}

      <div className={styles.toolbar}>
        <input
          className={styles.search}
          placeholder={mode === "history" ? "Search history" : "Search queue"}
          value={query}
          onChange={(event) => setQuery(event.target.value)}
        />
        {selectedIDs.length > 0 && (
          <div className={styles.selectionBar}>
            <span>{selectedIDs.length} selected</span>
            <button className={styles.buttonSmall} disabled={controls.busy} onClick={() => void controls.resumeJobs(selectedIDs)}>
              <Play size={13} aria-hidden /> Resume
            </button>
            <button className={styles.buttonSmall} disabled={controls.busy} onClick={() => void controls.pauseJobs(selectedIDs)}>
              <Pause size={13} aria-hidden /> Pause
            </button>
            <button
              className={styles.buttonSmall}
              disabled={controls.busy}
              onClick={() => {
                if (confirm(`Cancel ${selectedIDs.length} job(s)? Completed work stays on disk.`))
                  void controls.cancelJobs(selectedIDs);
              }}
            >
              <XCircle size={13} aria-hidden /> Cancel…
            </button>
          </div>
        )}
      </div>

      <div className={styles.splitRegion}>
        <div className={styles.tableWrap}>
          <table className={styles.table}>
            <thead>
              <tr>
                {mode === "queue" && <th className={styles.thNarrow}>#</th>}
                <th>Title</th>
                <th>Type</th>
                <th>{mode === "history" ? "Result" : "State"}</th>
                <th>Updated</th>
              </tr>
            </thead>
            <tbody>
              {visible.map((job) => (
                <tr
                  key={job.id}
                  onClick={(event) => toggleRow(job.id, event)}
                  data-selected={selection.ids.has(job.id) || job.id === openJob || undefined}
                  aria-selected={selection.ids.has(job.id)}
                >
                  {mode === "queue" && (
                    <td className={styles.tdNarrow}>{job.queuePosition ?? ""}</td>
                  )}
                  <td>
                    <div className={styles.jobTitle}>{job.title}</div>
                    {job.author && <div className={styles.jobAuthor}>{job.author}</div>}
                  </td>
                  <td className={styles.tdSecondary}>{job.kindTitle}</td>
                  <td>
                    <span data-lifecycle={job.lifecycle} className={styles.state}>
                      {job.statusTitle}
                    </span>
                    {job.lifecycle === "running" && job.progress != null && (
                      <div className={styles.track}>
                        <div className={styles.fill} style={{ width: `${job.progress * 100}%` }} />
                      </div>
                    )}
                  </td>
                  <td className={styles.tdSecondary}>{relative(job.updatedAt)}</td>
                </tr>
              ))}
              {visible.length === 0 && (
                <tr>
                  <td colSpan={5} className={styles.empty}>
                    {mode === "history" ? "No finished jobs yet." : "The queue is empty."}
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
        {openJob && (
          <JobInspector
            id={openJob}
            onClose={() =>
              void navigate({ to: "/production/$mode", params: { mode }, search: {} })
            }
          />
        )}
      </div>
    </div>
  );
}

import { X } from "lucide-react";
import { useJobControls, useJobDetail } from "../../api/jobs";
import { StageProgress } from "../../components/StageProgress";
import styles from "./JobInspector.module.css";

function bytes(value: number): string {
  if (value >= 1 << 30) return `${(value / (1 << 30)).toFixed(2)} GB`;
  if (value >= 1 << 20) return `${(value / (1 << 20)).toFixed(1)} MB`;
  return `${Math.max(1, Math.round(value / 1024))} KB`;
}

export function JobInspector({ id, onClose }: { id: string; onClose: () => void }) {
  const { data: job, error } = useJobDetail(id);
  const controls = useJobControls();

  if (error) {
    return (
      <aside className={styles.inspector}>
        <button className={styles.close} onClick={onClose} aria-label="Close inspector">
          <X size={16} />
        </button>
        <p className={styles.error}>{String(error)}</p>
      </aside>
    );
  }
  if (!job) return <aside className={styles.inspector}>Loading…</aside>;

  const { summary, settings } = job;
  const terminal = summary.lifecycle === "completed" || summary.lifecycle === "cancelled";

  return (
    <aside className={styles.inspector} aria-label={`Job ${summary.title}`}>
      <header className={styles.header}>
        <div>
          <h2 className={styles.title}>{summary.title}</h2>
          {summary.author && <div className={styles.author}>{summary.author}</div>}
          <div className={styles.status} data-lifecycle={summary.lifecycle}>
            {summary.statusTitle}
            {job.batch && ` · Book ${job.batch.ordinal} of ${job.batch.count}`}
          </div>
        </div>
        <button className={styles.close} onClick={onClose} aria-label="Close inspector">
          <X size={16} />
        </button>
      </header>

      {job.lastError && summary.lifecycle === "needsAttention" && (
        <div className={styles.errorCard} role="alert">
          {job.lastError}
        </div>
      )}

      {!terminal && (
        <div className={styles.actions}>
          {summary.lifecycle === "needsAttention" || summary.lifecycle === "paused" ? (
            <button className={styles.button} disabled={controls.busy} onClick={() => void controls.resumeJobs([id])}>
              {summary.lifecycle === "needsAttention" ? "Retry" : "Resume"}
            </button>
          ) : (
            <button className={styles.button} disabled={controls.busy} onClick={() => void controls.pauseJobs([id])}>
              Pause
            </button>
          )}
          <button
            className={styles.button}
            disabled={controls.busy}
            onClick={() => {
              if (confirm("Cancel this job? Completed work stays on disk."))
                void controls.cancelJobs([id]);
            }}
          >
            Cancel…
          </button>
        </div>
      )}

      <section className={styles.section}>
        <h3 className={styles.sectionTitle}>Stages</h3>
        <StageProgress stages={job.stages} />
      </section>

      {job.audiobookProgress && (
        <section className={styles.section}>
          <h3 className={styles.sectionTitle}>Chapters</h3>
          <p className={styles.detail}>
            {job.audiobookProgress.currentChapterIndex != null
              ? `Chapter ${job.audiobookProgress.currentChapterIndex + 1} of ${job.audiobookProgress.totalChapters}`
              : `${job.audiobookProgress.totalChapters} chapters`}
            {job.audiobookProgress.currentChapterTitle
              ? ` — ${job.audiobookProgress.currentChapterTitle}`
              : ""}
            {job.audiobookProgress.reusedChapters > 0 &&
              ` (${job.audiobookProgress.reusedChapters} reused)`}
          </p>
        </section>
      )}

      <section className={styles.section}>
        <h3 className={styles.sectionTitle}>Requested Settings</h3>
        <dl className={styles.grid}>
          <dt>Voice</dt>
          <dd className="mono">{settings.voiceID}</dd>
          <dt>AAC</dt>
          <dd>
            {settings.bitrateKbps} kbps · {settings.workers} workers
          </dd>
          <dt>Pauses</dt>
          <dd>
            ¶ {settings.paragraphPauseSeconds}s · ch {settings.chapterPauseSeconds}s
          </dd>
          <dt>Titles</dt>
          <dd>{settings.announceTitles ? "Announced" : "Not announced"}</dd>
          {settings.readAloudBitrateKbps != null && (
            <>
              <dt>ReadAloud</dt>
              <dd>
                Opus {settings.readAloudBitrateKbps} kbps ·{" "}
                {settings.readAloudEngine === "synthesis"
                  ? "Exact (no ASR)"
                  : (settings.readAloudEngine ?? "")}
                {settings.readAloudModel ? ` (${settings.readAloudModel})` : ""}
              </dd>
            </>
          )}
          {settings.storytellerProducts.length > 0 && (
            <>
              <dt>Delivery</dt>
              <dd>{settings.storytellerProducts.join(", ")}</dd>
            </>
          )}
        </dl>
      </section>

      {job.runtime && (
        <section className={styles.section}>
          <h3 className={styles.sectionTitle}>Actual Siri Runtime</h3>
          <dl className={styles.grid}>
            <dt>Engine</dt>
            <dd className="mono">
              {job.runtime.backendID}/{job.runtime.modelID}
            </dd>
            <dt>Voice</dt>
            <dd className="mono">
              {job.runtime.voiceID}
              {job.runtime.voiceRevision ? ` v${job.runtime.voiceRevision}` : ""}
            </dd>
            {job.runtime.macOSVersion && (
              <>
                <dt>macOS</dt>
                <dd>
                  {job.runtime.macOSVersion} ({job.runtime.macOSBuild})
                </dd>
              </>
            )}
            {job.runtime.frameworkVersion && (
              <>
                <dt>Framework</dt>
                <dd>SiriTTSService {job.runtime.frameworkVersion}</dd>
              </>
            )}
          </dl>
        </section>
      )}

      {job.products.length > 0 && (
        <section className={styles.section}>
          <h3 className={styles.sectionTitle}>Verified Products</h3>
          {job.products.map((product) => (
            <div key={product.kind + product.path} className={styles.product}>
              <div className={styles.productKind}>
                {product.kind} · {bytes(product.sizeBytes)}
              </div>
              <code className={styles.productPath} title={product.path}>
                {product.path}
              </code>
            </div>
          ))}
        </section>
      )}

      {job.warnings.length > 0 && (
        <section className={styles.section}>
          <h3 className={styles.sectionTitle}>Warnings</h3>
          {job.warnings.map((warning) => (
            <p key={warning} className={styles.warning}>
              {warning}
            </p>
          ))}
        </section>
      )}
    </aside>
  );
}

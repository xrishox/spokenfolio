import { Check, CircleDashed, Loader2, Minus, X } from "lucide-react";
import type { JobStage } from "../api/types";
import styles from "./StageProgress.module.css";

/** Vertical stage timeline: ○ pending, spinner+bar running, ✓ done,
 *  ✕ failed/needs attention, – skipped. */
export function StageProgress({ stages }: { stages: JobStage[] }) {
  return (
    <ol className={styles.list}>
      {stages.map((stage) => (
        <li key={stage.stage} className={styles.row} data-status={stage.status}>
          <span className={styles.icon} aria-hidden>
            {stage.status === "succeeded" ? (
              <Check size={13} />
            ) : stage.status === "running" ? (
              <Loader2 size={13} className={styles.spinner} />
            ) : stage.status === "needsAttention" || stage.status === "cancelled" ? (
              <X size={13} />
            ) : stage.status === "skipped" ? (
              <Minus size={13} />
            ) : (
              <CircleDashed size={13} />
            )}
          </span>
          <div className={styles.body}>
            <div className={styles.titleRow}>
              <span className={styles.title}>{stage.title}</span>
              <span className={styles.status}>
                {stage.status === "running" && stage.fraction != null
                  ? `${Math.round(stage.fraction * 100)}%`
                  : stage.statusTitle}
              </span>
            </div>
            {stage.status === "running" && stage.fraction != null && (
              <div className={styles.track} role="progressbar" aria-valuenow={Math.round(stage.fraction * 100)}>
                <div className={styles.fill} style={{ width: `${stage.fraction * 100}%` }} />
              </div>
            )}
            {stage.message && <div className={styles.message}>{stage.message}</div>}
          </div>
        </li>
      ))}
    </ol>
  );
}

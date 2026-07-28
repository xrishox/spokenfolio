import { useMutation, useQuery } from "@tanstack/react-query";
import { X } from "lucide-react";
import { useState } from "react";
import { api } from "../../api/client";
import type { DeletePlan, DeleteResult, DeleteScope, DeleteSlot, Library } from "../../api/types";
import styles from "./MirrorDialog.module.css";
import {
  DELETE_SLOTS,
  buildDeleteRequest,
  buildPlanRequest,
  hasWork,
  needsAcknowledgment,
} from "./deletePayload";

/** Deletes selected product slots locally, on Storyteller, or both. One global
 *  scope applies to every checked slot; the manifest is computed by the same
 *  server planner the desktop uses, so a book acts only where a slot exists in
 *  that scope. Deleting the source EPUB removes the whole local book; any
 *  human-narrated loss requires the acknowledgment checkbox. */
export function DeleteSheet({
  rowIDs,
  connectionParam,
  onClose,
  onDeleted,
}: {
  rowIDs: string[];
  connectionParam: string;
  onClose: () => void;
  onDeleted: (fresh: Library) => void;
}) {
  const [scope, setScope] = useState<DeleteScope>("local");
  const [slots, setSlots] = useState<Record<DeleteSlot, boolean>>({
    m4b: false,
    readAloudEPUB: false,
    humanAudiobook: false,
    humanReadAloudEPUB: false,
    sourceEPUB: false,
  });
  const [acknowledged, setAcknowledged] = useState(false);
  const [result, setResult] = useState<DeleteResult | null>(null);

  const chosenSlots = DELETE_SLOTS.filter((slot) => slots[slot.value]).map((slot) => slot.value);

  const { data: plan } = useQuery<DeletePlan>({
    queryKey: ["delete-plan", rowIDs, chosenSlots, scope, connectionParam],
    queryFn: () =>
      api<DeletePlan>(`/api/library/delete/plan${connectionParam}`, {
        method: "POST",
        body: JSON.stringify(buildPlanRequest(rowIDs, chosenSlots, scope)),
      }),
    enabled: chosenSlots.length > 0,
    staleTime: 0,
  });

  const del = useMutation({
    mutationFn: () =>
      api<DeleteResult>(`/api/library/delete${connectionParam}`, {
        method: "POST",
        body: JSON.stringify(buildDeleteRequest(rowIDs, chosenSlots, scope, acknowledged, plan!)),
      }),
    onSuccess: (fresh) => {
      onDeleted(fresh.library);
      setResult(fresh);
    },
  });

  const requiresAck = plan ? needsAcknowledgment(plan) : false;
  const canDelete =
    !!plan && hasWork(plan) && !del.isPending && (!requiresAck || acknowledged);

  if (result) {
    return (
      <Overlay onClose={onClose} title="Delete">
        <DeleteSummary result={result} />
        <footer className={styles.footer}>
          <span style={{ flex: 1 }} />
          <button className={styles.primary} onClick={onClose}>
            Done
          </button>
        </footer>
      </Overlay>
    );
  }

  return (
    <Overlay onClose={onClose} title="Delete">
      <p className={styles.dim}>
        {rowIDs.length} selected book{rowIDs.length === 1 ? "" : "s"}. Choose what to delete and
        where.
      </p>

      <div className={styles.formats} role="radiogroup" aria-label="Delete from">
        {(["local", "storyteller", "both"] as const).map((value) => (
          <label key={value} className={styles.row}>
            <input
              type="radio"
              name="delete-scope"
              checked={scope === value}
              onChange={() => setScope(value)}
            />
            {value === "local" ? "Local" : value === "storyteller" ? "Storyteller" : "Both"}
          </label>
        ))}
      </div>

      <div className={styles.formats}>
        {DELETE_SLOTS.map((slot) => (
          <label key={slot.value} className={styles.row} style={slot.wholeBook ? { color: "var(--danger, #d33)" } : undefined}>
            <input
              type="checkbox"
              checked={slots[slot.value]}
              onChange={(event) => setSlots((prev) => ({ ...prev, [slot.value]: event.target.checked }))}
            />
            {slot.label}
          </label>
        ))}
      </div>

      <DeleteManifest plan={plan} anySlots={chosenSlots.length > 0} />

      {requiresAck && (
        <label className={styles.row} style={{ color: "var(--danger, #d33)" }}>
          <input
            type="checkbox"
            checked={acknowledged}
            onChange={(event) => setAcknowledged(event.target.checked)}
          />
          I understand this permanently deletes the data above and cannot be undone.
        </label>
      )}

      {del.isError && (
        <p className={styles.error}>
          {del.error instanceof Error ? del.error.message : String(del.error)}
        </p>
      )}

      <footer className={styles.footer}>
        <button className={styles.button} onClick={onClose}>
          Cancel
        </button>
        <span style={{ flex: 1 }} />
        <button
          className={styles.primary}
          style={{ background: "var(--danger, #d33)" }}
          disabled={!canDelete}
          onClick={() => void del.mutateAsync().catch(() => {})}
        >
          {del.isPending ? "Deleting…" : "Delete"}
        </button>
      </footer>
    </Overlay>
  );
}

function Overlay({
  title,
  onClose,
  children,
}: {
  title: string;
  onClose: () => void;
  children: React.ReactNode;
}) {
  return (
    <div className={styles.overlay} role="dialog" aria-modal="true" aria-label={title}>
      <div className={styles.dialog}>
        <header className={styles.header}>
          <h2>{title}</h2>
          <button className={styles.close} onClick={onClose} aria-label="Close">
            <X size={16} />
          </button>
        </header>
        {children}
      </div>
    </div>
  );
}

function DeleteManifest({ plan, anySlots }: { plan: DeletePlan | undefined; anySlots: boolean }) {
  if (!anySlots) {
    return <p className={styles.dim}>Check one or more slots to delete.</p>;
  }
  if (!plan) return <p className={styles.dim}>Computing…</p>;
  if (!hasWork(plan)) {
    return (
      <p className={styles.dim}>
        Nothing to delete — none of the checked slots exist for these books in that scope.
      </p>
    );
  }
  return (
    <div style={{ maxHeight: 180, overflowY: "auto", display: "flex", flexDirection: "column", gap: 8 }}>
      {plan.books.map((book) => (
        <div key={book.rowID}>
          <strong>{book.title}</strong>
          {book.wholeBookLocal && (
            <div style={{ color: "var(--danger, #d33)", fontSize: 12 }}>
              • Deletes the entire local book (source, every local file, and its folder)
            </div>
          )}
          {!book.wholeBookLocal && book.localSlots.length > 0 && (
            <div style={{ fontSize: 12 }}>• Local: {book.localSlots.join(", ")}</div>
          )}
          {book.remoteSlots.length > 0 && (
            <div
              style={{
                fontSize: 12,
                color: book.remoteSlots.some((s) => s.humanNarration) ? "var(--danger, #d33)" : undefined,
              }}
            >
              • Storyteller:{" "}
              {book.remoteSlots.map((s) => s.format + (s.humanNarration ? " (human)" : "")).join(", ")}
            </div>
          )}
        </div>
      ))}
      {plan.skipped.length > 0 && (
        <p className={styles.dim} style={{ fontSize: 12 }}>
          Skipped (no checked slots present): {plan.skipped.map((s) => s.title).join(", ")}
        </p>
      )}
    </div>
  );
}

function DeleteSummary({ result }: { result: DeleteResult }) {
  const changed = result.books.filter(
    (b) => b.wholeBookDeleted || b.localDeleted.length > 0 || b.remoteDeleted.length > 0,
  );
  const blocked = result.books.filter((b) => b.blocked);
  const failed = result.books.filter((b) => b.failures.length > 0);
  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 6 }}>
      <p>
        {changed.length} book{changed.length === 1 ? "" : "s"} updated.
      </p>
      {blocked.length > 0 && (
        <p className={styles.dim} style={{ fontSize: 12 }}>
          Skipped (busy): {blocked.map((b) => `${b.title} — ${b.blocked}`).join("; ")}
        </p>
      )}
      {failed.length > 0 && (
        <p className={styles.error}>
          {failed.flatMap((b) => b.failures.map((f) => `${b.title}: ${f.reason}`)).join("; ")}
        </p>
      )}
    </div>
  );
}

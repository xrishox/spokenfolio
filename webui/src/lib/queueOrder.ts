import type { JobSummary } from "../api/types";

/** Pure helpers for reordering the waiting portion of the production queue.
 *  The server contract (`POST /api/queue/reorder`) wants the COMPLETE set of
 *  non-running, non-terminal job ids in the desired order, so every helper
 *  operates on that full id array — never on a filtered/visible subset. */

export type Lifecycle = JobSummary["lifecycle"];

/** Rows the scheduler allows to be reordered: anything not running and not
 *  terminal (queued, paused, needsAttention). */
export function isReorderable(lifecycle: Lifecycle): boolean {
  return lifecycle !== "running" && lifecycle !== "completed" && lifecycle !== "cancelled";
}

/** Moves `movedID` before/after `targetID`. Returns `ids` unchanged (same
 *  reference) when the move is a no-op or either id is unknown, so callers
 *  can skip a pointless POST with an identity check. */
export function moveRelative(
  ids: readonly string[],
  movedID: string,
  targetID: string,
  edge: "before" | "after",
): readonly string[] {
  if (movedID === targetID) return ids;
  if (!ids.includes(movedID) || !ids.includes(targetID)) return ids;
  const without = ids.filter((id) => id !== movedID);
  const targetIndex = without.indexOf(targetID);
  const insertAt = edge === "before" ? targetIndex : targetIndex + 1;
  const next = [...without.slice(0, insertAt), movedID, ...without.slice(insertAt)];
  return next.every((id, index) => id === ids[index]) ? ids : next;
}

/** Swaps `id` with its neighbor. No-op (same reference) at the edges. */
export function moveStep(
  ids: readonly string[],
  id: string,
  delta: -1 | 1,
): readonly string[] {
  const index = ids.indexOf(id);
  if (index === -1) return ids;
  const other = index + delta;
  if (other < 0 || other >= ids.length) return ids;
  const next = [...ids];
  next[index] = next[other];
  next[other] = id;
  return next;
}

/** Moves `id` to the very top or bottom. No-op (same reference) when it is
 *  already there or unknown. */
export function moveEdge(
  ids: readonly string[],
  id: string,
  edge: "top" | "bottom",
): readonly string[] {
  const index = ids.indexOf(id);
  if (index === -1) return ids;
  if (edge === "top" ? index === 0 : index === ids.length - 1) return ids;
  const without = ids.filter((value) => value !== id);
  return edge === "top" ? [id, ...without] : [...without, id];
}

/** Rebuilds a jobs array with its reorderable subset in `order`, leaving
 *  running/terminal rows exactly where they are. Used for the optimistic
 *  cache update while the reorder POST is in flight. */
export function applyOrder(jobs: readonly JobSummary[], order: readonly string[]): JobSummary[] {
  const byID = new Map(jobs.map((job) => [job.id, job]));
  const queue = order.map((id) => byID.get(id)).filter((job): job is JobSummary => !!job);
  let cursor = 0;
  return jobs.map((job) =>
    isReorderable(job.lifecycle) && cursor < queue.length ? queue[cursor++] : job,
  );
}

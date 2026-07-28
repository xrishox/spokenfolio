import type {
  DeletePlan,
  DeletePlanRequest,
  DeleteRequest,
  DeleteScope,
  DeleteSlot,
} from "../../api/types";

/** The selectable slots, in display order. The source slot is last and
 *  flagged because choosing it deletes the entire local book. */
export const DELETE_SLOTS: readonly { value: DeleteSlot; label: string; wholeBook?: boolean }[] = [
  { value: "m4b", label: "TTS Audiobook (M4B)" },
  { value: "readAloudEPUB", label: "TTS ReadAloud" },
  { value: "humanAudiobook", label: "Human Audiobook" },
  { value: "humanReadAloudEPUB", label: "Human ReadAloud" },
  { value: "sourceEPUB", label: "Source EPUB — deletes the entire local book", wholeBook: true },
];

export function buildPlanRequest(
  rowIDs: string[],
  slots: DeleteSlot[],
  scope: DeleteScope,
): DeletePlanRequest {
  return { rowIDs, slots, scope };
}

/** Books whose deletion is destructive enough to require explicit
 *  acknowledgment: a whole-book delete, or one that loses human-narrated
 *  content that cannot be re-created locally. */
export function acknowledgableRowIDs(plan: DeletePlan): string[] {
  return plan.books.filter((book) => book.wholeBookLocal || book.losesHumanContent).map((book) => book.rowID);
}

export function needsAcknowledgment(plan: DeletePlan): boolean {
  return acknowledgableRowIDs(plan).length > 0;
}

export function hasWork(plan: DeletePlan): boolean {
  return plan.books.length > 0;
}

/** Builds the execute payload. The acknowledged row IDs are sent only when the
 *  user checked the box; the server re-verifies and refuses any unacknowledged
 *  destructive book. */
export function buildDeleteRequest(
  rowIDs: string[],
  slots: DeleteSlot[],
  scope: DeleteScope,
  acknowledged: boolean,
  plan: DeletePlan,
): DeleteRequest {
  return {
    rowIDs,
    slots,
    scope,
    acknowledgedRowIDs: acknowledged ? acknowledgableRowIDs(plan) : [],
  };
}

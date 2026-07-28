import { describe, expect, it } from "vitest";
import type { DeletePlan } from "../../api/types";
import {
  acknowledgableRowIDs,
  buildDeleteRequest,
  hasWork,
  needsAcknowledgment,
} from "./deletePayload";

function plan(
  books: Partial<DeletePlan["books"][number]>[],
  skipped: DeletePlan["skipped"] = [],
): DeletePlan {
  return {
    books: books.map((book, index) => ({
      rowID: book.rowID ?? `row-${index}`,
      title: book.title ?? "Book",
      wholeBookLocal: book.wholeBookLocal ?? false,
      losesHumanContent: book.losesHumanContent ?? false,
      localSlots: book.localSlots ?? [],
      remoteSlots: book.remoteSlots ?? [],
    })),
    skipped,
  };
}

describe("deletePayload", () => {
  it("flags whole-book and human-content books as needing acknowledgment", () => {
    const p = plan([
      { rowID: "a", localSlots: ["m4b"] },
      { rowID: "b", wholeBookLocal: true },
      { rowID: "c", losesHumanContent: true },
    ]);
    expect(acknowledgableRowIDs(p).sort()).toEqual(["b", "c"]);
    expect(needsAcknowledgment(p)).toBe(true);
  });

  it("needs no acknowledgment when nothing destructive is selected", () => {
    const p = plan([{ rowID: "a", localSlots: ["m4b"] }]);
    expect(needsAcknowledgment(p)).toBe(false);
    expect(acknowledgableRowIDs(p)).toEqual([]);
  });

  it("sends acknowledged row IDs only when the box is checked", () => {
    const p = plan([
      { rowID: "a", localSlots: ["m4b"] },
      { rowID: "b", wholeBookLocal: true },
    ]);
    const unchecked = buildDeleteRequest(["a", "b"], ["m4b", "sourceEPUB"], "local", false, p);
    expect(unchecked.acknowledgedRowIDs).toEqual([]);
    const checked = buildDeleteRequest(["a", "b"], ["m4b", "sourceEPUB"], "local", true, p);
    expect(checked.acknowledgedRowIDs).toEqual(["b"]);
    expect(checked.scope).toBe("local");
    expect(checked.slots).toEqual(["m4b", "sourceEPUB"]);
  });

  it("reports whether the plan has any work", () => {
    expect(hasWork(plan([]))).toBe(false);
    expect(hasWork(plan([{ rowID: "a", localSlots: ["m4b"] }]))).toBe(true);
  });
});

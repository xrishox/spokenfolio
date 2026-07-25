import { describe, expect, it } from "vitest";
import { applyOrder, isReorderable, moveEdge, moveRelative, moveStep } from "./queueOrder";
import type { JobSummary } from "../api/types";

const ids = ["a", "b", "c", "d"];

describe("isReorderable", () => {
  it("allows queued, paused, and needsAttention", () => {
    expect(isReorderable("queued")).toBe(true);
    expect(isReorderable("paused")).toBe(true);
    expect(isReorderable("needsAttention")).toBe(true);
  });

  it("rejects running and terminal lifecycles", () => {
    expect(isReorderable("running")).toBe(false);
    expect(isReorderable("completed")).toBe(false);
    expect(isReorderable("cancelled")).toBe(false);
  });
});

describe("moveRelative", () => {
  it("moves before a later target", () => {
    expect(moveRelative(ids, "a", "c", "before")).toEqual(["b", "a", "c", "d"]);
  });

  it("moves after a later target", () => {
    expect(moveRelative(ids, "a", "c", "after")).toEqual(["b", "c", "a", "d"]);
  });

  it("moves before an earlier target", () => {
    expect(moveRelative(ids, "d", "b", "before")).toEqual(["a", "d", "b", "c"]);
  });

  it("moves after an earlier target", () => {
    expect(moveRelative(ids, "d", "a", "after")).toEqual(["a", "d", "b", "c"]);
  });

  it("returns the same reference on a self drop", () => {
    expect(moveRelative(ids, "b", "b", "before")).toBe(ids);
  });

  it("returns the same reference when the move changes nothing", () => {
    expect(moveRelative(ids, "a", "b", "before")).toBe(ids);
    expect(moveRelative(ids, "b", "a", "after")).toBe(ids);
  });

  it("returns the same reference for unknown ids", () => {
    expect(moveRelative(ids, "zz", "b", "before")).toBe(ids);
    expect(moveRelative(ids, "a", "zz", "after")).toBe(ids);
  });
});

describe("moveStep", () => {
  it("moves up and down one position", () => {
    expect(moveStep(ids, "c", -1)).toEqual(["a", "c", "b", "d"]);
    expect(moveStep(ids, "b", 1)).toEqual(["a", "c", "b", "d"]);
  });

  it("clamps at the edges", () => {
    expect(moveStep(ids, "a", -1)).toBe(ids);
    expect(moveStep(ids, "d", 1)).toBe(ids);
  });

  it("ignores unknown ids", () => {
    expect(moveStep(ids, "zz", 1)).toBe(ids);
  });
});

describe("moveEdge", () => {
  it("moves to the top and bottom", () => {
    expect(moveEdge(ids, "c", "top")).toEqual(["c", "a", "b", "d"]);
    expect(moveEdge(ids, "b", "bottom")).toEqual(["a", "c", "d", "b"]);
  });

  it("is a no-op when already at the requested edge", () => {
    expect(moveEdge(ids, "a", "top")).toBe(ids);
    expect(moveEdge(ids, "d", "bottom")).toBe(ids);
  });

  it("ignores unknown ids", () => {
    expect(moveEdge(ids, "zz", "top")).toBe(ids);
  });
});

function job(id: string, lifecycle: JobSummary["lifecycle"]): JobSummary {
  return {
    id,
    title: id,
    author: null,
    kindTitle: "Audiobook",
    statusTitle: lifecycle,
    lifecycle,
    queueDisposition: "",
    queuePosition: null,
    progress: null,
    createdAt: "2026-01-01T00:00:00Z",
    updatedAt: "2026-01-01T00:00:00Z",
  };
}

describe("applyOrder", () => {
  it("reorders only the reorderable rows, keeping others in place", () => {
    const jobs = [
      job("run", "running"),
      job("a", "queued"),
      job("done", "completed"),
      job("b", "paused"),
      job("c", "needsAttention"),
    ];
    const next = applyOrder(jobs, ["c", "a", "b"]);
    expect(next.map((j) => j.id)).toEqual(["run", "c", "done", "a", "b"]);
  });

  it("ignores unknown ids in the order", () => {
    const jobs = [job("a", "queued"), job("b", "queued")];
    const next = applyOrder(jobs, ["b", "zz", "a"]);
    expect(next.map((j) => j.id)).toEqual(["b", "a"]);
  });
});

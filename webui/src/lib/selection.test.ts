import { describe, expect, it } from "vitest";
import { clearSelection, clickRow, emptySelection, pruneSelection, selectAll } from "./selection";

const rows = ["a", "b", "c", "d", "e"];

describe("selection", () => {
  it("plain click selects one and anchors", () => {
    const state = clickRow(emptySelection, rows, "b", {});
    expect([...state.ids]).toEqual(["b"]);
    expect(state.anchor).toBe("b");
  });

  it("meta click toggles without moving other rows", () => {
    let state = clickRow(emptySelection, rows, "b", {});
    state = clickRow(state, rows, "d", { meta: true });
    expect([...state.ids].sort()).toEqual(["b", "d"]);
    state = clickRow(state, rows, "b", { meta: true });
    expect([...state.ids]).toEqual(["d"]);
  });

  it("shift click selects the anchor range in either direction", () => {
    let state = clickRow(emptySelection, rows, "d", {});
    state = clickRow(state, rows, "a", { shift: true });
    expect([...state.ids].sort()).toEqual(["a", "b", "c", "d"]);
    expect(state.anchor).toBe("d");
    state = clickRow(state, rows, "e", { shift: true });
    expect([...state.ids].sort()).toEqual(["d", "e"]);
  });

  it("shift+meta extends the existing selection", () => {
    let state = clickRow(emptySelection, rows, "a", {});
    state = clickRow(state, rows, "e", { meta: true });
    state = clickRow(state, rows, "d", { shift: true, meta: true });
    expect([...state.ids].sort()).toEqual(["a", "d", "e"]);
  });

  it("select all, clear, prune", () => {
    let state = selectAll(rows);
    expect(state.ids.size).toBe(5);
    state = pruneSelection(state, ["b", "c"]);
    expect([...state.ids].sort()).toEqual(["b", "c"]);
    expect(clearSelection().ids.size).toBe(0);
  });
});

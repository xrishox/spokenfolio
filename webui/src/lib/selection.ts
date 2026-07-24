/** Desktop-style table selection over a visible row order: plain click
 *  selects and anchors, ⌘/Ctrl-click toggles, Shift-click selects the
 *  anchor→row range, ⌘A selects all visible, Esc clears. */
export interface SelectionState {
  ids: Set<string>;
  anchor: string | null;
}

export const emptySelection: SelectionState = { ids: new Set(), anchor: null };

export function clickRow(
  state: SelectionState,
  visibleIDs: string[],
  id: string,
  modifiers: { meta?: boolean; shift?: boolean },
): SelectionState {
  if (modifiers.shift && state.anchor) {
    const anchorIndex = visibleIDs.indexOf(state.anchor);
    const targetIndex = visibleIDs.indexOf(id);
    if (anchorIndex !== -1 && targetIndex !== -1) {
      const [start, end] =
        anchorIndex <= targetIndex ? [anchorIndex, targetIndex] : [targetIndex, anchorIndex];
      const range = visibleIDs.slice(start, end + 1);
      // Shift extends from the anchor; with ⌘ held too, add to the
      // existing selection instead of replacing it.
      const base = modifiers.meta ? new Set(state.ids) : new Set<string>();
      for (const value of range) base.add(value);
      return { ids: base, anchor: state.anchor };
    }
  }
  if (modifiers.meta) {
    const ids = new Set(state.ids);
    if (ids.has(id)) ids.delete(id);
    else ids.add(id);
    return { ids, anchor: id };
  }
  return { ids: new Set([id]), anchor: id };
}

export function selectAll(visibleIDs: string[]): SelectionState {
  return { ids: new Set(visibleIDs), anchor: visibleIDs[0] ?? null };
}

export function clearSelection(): SelectionState {
  return emptySelection;
}

/** Drops ids that are no longer visible (filter/search changes). */
export function pruneSelection(
  state: SelectionState,
  visibleIDs: string[],
): SelectionState {
  const visible = new Set(visibleIDs);
  const ids = new Set([...state.ids].filter((id) => visible.has(id)));
  return {
    ids,
    anchor: state.anchor && visible.has(state.anchor) ? state.anchor : null,
  };
}

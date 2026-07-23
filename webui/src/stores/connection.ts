import { create } from "zustand";

/** Live-connection state for the SSE stream; drives the poll fallback and
 *  the reconnecting banner. */
export const useConnection = create<{ sseConnected: boolean }>(() => ({
  sseConnected: false,
}));

export function setSSEConnected(connected: boolean) {
  useConnection.setState({ sseConnected: connected });
}

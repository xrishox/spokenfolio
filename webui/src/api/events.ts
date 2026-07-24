import { QueryClient } from "@tanstack/react-query";
import type { EventTopic } from "./types";

/** One EventSource for the whole app. Each SSE event is a complete topic
 *  snapshot; we hand the payload straight to the query cache keyed by
 *  topic, so pages render pushed data without a refetch. While the stream
 *  is down, `connected` flips false and queries fall back to polling. */
export class EventStream {
  private source: EventSource | null = null;
  private retryDelay = 1000;
  private closed = false;
  connected = false;
  onConnectionChange: ((connected: boolean) => void) | null = null;

  constructor(private readonly queryClient: QueryClient) {}

  start() {
    this.closed = false;
    this.connect();
  }

  stop() {
    this.closed = true;
    this.source?.close();
    this.source = null;
    this.setConnected(false);
  }

  private setConnected(value: boolean) {
    if (this.connected !== value) {
      this.connected = value;
      this.onConnectionChange?.(value);
    }
  }

  private connect() {
    if (this.closed) return;
    const source = new EventSource("/api/events");
    this.source = source;
    source.onopen = () => {
      this.retryDelay = 1000;
      this.setConnected(true);
    };
    source.onerror = () => {
      source.close();
      this.setConnected(false);
      if (!this.closed) {
        setTimeout(() => this.connect(), this.retryDelay);
        this.retryDelay = Math.min(this.retryDelay * 2, 15000);
      }
    };
    const topics: EventTopic[] = [
      "server",
      "queue",
      "jobs",
      "drafts",
      "quality",
      "tools",
      "library",
    ];
    for (const topic of topics) {
      source.addEventListener(topic, (event) => {
        try {
          const payload = JSON.parse((event as MessageEvent).data);
          this.queryClient.setQueryData([topic], payload);
        } catch {
          // A malformed frame is ignored; the poll fallback self-heals.
        }
      });
    }
  }
}

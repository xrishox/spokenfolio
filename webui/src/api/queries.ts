import { useQuery } from "@tanstack/react-query";
import { api } from "./client";
import type { JobSummary, QueueStatus, ServerStatus, Settings, Voices } from "./types";
import { useConnection } from "../stores/connection";

/** Topic-keyed queries. SSE pushes complete snapshots into these keys; when
 *  the stream is down we fall back to polling. */
function usePollFallback() {
  const connected = useConnection((s) => s.sseConnected);
  return connected ? false : 5000;
}

export function useServerStatus() {
  return useQuery<ServerStatus>({
    queryKey: ["server"],
    queryFn: () => api<ServerStatus>("/api/server"),
    refetchInterval: 5000,
    staleTime: 2000,
  });
}

export function useQueueStatus() {
  const refetchInterval = usePollFallback();
  return useQuery<QueueStatus>({
    queryKey: ["queue"],
    queryFn: () => api<QueueStatus>("/api/queue"),
    refetchInterval,
    staleTime: Infinity,
    retry: false,
  });
}

export function useJobs() {
  const refetchInterval = usePollFallback();
  return useQuery<JobSummary[]>({
    queryKey: ["jobs"],
    queryFn: () => api<JobSummary[]>("/api/jobs"),
    refetchInterval,
    staleTime: Infinity,
    retry: false,
  });
}

export function useVoices() {
  return useQuery<Voices>({
    queryKey: ["voices"],
    queryFn: () => api<Voices>("/api/voices"),
    staleTime: 60_000,
  });
}

export function useSettings() {
  return useQuery<Settings>({
    queryKey: ["settings"],
    queryFn: () => api<Settings>("/api/settings"),
    staleTime: 30_000,
    retry: false,
  });
}

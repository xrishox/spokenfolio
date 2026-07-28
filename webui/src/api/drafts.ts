import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { api } from "./client";
import type {
  Draft,
  DraftProcessSettings,
  DraftQueueOutcome,
  ProductionDefaults,
} from "./types";
import { useConnection } from "../stores/connection";

export function useDrafts() {
  const connected = useConnection((s) => s.sseConnected);
  return useQuery<Draft[]>({
    queryKey: ["drafts"],
    queryFn: () => api<Draft[]>("/api/drafts"),
    refetchInterval: connected ? false : 3000,
    staleTime: Infinity,
    retry: false,
  });
}

export function useProductionDefaults() {
  return useQuery<ProductionDefaults>({
    queryKey: ["production-defaults"],
    queryFn: () => api<ProductionDefaults>("/api/production/defaults"),
    staleTime: 5 * 60_000,
    retry: false,
  });
}

export function useDraftActions() {
  const queryClient = useQueryClient();
  const invalidate = () => void queryClient.invalidateQueries({ queryKey: ["drafts"] });

  const remove = useMutation({
    mutationFn: (id: string) => api<void>(`/api/drafts/${id}`, { method: "DELETE" }),
    onSuccess: invalidate,
  });
  const retry = useMutation({
    mutationFn: (id: string) => api<Draft>(`/api/drafts/${id}/retry`, { method: "POST" }),
    onSuccess: invalidate,
  });
  const fromPath = useMutation({
    mutationFn: (path: string) =>
      api<Draft>("/api/drafts/from-path", {
        method: "POST",
        body: JSON.stringify({ path }),
      }),
    onSuccess: invalidate,
  });
  const toggleSection = useMutation({
    mutationFn: ({ id, sectionID, included }: { id: string; sectionID: number; included: boolean }) =>
      api<Draft>(`/api/drafts/${id}`, {
        method: "PATCH",
        body: JSON.stringify({ sections: [{ id: sectionID, included }] }),
      }),
    onSuccess: invalidate,
  });
  const queue = useMutation({
    mutationFn: (drafts: ({ draftID: string; includedSections: number[] } & DraftProcessSettings)[]) =>
      api<{ outcomes: DraftQueueOutcome[] }>("/api/drafts/queue", {
        method: "POST",
        body: JSON.stringify({ drafts }),
      }),
    onSuccess: () => {
      invalidate();
      void queryClient.invalidateQueries({ queryKey: ["jobs"] });
      void queryClient.invalidateQueries({ queryKey: ["queue"] });
    },
  });
  return { remove, retry, fromPath, toggleSection, queue };
}

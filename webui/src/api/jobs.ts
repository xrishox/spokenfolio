import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { api } from "./client";
import type { JobDetail, QueueStatus } from "./types";
import { useConnection } from "../stores/connection";

export function useJobDetail(id: string | undefined) {
  const connected = useConnection((s) => s.sseConnected);
  return useQuery<JobDetail>({
    queryKey: ["job", id],
    queryFn: () => api<JobDetail>(`/api/jobs/${id}`),
    enabled: !!id,
    // Detail is not SSE-pushed; refresh alongside snapshot cadence.
    refetchInterval: connected ? 2000 : 5000,
  });
}

/** Confirmed (non-optimistic) job/queue controls: the desktop semantics
 *  persist intent before signaling, so the UI shows in-flight verbs and
 *  reconciles from the pushed snapshot. Each control returns the fresh
 *  queue status which we seed into the cache immediately. */
function useControl(path: string) {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (body: object) =>
      api<QueueStatus>(path, { method: "POST", body: JSON.stringify(body) }),
    onSuccess: (queue) => {
      queryClient.setQueryData(["queue"], queue);
      void queryClient.invalidateQueries({ queryKey: ["jobs"] });
      void queryClient.invalidateQueries({ queryKey: ["job"] });
    },
  });
}

export function useJobControls() {
  const pause = useControl("/api/jobs/pause");
  const resume = useControl("/api/jobs/resume");
  const cancel = useControl("/api/jobs/cancel");
  const queuePause = useControl("/api/queue/pause");
  const queueResume = useControl("/api/queue/resume");
  const cancelWaiting = useControl("/api/queue/cancel-waiting");
  const reorder = useControl("/api/queue/reorder");
  const runNext = useControl("/api/queue/run-next");
  return {
    pauseJobs: (ids: string[]) => pause.mutateAsync({ ids }),
    resumeJobs: (ids: string[]) => resume.mutateAsync({ ids }),
    cancelJobs: (ids: string[]) => cancel.mutateAsync({ ids }),
    pauseQueue: (interruptActive = false) => queuePause.mutateAsync({ interruptActive }),
    resumeQueue: () => queueResume.mutateAsync({}),
    cancelWaiting: (includeActive = false) => cancelWaiting.mutateAsync({ includeActive }),
    /** Full desired order of ALL non-running, non-terminal job ids. */
    reorderQueue: (ids: string[]) => reorder.mutateAsync({ ids }),
    /** Preempt: this job runs next; a running book pauses safely behind it. */
    runNextJob: (id: string) => runNext.mutateAsync({ id }),
    busy:
      pause.isPending ||
      resume.isPending ||
      cancel.isPending ||
      queuePause.isPending ||
      runNext.isPending ||
      queueResume.isPending ||
      cancelWaiting.isPending ||
      reorder.isPending,
  };
}

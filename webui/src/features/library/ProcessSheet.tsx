import { useMutation, useQuery } from "@tanstack/react-query";
import { X } from "lucide-react";
import { useEffect, useState } from "react";
import { api, APIError } from "../../api/client";
import styles from "./ProcessSheet.module.css";

interface Plan {
  books: {
    id: string;
    title: string;
    author: string | null;
    source: "cataloged" | "download";
    hasAudiobook: boolean;
    hasReadAloud: boolean;
    audiobookAlignsDirectly: boolean;
  }[];
  skipped: { title: string; reason: string }[];
  defaults: {
    voiceID: string;
    bitrateKbps: number;
    workers: number;
    announceTitles: boolean;
    paragraphPauseSeconds: number;
    chapterPauseSeconds: number;
  };
  voices: { id: string; name: string; language: string; quality: string }[];
  permissionWarning: string | null;
  connections: { id: string; label: string }[];
}

interface ReviewCandidate {
  remoteBookID: string;
  title: string;
  authors: string[];
  reason: string;
}

export function ProcessSheet({
  rowIDs,
  connection,
  intent = "process",
  onClose,
  onQueued,
}: {
  rowIDs: string[];
  connection: string | "local";
  intent?: "process" | "sendOnly" | "readAloud";
  onClose: () => void;
  onQueued: (count: number) => void;
}) {
  const connectionParam = connection === "local" ? "" : `?connection=${connection}`;
  const { data: plan } = useQuery<Plan>({
    queryKey: ["process-plan", rowIDs.join(","), connection],
    queryFn: () =>
      api<Plan>(`/api/library/process/plan${connectionParam}`, {
        method: "POST",
        body: JSON.stringify({ rowIDs }),
      }),
    staleTime: Infinity,
    retry: false,
  });

  const [toggles, setToggles] = useState({
    createMissingAudiobooks: intent === "process",
    recreateExistingAudiobooks: false,
    createMissingReadAlouds: intent !== "sendOnly",
    recreateExistingReadAlouds: intent === "readAloud",
    sendToStoryteller: intent === "sendOnly",
    deliveryConnectionID: null as string | null,
    sendEPUB: true,
    sendM4B: true,
    sendReadAloud: true,
  });
  const [voiceID, setVoiceID] = useState("");
  const [readAloudBitrateKbps, setReadAloudBitrateKbps] = useState(32);
  const [readAloudEngine, setReadAloudEngine] = useState<"synthesis" | "apple" | "whisper">("synthesis");
  const [whisperModel, setWhisperModel] = useState("large-v3-turbo");
  const [review, setReview] = useState<ReviewCandidate[] | null>(null);
  const [selectedCandidate, setSelectedCandidate] = useState<string | null>(null);
  const [result, setResult] = useState<{ queued: number; failures: { title: string; reason: string }[] } | null>(null);

  useEffect(() => {
    if (plan && !voiceID) setVoiceID(plan.defaults.voiceID);
    if (plan && !toggles.deliveryConnectionID && plan.connections.length > 0) {
      setToggles((prev) => ({
        ...prev,
        deliveryConnectionID: plan.connections[0]?.id ?? null,
      }));
    }
  }, [plan, voiceID, toggles.deliveryConnectionID]);

  const queuePayload = (confirmedRemoteBookID: string | null) =>
    JSON.stringify({
      rowIDs,
      ...toggles,
      confirmedRemoteBookID,
      voiceID,
      bitrateKbps: plan?.defaults.bitrateKbps ?? 256,
      workers: plan?.defaults.workers ?? 4,
      announceTitles: plan?.defaults.announceTitles ?? true,
      paragraphPauseSeconds: plan?.defaults.paragraphPauseSeconds ?? 0.6,
      chapterPauseSeconds: plan?.defaults.chapterPauseSeconds ?? 1.75,
      readAloudBitrateKbps,
      readAloudASREngineID: readAloudEngine,
      readAloudASRModelID: readAloudEngine === "whisper" ? whisperModel : null,
    });

  const queue = useMutation({
    mutationFn: (confirmedRemoteBookID: string | null) =>
      api<{ queued: number; failures: { title: string; reason: string }[] }>(
        `/api/library/process/queue${connectionParam}`,
        {
          method: "POST",
          body: queuePayload(confirmedRemoteBookID),
        },
      ),
    onSuccess: (value) => {
      setResult(value);
      onQueued(value.queued);
    },
    onError: async (error) => {
      // 409 review flow: the API returns candidates for a single book.
      if (error instanceof APIError && error.status === 409) {
        try {
          const response = await fetch(`/api/library/process/plan-review-cache`);
          void response;
        } catch {
          /* candidates arrive via the error body path below */
        }
      }
    },
  });

  const runQueue = async (confirmed: string | null) => {
    try {
      await queue.mutateAsync(confirmed);
    } catch (error) {
      // The 409 body carries candidates; re-fetch it directly.
      if (error instanceof APIError && error.status === 409) {
        const response = await fetch(`/api/library/process/queue${connectionParam}`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: queuePayload(null),
        });
        const body = (await response.json()) as { candidates?: ReviewCandidate[] };
        if (body.candidates) setReview(body.candidates);
      }
    }
  };

  if (!plan) {
    return (
      <div className={styles.overlay}>
        <div className={styles.sheet}>Loading plan…</div>
      </div>
    );
  }

  const downloads = plan.books.filter((book) => book.source === "download").length;

  return (
    <div className={styles.overlay} role="dialog" aria-modal="true" aria-label="Process books">
      <div className={styles.sheet}>
        <header className={styles.header}>
          <h2>Process {plan.books.length} Book{plan.books.length === 1 ? "" : "s"}</h2>
          <button className={styles.close} onClick={onClose} aria-label="Close">
            <X size={16} />
          </button>
        </header>

        {result ? (
          <div className={styles.result}>
            <p>
              Queued {result.queued} job{result.queued === 1 ? "" : "s"}.
            </p>
            {result.failures.map((failure) => (
              <p key={failure.title} className={styles.failure}>
                {failure.title}: {failure.reason}
              </p>
            ))}
            <button className={styles.primary} onClick={onClose}>
              Done
            </button>
          </div>
        ) : review ? (
          <div className={styles.review}>
            <p>Storyteller has similar editions. Pick the matching one:</p>
            <ul>
              {review.map((candidate) => (
                <li key={candidate.remoteBookID}>
                  <label>
                    <input
                      type="radio"
                      name="candidate"
                      checked={selectedCandidate === candidate.remoteBookID}
                      onChange={() => setSelectedCandidate(candidate.remoteBookID)}
                    />
                    <strong>{candidate.title}</strong> — {candidate.authors.join(", ")}
                    <em className={styles.reason}> ({candidate.reason})</em>
                  </label>
                </li>
              ))}
            </ul>
            <div className={styles.actions}>
              <button className={styles.button} onClick={() => setReview(null)}>
                Back
              </button>
              <button
                className={styles.primary}
                disabled={!selectedCandidate || queue.isPending}
                onClick={() => {
                  setReview(null);
                  void runQueue(selectedCandidate);
                }}
              >
                Link and Queue
              </button>
            </div>
          </div>
        ) : (
          <>
            {plan.skipped.length > 0 && (
              <section className={styles.section}>
                <h3>Skipped ({plan.skipped.length})</h3>
                {plan.skipped.map((skip) => (
                  <p key={skip.title} className={styles.dim}>
                    {skip.title} — {skip.reason}
                  </p>
                ))}
              </section>
            )}

            <section className={styles.section}>
              <h3>Source</h3>
              <p className={styles.dim}>
                {plan.books.length - downloads} cataloged locally
                {downloads > 0 && ` · ${downloads} will download the EPUB from Storyteller`}
              </p>
            </section>

            <section className={styles.section}>
              <h3>Audiobook (M4B)</h3>
              <label className={styles.row}>
                <input
                  type="checkbox"
                  checked={toggles.createMissingAudiobooks}
                  onChange={(event) =>
                    setToggles({ ...toggles, createMissingAudiobooks: event.target.checked })
                  }
                />
                Create for books missing one
              </label>
              <label className={styles.row}>
                <input
                  type="checkbox"
                  checked={toggles.recreateExistingAudiobooks}
                  onChange={(event) =>
                    setToggles({ ...toggles, recreateExistingAudiobooks: event.target.checked })
                  }
                />
                Recreate existing (digest-guarded)
              </label>
              <label className={styles.field}>
                <span>Voice</span>
                <select value={voiceID} onChange={(event) => setVoiceID(event.target.value)}>
                  {plan.voices.map((voice) => (
                    <option key={voice.id} value={voice.id}>
                      {voice.name} — {voice.language}
                    </option>
                  ))}
                </select>
              </label>
              {plan.permissionWarning && (
                <p className={styles.warning}>{plan.permissionWarning}</p>
              )}
            </section>

            <section className={styles.section}>
              <h3>ReadAloud EPUB</h3>
              <label className={styles.row}>
                <input
                  type="checkbox"
                  checked={toggles.createMissingReadAlouds}
                  onChange={(event) =>
                    setToggles({ ...toggles, createMissingReadAlouds: event.target.checked })
                  }
                />
                Create for books missing one
              </label>
              <label className={styles.row}>
                <input
                  type="checkbox"
                  checked={toggles.recreateExistingReadAlouds}
                  onChange={(event) =>
                    setToggles({ ...toggles, recreateExistingReadAlouds: event.target.checked })
                  }
                />
                Recreate existing
              </label>
              {(toggles.createMissingReadAlouds || toggles.recreateExistingReadAlouds) && (
                <>
                  <label className={styles.field}>
                    <span>Opus bitrate</span>
                    <div className={styles.segmented} role="radiogroup" aria-label="Opus bitrate">
                      {[16, 32, 64, 96].map((rate) => (
                        <button
                          key={rate}
                          role="radio"
                          aria-checked={readAloudBitrateKbps === rate}
                          data-active={readAloudBitrateKbps === rate || undefined}
                          onClick={() => setReadAloudBitrateKbps(rate)}
                        >
                          {rate}
                        </button>
                      ))}
                    </div>
                  </label>
                  <label className={styles.field}>
                    <span>Alignment transcript</span>
                    <div className={styles.segmented} role="radiogroup" aria-label="Alignment transcript">
                      {(
                        [
                          ["synthesis", "Exact (no ASR)"],
                          ["apple", "Apple Speech"],
                          ["whisper", "Whisper"],
                        ] as const
                      ).map(([engine, label]) => (
                        <button
                          key={engine}
                          role="radio"
                          aria-checked={readAloudEngine === engine}
                          data-active={readAloudEngine === engine || undefined}
                          onClick={() => setReadAloudEngine(engine)}
                        >
                          {label}
                        </button>
                      ))}
                    </div>
                  </label>
                  {readAloudEngine === "whisper" && (
                    <label className={styles.field}>
                      <span>Whisper model</span>
                      <select
                        value={whisperModel}
                        onChange={(event) => setWhisperModel(event.target.value)}
                      >
                        {["tiny", "base", "small", "medium", "large-v3", "large-v3-turbo"].map(
                          (model) => (
                            <option key={model} value={model}>
                              {model}
                            </option>
                          ),
                        )}
                      </select>
                    </label>
                  )}
                  <p className={styles.dim}>
                    Exact uses the audiobook's own synthesis timing (no speech
                    recognition); Apple and Whisper transcribe the audio instead —
                    needed when aligning audio not synthesized by this app.
                  </p>
                </>
              )}
            </section>

            {plan.connections.length > 0 && (
              <section className={styles.section}>
                <h3>Send to Storyteller</h3>
                <label className={styles.row}>
                  <input
                    type="checkbox"
                    checked={toggles.sendToStoryteller}
                    onChange={(event) =>
                      setToggles({ ...toggles, sendToStoryteller: event.target.checked })
                    }
                  />
                  Send finished products after production
                </label>
                {toggles.sendToStoryteller && (
                  <>
                    <label className={styles.field}>
                      <span>Connection</span>
                      <select
                        value={toggles.deliveryConnectionID ?? ""}
                        onChange={(event) =>
                          setToggles({ ...toggles, deliveryConnectionID: event.target.value })
                        }
                      >
                        {plan.connections.map((c) => (
                          <option key={c.id} value={c.id}>
                            {c.label}
                          </option>
                        ))}
                      </select>
                    </label>
                    {(
                      [
                        ["sendEPUB", "Source EPUB"],
                        ["sendM4B", "AAC audiobook"],
                        ["sendReadAloud", "ReadAloud EPUB"],
                      ] as const
                    ).map(([key, label]) => (
                      <label key={key} className={styles.row}>
                        <input
                          type="checkbox"
                          checked={toggles[key]}
                          onChange={(event) =>
                            setToggles({ ...toggles, [key]: event.target.checked })
                          }
                        />
                        {label}
                      </label>
                    ))}
                  </>
                )}
              </section>
            )}

            <footer className={styles.footer}>
              <button className={styles.button} onClick={onClose}>
                Cancel
              </button>
              <button
                className={styles.primary}
                disabled={queue.isPending || plan.books.length === 0}
                onClick={() => void runQueue(null)}
              >
                {queue.isPending ? "Queueing…" : `Add ${plan.books.length} to Queue`}
              </button>
            </footer>
          </>
        )}
      </div>
    </div>
  );
}

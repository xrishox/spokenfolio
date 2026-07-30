import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Link, useParams } from "@tanstack/react-router";
import { Copy, FolderSearch, Plug, RefreshCcw, Trash2 } from "lucide-react";
import { useEffect, useState } from "react";
import { api, APIError } from "../../api/client";
import { useSettings } from "../../api/queries";
import type { RelocationStatus, Settings } from "../../api/types";
import { FolderPicker } from "../../components/FolderPicker";
import styles from "./SettingsPage.module.css";

const scopes = [
  ["storage", "Storage"],
  ["readaloud", "ReadAloud"],
  ["storyteller", "Storyteller"],
] as const;
type Scope = (typeof scopes)[number][0];

interface Connection {
  id: string;
  origin: string;
  displayName: string;
  username: string;
  connectedAt: string;
  permissions: Record<string, boolean>;
}

interface Tools {
  stalign: {
    status: string;
    detail: string;
    installedVersion: string | null;
    availableVersion: string | null;
    installedSHA256: string | null;
    updateAvailable: boolean | null;
    compatibility: string | null;
  };
  media: { status: string; detail: string };
  publications: { status: string; detail: string };
}

interface DeviceAuthSession {
  id: string;
  userCode: string;
  verificationURL: string;
  expiresAt: string;
  state: "pending" | "connected" | "expired" | "failed";
  username: string | null;
  failure: string | null;
}

export function SettingsPage() {
  const params = useParams({ strict: false }) as { scope?: Scope };
  const scope: Scope = scopes.some(([key]) => key === params.scope)
    ? (params.scope as Scope)
    : "storage";

  return (
    <div className={styles.page}>
      <header className={styles.header}>
        <h1 className={styles.title}>Settings</h1>
        <nav className={styles.tabs} aria-label="Settings scope">
          {scopes.map(([key, label]) => (
            <Link
              key={key}
              to="/settings/$scope"
              params={{ scope: key }}
              className={styles.tab}
              data-active={key === scope || undefined}
            >
              {label}
            </Link>
          ))}
        </nav>
      </header>
      {scope === "storage" && <StoragePane />}
      {scope === "readaloud" && <ToolsPane />}
      {scope === "storyteller" && <StorytellerPane />}
    </div>
  );
}

function StoragePane() {
  const { data: settings, refetch } = useSettings();
  const [path, setPath] = useState("");
  const [showBrowser, setShowBrowser] = useState(false);
  const [relocation, setRelocation] = useState<RelocationStatus | null>(null);

  // Adopt a relocation already known to the server (e.g. this page opened
  // while a move started elsewhere is still running).
  useEffect(() => {
    if (settings?.relocation && relocation === null) setRelocation(settings.relocation);
  }, [settings, relocation]);

  const save = useMutation({
    mutationFn: (value: string | null) =>
      api<Settings>("/api/settings/processed-directory", {
        method: "PUT",
        body: JSON.stringify({ path: value }),
      }),
    onSuccess: (fresh) => {
      setRelocation(fresh.relocation);
      setPath("");
      setShowBrowser(false);
      void refetch();
    },
  });

  // Poll the relocation while the background move runs.
  useEffect(() => {
    if (!relocation?.active) return;
    const timer = setInterval(() => {
      api<RelocationStatus>("/api/settings/relocation")
        .then((fresh) => {
          setRelocation(fresh);
          if (!fresh.active) void refetch();
        })
        .catch(() => {
          /* transient poll failure; keep the last known state */
        });
    }, 1000);
    return () => clearInterval(timer);
  }, [relocation?.active, refetch]);

  const submit = (value: string | null) => {
    const unchanged = value !== null && value === settings?.processedDirectory;
    if (!unchanged) {
      const target = value ?? "the default folder ~/Books/SpokenFolio";
      if (
        !confirm(
          `Move your library to ${target}? Books currently being processed block this.`,
        )
      )
        return;
    }
    save.mutate(value);
  };

  const blocked =
    save.isError && save.error instanceof APIError && save.error.code === "relocation_blocked";

  return (
    <section className={styles.card}>
      <h2 className={styles.cardTitle}>Book Library</h2>
      <p className={styles.dim}>
        All book files — imported EPUBs, Storyteller downloads, TTS audiobooks, and TTS
        ReadAlouds — are stored here, one folder per book. Changing the location moves your
        whole library.
      </p>
      <code className={styles.path}>{settings?.processedDirectory ?? "…"}</code>
      <div className={styles.row}>
        <input
          className={styles.input}
          placeholder="New folder path on the Mac (e.g. ~/Books/SpokenFolio)"
          value={path}
          onChange={(event) => setPath(event.target.value)}
        />
        <button
          className={styles.button}
          onClick={() => setShowBrowser((open) => !open)}
          aria-expanded={showBrowser}
        >
          <FolderSearch size={14} aria-hidden /> Browse
        </button>
        <button
          className={styles.button}
          disabled={!path.trim() || save.isPending || relocation?.active}
          onClick={() => submit(path.trim())}
        >
          Save
        </button>
        <button
          className={styles.button}
          disabled={save.isPending || relocation?.active}
          onClick={() => submit(null)}
        >
          Restore Default
        </button>
      </div>
      {showBrowser && settings && (
        <FolderPicker initialPath={settings.processedDirectory} onPick={setPath} />
      )}
      {relocation?.active && (
        <p className={styles.dim} role="status">
          Moving {relocation.currentTitle ?? "the library"} ({relocation.completed}/
          {relocation.total})…
          {relocation.destination && ` → ${relocation.destination}`}
        </p>
      )}
      {relocation && !relocation.active && relocation.failures.length > 0 && (
        <div role="alert">
          <p className={styles.error}>
            {relocation.failures.length} book
            {relocation.failures.length === 1 ? "" : "s"} could not be moved:
          </p>
          {relocation.failures.map((failure) => (
            <p key={failure.title} className={styles.error}>
              {failure.title}: {failure.reason}
            </p>
          ))}
        </div>
      )}
      {blocked && (
        <p className={styles.error} role="alert">
          Cannot move the library right now: {(save.error as APIError).message}
        </p>
      )}
      {save.isError && !blocked && (
        <p className={styles.error} role="alert">
          {save.error instanceof Error ? save.error.message : String(save.error)}
        </p>
      )}
    </section>
  );
}

function ToolsPane() {
  const queryClient = useQueryClient();
  const { data: tools } = useQuery<Tools>({
    queryKey: ["tools"],
    queryFn: () => api<Tools>("/api/tools"),
    staleTime: 30_000,
    retry: false,
  });
  const install = useMutation({
    mutationFn: () => api<Tools>("/api/tools/stalign/install", { method: "POST" }),
    onSuccess: (fresh) => queryClient.setQueryData(["tools"], fresh),
  });
  const [copied, setCopied] = useState(false);

  return (
    <>
      <section className={styles.card}>
        <h2 className={styles.cardTitle}>stalign</h2>
        <p className={styles.dim}>{tools?.stalign.detail ?? "Checking…"}</p>
        {tools?.stalign.status !== "installed" && (
          <button
            className={styles.button}
            disabled={install.isPending}
            onClick={() => void install.mutateAsync()}
          >
            {install.isPending
              ? "Installing…"
              : tools?.stalign.updateAvailable
                ? `Update to stalign ${tools.stalign.availableVersion ?? ""}`
                : `Install latest stable stalign ${tools?.stalign.availableVersion ?? ""}`}
          </button>
        )}
        {install.isError && <p className={styles.error}>{String(install.error)}</p>}
      </section>
      <section className={styles.card}>
        <h2 className={styles.cardTitle}>EPUB compliance</h2>
        <p className={styles.dim}>{tools?.publications.detail ?? "Checking…"}</p>
        {tools?.publications.status !== "installed" && (
          <button
            className={styles.button}
            onClick={() => {
              void navigator.clipboard.writeText(
                "brew install epubcheck && brew install --cask calibre",
              );
              setCopied(true);
              setTimeout(() => setCopied(false), 1500);
            }}
          >
            <Copy size={14} aria-hidden /> {copied ? "Copied" : "Copy Homebrew Command"}
          </button>
        )}
      </section>
      <section className={styles.card}>
        <h2 className={styles.cardTitle}>ffmpeg</h2>
        <p className={styles.dim}>{tools?.media.detail ?? "Checking…"}</p>
        {tools?.media.status !== "installed" && (
          <button
            className={styles.button}
            onClick={() => {
              void navigator.clipboard.writeText("brew install ffmpeg");
              setCopied(true);
              setTimeout(() => setCopied(false), 1500);
            }}
          >
            <Copy size={14} aria-hidden /> {copied ? "Copied" : "Copy Homebrew Command"}
          </button>
        )}
      </section>
    </>
  );
}

function StorytellerPane() {
  const queryClient = useQueryClient();
  const { data: connections, refetch } = useQuery<Connection[]>({
    queryKey: ["storyteller-connections"],
    queryFn: () => api<Connection[]>("/api/storyteller/connections"),
    staleTime: 30_000,
    retry: false,
  });
  const [health, setHealth] = useState<Record<string, { state: string; detail: string }>>({});
  const [origin, setOrigin] = useState("");
  const [session, setSession] = useState<DeviceAuthSession | null>(null);

  const test = useMutation({
    mutationFn: (id: string) =>
      api<{ state: string; detail: string }>(`/api/storyteller/connections/${id}/test`, {
        method: "POST",
        body: "{}",
      }),
    onSuccess: (result, id) => setHealth((prev) => ({ ...prev, [id]: result })),
  });

  const invalidateLibrary = () => {
    void queryClient.invalidateQueries({ queryKey: ["library"] });
    void queryClient.invalidateQueries({ queryKey: ["library-bootstrap"] });
  };

  const remove = useMutation({
    mutationFn: (id: string) =>
      api<void>(`/api/storyteller/connections/${id}`, { method: "DELETE" }),
    onSuccess: () => {
      void refetch();
      invalidateLibrary();
    },
  });

  // Starts device authorization; `replacingConnectionID` re-authorizes an
  // existing connection in place instead of creating a new one.
  const start = useMutation({
    // The server fails unreachable origins within ~10s with a reason; the
    // abort signal is the belt-and-braces bound so the Connect button can
    // never wedge waiting on a bad address.
    mutationFn: async (input: { origin: string; replacingConnectionID: string | null }) => {
      try {
        return await api<DeviceAuthSession>("/api/storyteller/device-auth", {
          method: "POST",
          body: JSON.stringify(input),
          signal: AbortSignal.timeout(20_000),
        });
      } catch (error) {
        if (
          error instanceof DOMException &&
          (error.name === "TimeoutError" || error.name === "AbortError")
        ) {
          throw new Error(
            "Timed out reaching that address after 20 seconds. Check the URL, port, and network, then try again.",
          );
        }
        throw error;
      }
    },
    onSuccess: (fresh) => {
      setSession(fresh);
      window.open(fresh.verificationURL, "_blank", "noopener");
    },
  });

  // Poll the session while pending.
  useEffect(() => {
    if (!session || session.state !== "pending") return;
    const timer = setInterval(() => {
      void api<DeviceAuthSession>(`/api/storyteller/device-auth/${session.id}`)
        .then((fresh) => {
          setSession(fresh);
          if (fresh.state === "connected") {
            void refetch();
            void queryClient.invalidateQueries({ queryKey: ["library"] });
            void queryClient.invalidateQueries({ queryKey: ["library-bootstrap"] });
          }
        })
        .catch(() => setSession(null));
    }, 3000);
    return () => clearInterval(timer);
  }, [session, refetch, queryClient]);

  return (
    <>
      <section className={styles.card}>
        <h2 className={styles.cardTitle}>Add Connection</h2>
        <div className={styles.row}>
          <input
            className={styles.input}
            placeholder="https://storyteller.example.com"
            value={origin}
            onChange={(event) => {
              setOrigin(event.target.value);
              if (start.isError) start.reset();
            }}
          />
          <button
            className={styles.button}
            disabled={!origin.trim() || start.isPending || session?.state === "pending"}
            onClick={() => start.mutate({ origin, replacingConnectionID: null })}
          >
            <Plug size={14} aria-hidden /> {start.isPending ? "Connecting…" : "Connect…"}
          </button>
        </div>
        {start.isError && (
          <p className={styles.error} role="alert">
            {start.error instanceof Error ? start.error.message : String(start.error)}
          </p>
        )}
        {session && (
          <div className={styles.authBox} data-state={session.state}>
            {session.state === "pending" && (
              <>
                <p>Approve this device in Storyteller with the code:</p>
                <div className={styles.userCode}>{session.userCode}</div>
                <p className={styles.dim}>
                  Waiting for approval…{" "}
                  <a href={session.verificationURL} target="_blank" rel="noopener">
                    Open the approval page
                  </a>
                </p>
                <button
                  className={styles.button}
                  onClick={() => {
                    void api(`/api/storyteller/device-auth/${session.id}`, {
                      method: "DELETE",
                    });
                    setSession(null);
                  }}
                >
                  Cancel
                </button>
              </>
            )}
            {session.state === "connected" && (
              <p>Connected as {session.username}.</p>
            )}
            {session.state === "expired" && (
              <p>The approval code expired before this device was approved. Try again.</p>
            )}
            {session.state === "failed" && <p className={styles.error}>{session.failure}</p>}
          </div>
        )}
      </section>

      {(connections ?? []).map((connection) => (
        <section key={connection.id} className={styles.card}>
          <div className={styles.connectionHead}>
            <div>
              <h2 className={styles.cardTitle}>{connection.displayName}</h2>
              <p className={styles.dim}>
                {connection.username} · {connection.origin}
              </p>
            </div>
            <div className={styles.connectionActions}>
              <button
                className={styles.button}
                disabled={test.isPending}
                onClick={() => void test.mutateAsync(connection.id)}
              >
                <RefreshCcw size={13} aria-hidden /> Test
              </button>
              <button
                className={styles.button}
                disabled={start.isPending || session?.state === "pending"}
                onClick={() =>
                  start.mutate({
                    origin: connection.origin,
                    replacingConnectionID: connection.id,
                  })
                }
              >
                <Plug size={13} aria-hidden /> Reconnect…
              </button>
              <button
                className={styles.button}
                onClick={() => {
                  if (
                    confirm(
                      `Disconnect ${connection.displayName}? The saved Library snapshot and history are retained.`,
                    )
                  )
                    void remove.mutateAsync(connection.id);
                }}
              >
                <Trash2 size={13} aria-hidden /> Disconnect…
              </button>
            </div>
          </div>
          {health[connection.id] && (
            <p
              className={styles.health}
              data-state={health[connection.id]?.state}
            >
              {health[connection.id]?.detail}
            </p>
          )}
          <div className={styles.permissions}>
            {Object.entries(connection.permissions).map(([key, granted]) => (
              <span key={key} className={styles.permission} data-granted={granted || undefined}>
                {key}
              </span>
            ))}
          </div>
        </section>
      ))}
    </>
  );
}

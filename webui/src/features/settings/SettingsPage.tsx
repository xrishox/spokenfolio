import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Link, useParams } from "@tanstack/react-router";
import { Copy, Plug, RefreshCcw, Trash2 } from "lucide-react";
import { useEffect, useState } from "react";
import { api } from "../../api/client";
import { useSettings } from "../../api/queries";
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
  stalign: { status: string; detail: string; pinnedVersion: string | null };
  media: { status: string; detail: string };
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
  const save = useMutation({
    mutationFn: (value: string | null) =>
      api("/api/settings/processed-directory", {
        method: "PUT",
        body: JSON.stringify({ path: value }),
      }),
    onSuccess: () => void refetch(),
  });

  return (
    <section className={styles.card}>
      <h2 className={styles.cardTitle}>Processed Books</h2>
      <p className={styles.dim}>
        Finished audiobooks and ReadAlouds are organized under this folder on the Mac.
      </p>
      <code className={styles.path}>{settings?.processedDirectory ?? "…"}</code>
      <div className={styles.row}>
        <input
          className={styles.input}
          placeholder="New folder path on the Mac (e.g. ~/Books/Processed)"
          value={path}
          onChange={(event) => setPath(event.target.value)}
        />
        <button
          className={styles.button}
          disabled={!path.trim() || save.isPending}
          onClick={() => {
            void save.mutateAsync(path.trim());
            setPath("");
          }}
        >
          Set Folder
        </button>
        <button
          className={styles.button}
          disabled={save.isPending}
          onClick={() => void save.mutateAsync(null)}
        >
          Restore Default
        </button>
      </div>
      {save.isError && <p className={styles.error}>{String(save.error)}</p>}
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
              : `Install stalign ${tools?.stalign.pinnedVersion ?? ""}`}
          </button>
        )}
        {install.isError && <p className={styles.error}>{String(install.error)}</p>}
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
    mutationFn: (input: { origin: string; replacingConnectionID: string | null }) =>
      api<DeviceAuthSession>("/api/storyteller/device-auth", {
        method: "POST",
        body: JSON.stringify(input),
      }),
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
            onChange={(event) => setOrigin(event.target.value)}
          />
          <button
            className={styles.button}
            disabled={!origin.trim() || start.isPending || session?.state === "pending"}
            onClick={() => void start.mutateAsync({ origin, replacingConnectionID: null })}
          >
            <Plug size={14} aria-hidden /> Connect…
          </button>
        </div>
        {start.isError && <p className={styles.error}>{String(start.error)}</p>}
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
                  void start.mutateAsync({
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

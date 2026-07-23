import { AlertTriangle, CheckCircle2, Clock, Copy, Power } from "lucide-react";
import { useState } from "react";
import { useServerStatus, useVoices } from "../../api/queries";
import styles from "./ServerPage.module.css";

const healthPresentation = {
  ready: { icon: CheckCircle2, color: "var(--ok)", title: "Running" },
  starting: { icon: Clock, color: "var(--text-tertiary)", title: "Starting" },
  permission_required: {
    icon: AlertTriangle,
    color: "var(--warn)",
    title: "Permission required",
  },
  unavailable: { icon: AlertTriangle, color: "var(--warn)", title: "Degraded" },
} as const;

export function ServerPage() {
  const { data: server, isLoading, error } = useServerStatus();
  const { data: voices } = useVoices();
  const [copied, setCopied] = useState(false);

  if (isLoading) return <div className={styles.page}>Loading server status…</div>;
  if (error || !server) {
    return (
      <div className={styles.page}>
        <div className={styles.errorCard} role="alert">
          The server did not answer. It may be stopped — start the SpokenFolio app
          (or <code>spokenfolio serve --studio</code>) on the Mac.
        </div>
      </div>
    );
  }

  const presentation = healthPresentation[server.health] ?? healthPresentation.unavailable;
  const HealthIcon = presentation.icon;

  const copyEndpoint = async () => {
    try {
      await navigator.clipboard.writeText(server.endpoint);
      setCopied(true);
      setTimeout(() => setCopied(false), 1500);
    } catch {
      // Clipboard needs a secure context or user gesture; ignore quietly.
    }
  };

  return (
    <div className={styles.page}>
      <header className={styles.header}>
        <HealthIcon size={28} color={presentation.color} aria-hidden />
        <div>
          <h1 className={styles.title}>{presentation.title}</h1>
          <p className={styles.subtitle}>
            {server.health === "ready"
              ? `Serving ${server.voiceCount} Siri voice${server.voiceCount === 1 ? "" : "s"} on the local network.`
              : server.fullDiskAccessInstructions ??
                "The speech engine is unavailable; speech requests return a structured 503."}
          </p>
        </div>
      </header>

      <section className={styles.card} aria-label="Connection">
        <h2 className={styles.cardTitle}>Connection</h2>
        <div className={styles.row}>
          <span className={styles.rowLabel}>Address</span>
          <code className={styles.endpoint}>{server.endpoint}</code>
          <button className={styles.iconButton} onClick={copyEndpoint} aria-label="Copy address">
            <Copy size={14} aria-hidden /> {copied ? "Copied" : "Copy"}
          </button>
        </div>
        <div className={styles.row}>
          <span className={styles.rowLabel}>API</span>
          <span>OpenAI-compatible /v1/audio/speech</span>
        </div>
        <div className={styles.row}>
          <span className={styles.rowLabel}>Audio</span>
          <span>Mono 48 kHz · Opus, AAC, WAV, PCM</span>
        </div>
        <div className={styles.row}>
          <span className={styles.rowLabel}>Studio</span>
          <span>
            {server.schedulerState === "hosted"
              ? "Job scheduler hosted by this process"
              : server.schedulerState === "lockedByOtherProcess"
                ? "Another process owns the job scheduler"
                : "Not hosted (TTS only)"}
          </span>
        </div>
      </section>

      {voices && voices.voices.length > 0 && (
        <section className={styles.card} aria-label="Voices">
          <h2 className={styles.cardTitle}>Voices</h2>
          <ul className={styles.voiceList}>
            {voices.voices.map((voice) => (
              <li key={voice.id} className={styles.voiceRow}>
                <span>{voice.name}</span>
                <span className={styles.voiceLang}>{voice.language}</span>
                <code className={styles.voiceID}>{voice.id}</code>
              </li>
            ))}
          </ul>
        </section>
      )}

      {server.health !== "ready" && server.fullDiskAccessInstructions && (
        <section className={styles.card} aria-label="Fix">
          <h2 className={styles.cardTitle}>
            <Power size={14} aria-hidden /> How to fix
          </h2>
          <p>{server.fullDiskAccessInstructions}</p>
        </section>
      )}
    </div>
  );
}

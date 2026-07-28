import { AlertTriangle, CheckCircle2, Clock, Copy, Play, Power } from "lucide-react";
import { useEffect, useRef, useState } from "react";
import { useServerStatus, useTTSCatalog } from "../../api/queries";
import type { TTSSelection } from "../../api/types";
import { TTSSelectionFields } from "../tts/TTSSelectionFields";
import { emptyTTSSelection, normalizeTTSSelection } from "../tts/selection";
import { countGraphemes, requestSpeechTestAudio } from "./speechTest";
import styles from "./ServerPage.module.css";

const MAX_TEST_CHARACTERS = 4096;

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

function sameSelection(left: TTSSelection, right: TTSSelection): boolean {
  return (
    left.backendID === right.backendID &&
    left.modelID === right.modelID &&
    left.voiceID === right.voiceID &&
    left.pacePreset === right.pacePreset &&
    left.expressivityPreset === right.expressivityPreset
  );
}

export function ServerPage() {
  const { data: server, isLoading, error } = useServerStatus();
  const { data: ttsCatalog } = useTTSCatalog();
  const [copied, setCopied] = useState(false);
  const [selection, setSelection] = useState<TTSSelection>(emptyTTSSelection);
  const [testText, setTestText] = useState("Hello from SpokenFolio.");
  const [testStatus, setTestStatus] = useState<string | null>(null);
  const [testError, setTestError] = useState<string | null>(null);
  const [testing, setTesting] = useState(false);
  const [audioURL, setAudioURL] = useState<string | null>(null);
  const audioRef = useRef<HTMLAudioElement>(null);

  useEffect(() => {
    const normalized = normalizeTTSSelection(ttsCatalog, selection);
    if (!sameSelection(normalized, selection)) setSelection(normalized);
  }, [ttsCatalog, selection]);

  useEffect(() => {
    if (!audioURL) return;
    const audio = audioRef.current;
    if (!audio) {
      URL.revokeObjectURL(audioURL);
      return;
    }
    let active = true;
    void audio.play().then(
      () => {
        if (active) setTestStatus("AAC verified and playing.");
      },
      (playError: unknown) => {
        if (!active) return;
        setTestError(
          playError instanceof Error ? playError.message : "The browser could not start AAC playback.",
        );
        setTestStatus("AAC verified. Use the audio controls to play it.");
      },
    );
    return () => {
      active = false;
      audio.pause();
      audio.removeAttribute("src");
      audio.load();
      URL.revokeObjectURL(audioURL);
    };
  }, [audioURL]);

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
  const trimmedTestText = testText.trim();
  const testCharacterCount = countGraphemes(testText);
  const canTest =
    server.health === "ready" &&
    ttsCatalog != null &&
    selection.backendID !== "" &&
    selection.modelID !== "" &&
    selection.voiceID !== "" &&
    trimmedTestText.length > 0 &&
    testCharacterCount <= MAX_TEST_CHARACTERS &&
    !testing;

  const copyEndpoint = async () => {
    try {
      await navigator.clipboard.writeText(server.endpoint);
      setCopied(true);
      setTimeout(() => setCopied(false), 1500);
    } catch {
      // Clipboard needs a secure context or user gesture; ignore quietly.
    }
  };

  const testAndPlay = async () => {
    if (!canTest || !ttsCatalog) return;
    setTesting(true);
    setTestError(null);
    setTestStatus("Requesting and validating Opus…");
    setAudioURL(null);
    try {
      await requestSpeechTestAudio(ttsCatalog, selection, testText, "opus");
      setTestStatus("Opus verified. Requesting AAC…");
      const aac = await requestSpeechTestAudio(ttsCatalog, selection, testText, "aac");
      setTestStatus("AAC verified. Starting playback…");
      setAudioURL(URL.createObjectURL(aac));
    } catch (requestError) {
      setTestStatus(null);
      setTestError(
        requestError instanceof Error ? requestError.message : "The speech test failed.",
      );
    } finally {
      setTesting(false);
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
              ? `Serving ${server.voiceCount} TTS voice${server.voiceCount === 1 ? "" : "s"} on the local network.`
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

      <section className={styles.card} aria-labelledby="test-play-title">
        <h2 id="test-play-title" className={styles.cardTitle}>Test &amp; Play</h2>
        <p className={styles.testHint}>
          Verifies an Opus response first, then requests and plays the AAC response.
        </p>
        <TTSSelectionFields
          catalog={ttsCatalog}
          value={selection}
          onChange={setSelection}
          disabled={testing}
        />
        <label className={styles.testField}>
          <span>Text</span>
          <textarea
            value={testText}
            rows={5}
            disabled={testing}
            aria-describedby="test-character-count"
            onChange={(event) => setTestText(event.target.value)}
          />
        </label>
        <div className={styles.testActions}>
          <span id="test-character-count" className={styles.characterCount}>
            {testCharacterCount.toLocaleString()} / {MAX_TEST_CHARACTERS.toLocaleString()}
          </span>
          <button
            type="button"
            className={styles.primaryButton}
            disabled={!canTest}
            onClick={() => void testAndPlay()}
          >
            <Play size={14} aria-hidden /> {testing ? "Testing…" : "Test & Play"}
          </button>
        </div>
        {!trimmedTestText && (
          <p className={styles.validation} role="alert">Enter nonblank text to test.</p>
        )}
        {testStatus && <p className={styles.testStatus} role="status" aria-live="polite">{testStatus}</p>}
        {testError && <p className={styles.testError} role="alert">{testError}</p>}
        {audioURL && (
          <audio
            ref={audioRef}
            className={styles.audioPlayer}
            src={audioURL}
            controls
            aria-label="Synthesized AAC preview"
            onPlay={() => {
              setTestError(null);
              setTestStatus("AAC verified and playing.");
            }}
            onError={() => setTestError("The browser could not decode the AAC response.")}
            onEnded={() => {
              setAudioURL(null);
              setTestStatus("Opus and AAC verified. Playback finished.");
            }}
          />
        )}
      </section>

      {ttsCatalog && ttsCatalog.voices.length > 0 && (
        <section className={styles.card} aria-label="Voices">
          <h2 className={styles.cardTitle}>Voices</h2>
          <ul className={styles.voiceList}>
            {ttsCatalog.voices.map((voice) => (
              <li
                key={`${voice.backend ?? "legacy"}/${voice.model ?? "legacy"}/${voice.id}`}
                className={styles.voiceRow}
              >
                <span>{voice.name}</span>
                <span className={styles.voiceLang}>{voice.lang}</span>
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

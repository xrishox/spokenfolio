import { Link, Outlet, useRouterState } from "@tanstack/react-router";
import {
  BookOpen,
  Factory,
  Server,
  Settings as SettingsIcon,
  ShieldCheck,
} from "lucide-react";
import { useQueueStatus, useServerStatus, useSettings } from "../api/queries";
import { useConnection } from "../stores/connection";
import styles from "./AppShell.module.css";
import { OnboardingModal } from "./OnboardingModal";

const sections = [
  {
    to: "/production/$mode",
    params: { mode: "queue" },
    match: "/production",
    label: "Production",
    icon: Factory,
  },
  { to: "/library", match: "/library", label: "Library", icon: BookOpen },
  { to: "/quality", match: "/quality", label: "ReadAloud Quality", icon: ShieldCheck },
  { to: "/server", match: "/server", label: "TTS Server", icon: Server },
  {
    to: "/settings/$scope",
    params: { scope: "storage" },
    match: "/settings",
    label: "Settings",
    icon: SettingsIcon,
  },
] as const;

function ServerDot() {
  const { data } = useServerStatus();
  const color =
    data?.health === "ready"
      ? "var(--ok)"
      : data?.health === "starting"
        ? "var(--text-tertiary)"
        : "var(--warn)";
  return <span className={styles.dot} style={{ background: color }} aria-hidden />;
}

export function AppShell() {
  const { data: queue } = useQueueStatus();
  const { data: settings } = useSettings();
  const sseConnected = useConnection((s) => s.sseConnected);
  const pathname = useRouterState({ select: (s) => s.location.pathname });
  const productionBadge = queue ? queue.queuedCount + queue.runningCount : 0;

  return (
    <div className={styles.shell}>
      {settings && !settings.configured && <OnboardingModal settings={settings} />}
      <nav className={styles.sidebar} aria-label="Sections">
        <div className={styles.appName}>SpokenFolio</div>
        {sections.map(({ to, match, label, icon: Icon, ...section }) => (
          <Link
            key={to}
            to={to}
            params={"params" in section ? (section.params as Record<string, string>) : {}}
            className={styles.navItem}
            data-active={pathname.startsWith(match) || undefined}
          >
            <Icon size={16} strokeWidth={1.8} aria-hidden />
            <span className={styles.navLabel}>{label}</span>
            {label === "Production" && productionBadge > 0 && (
              <span className={styles.badge}>{productionBadge}</span>
            )}
            {label === "TTS Server" && <ServerDot />}
          </Link>
        ))}
      </nav>
      <div className={styles.main}>
        {!sseConnected && (
          <div className={styles.banner} role="status">
            Live updates reconnecting — showing polled data.
          </div>
        )}
        {queue?.isSuspended && (
          <div className={styles.banner} role="status">
            The production queue is paused.
          </div>
        )}
        <main className={styles.content}>
          <Outlet />
        </main>
      </div>
    </div>
  );
}

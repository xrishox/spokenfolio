import { useQuery } from "@tanstack/react-query";
import { CornerLeftUp, Folder } from "lucide-react";
import { useEffect, useState } from "react";
import { api } from "../api/client";
import type { FSList } from "../api/types";
import styles from "./FolderPicker.module.css";

/** Compact directory browser over GET /api/fs/list (bounded to the home
 *  folder by the server). Clicking a folder descends into it and reports it
 *  via `onPick`, so browsing doubles as selection. */
export function FolderPicker({
  initialPath,
  onPick,
}: {
  initialPath: string;
  onPick: (path: string) => void;
}) {
  const [path, setPath] = useState(initialPath);
  const { data, isError, error } = useQuery<FSList>({
    queryKey: ["fs-list", path],
    queryFn: () => api<FSList>(`/api/fs/list?path=${encodeURIComponent(path)}`),
    staleTime: 5000,
    retry: false,
  });

  // The starting folder may not exist yet (e.g. the not-yet-created default
  // library folder). Walk up client-side until a listable ancestor is found.
  useEffect(() => {
    if (!isError) return;
    const slash = path.lastIndexOf("/");
    if (slash > 0) setPath(path.slice(0, slash));
  }, [isError, path]);

  const go = (next: string) => {
    setPath(next);
    onPick(next);
  };

  const directories = (data?.entries ?? []).filter((entry) => entry.kind === "directory");

  return (
    <div className={styles.picker}>
      <div className={styles.current} title={data?.path ?? path}>
        {data?.path ?? path}
      </div>
      <ul className={styles.list}>
        {data?.parent != null && (
          <li>
            <button type="button" className={styles.entry} onClick={() => go(data.parent!)}>
              <CornerLeftUp size={13} aria-hidden />
              <span>..</span>
            </button>
          </li>
        )}
        {directories.map((entry) => (
          <li key={entry.path}>
            <button type="button" className={styles.entry} onClick={() => go(entry.path)}>
              <Folder size={13} aria-hidden />
              <span>{entry.name}</span>
            </button>
          </li>
        ))}
        {data && directories.length === 0 && (
          <li className={styles.empty}>No subfolders</li>
        )}
      </ul>
      {isError && (
        <p className={styles.error}>
          {error instanceof Error ? error.message : "Cannot list that folder."}
        </p>
      )}
    </div>
  );
}

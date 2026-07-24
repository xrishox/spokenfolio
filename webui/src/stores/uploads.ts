import { create } from "zustand";

export interface Upload {
  key: string;
  filename: string;
  fraction: number;
  xhr: XMLHttpRequest;
  error?: string;
}

interface UploadsState {
  uploads: Upload[];
}

export const useUploads = create<UploadsState>(() => ({ uploads: [] }));

const queue: { file: File; urlFor: (name: string) => string }[] = [];
let active = 0;
const MAX_CONCURRENT = 2;

function startNext(onDone: () => void) {
  while (active < MAX_CONCURRENT && queue.length > 0) {
    const { file, urlFor } = queue.shift()!;
    active += 1;
    const key = `${file.name}-${Date.now()}-${Math.random()}`;
    const xhr = new XMLHttpRequest();
    useUploads.setState((state) => ({
      uploads: [...state.uploads, { key, filename: file.name, fraction: 0, xhr }],
    }));
    const finish = (error?: string) => {
      active -= 1;
      useUploads.setState((state) => ({
        uploads: error
          ? state.uploads.map((upload) =>
              upload.key === key ? { ...upload, error } : upload,
            )
          : state.uploads.filter((upload) => upload.key !== key),
      }));
      onDone();
      startNext(onDone);
    };
    xhr.upload.onprogress = (event) => {
      if (!event.lengthComputable) return;
      const fraction = event.loaded / event.total;
      useUploads.setState((state) => ({
        uploads: state.uploads.map((upload) =>
          upload.key === key ? { ...upload, fraction } : upload,
        ),
      }));
    };
    xhr.onload = () => {
      if (xhr.status >= 200 && xhr.status < 300) finish();
      else {
        let message = `${xhr.status}`;
        try {
          message = JSON.parse(xhr.responseText).error.message;
        } catch {
          /* keep status */
        }
        finish(message);
      }
    };
    xhr.onerror = () => finish("network error");
    xhr.onabort = () => finish();
    xhr.open("POST", urlFor(file.name));
    xhr.setRequestHeader("Content-Type", "application/epub+zip");
    xhr.send(file);
  }
}

export function enqueueUploads(
  files: File[],
  onDone: () => void,
  urlFor: (name: string) => string = (name) =>
    `/api/drafts/upload?filename=${encodeURIComponent(name)}`,
) {
  queue.push(
    ...files
      .filter((file) => file.name.toLowerCase().endsWith(".epub"))
      .map((file) => ({ file, urlFor })),
  );
  startNext(onDone);
}

export function cancelUpload(key: string) {
  const upload = useUploads.getState().uploads.find((u) => u.key === key);
  upload?.xhr.abort();
}

export function dismissUpload(key: string) {
  useUploads.setState((state) => ({
    uploads: state.uploads.filter((upload) => upload.key !== key),
  }));
}

export function hasActiveUploads(): boolean {
  return useUploads.getState().uploads.some((upload) => !upload.error);
}

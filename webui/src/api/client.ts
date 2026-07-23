import type { APIErrorEnvelope } from "./types";

export class APIError extends Error {
  readonly code: string;
  readonly status: number;

  constructor(status: number, code: string, message: string) {
    super(message);
    this.code = code;
    this.status = status;
  }
}

/** JSON fetch against the same-origin /api surface with the envelope
 *  decoded into a typed error. */
export async function api<T>(
  path: string,
  init?: RequestInit & { signal?: AbortSignal },
): Promise<T> {
  const response = await fetch(path, {
    headers: { Accept: "application/json", ...(init?.body ? { "Content-Type": "application/json" } : {}) },
    ...init,
  });
  if (!response.ok) {
    let code = "http_error";
    let message = `${response.status} ${response.statusText}`;
    try {
      const envelope = (await response.json()) as APIErrorEnvelope;
      code = envelope.error.code;
      message = envelope.error.message;
    } catch {
      // Non-JSON error body; keep the status text.
    }
    throw new APIError(response.status, code, message);
  }
  if (response.status === 204) return undefined as T;
  return (await response.json()) as T;
}

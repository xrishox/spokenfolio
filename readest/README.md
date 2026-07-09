# Readest: OpenAI-compatible Siri TTS client

The patch stack in [`patches/`](patches/) is based directly on the official
[readest/readest](https://github.com/readest/readest) `main` branch. The
convenience fork is [xrishox/readest](https://github.com/xrishox/readest); it is
a fork of that official repository, not a separate upstream.

The changes add a self-hosted OpenAI-compatible TTS choice and keep the codec
and lookahead work inside the fork-added client files so future upstream
rebases remain small.

## Runtime behavior

- Probes the device's real `AudioContext.decodeAudioData` support with valid
  local fixtures and chooses Ogg Opus, AAC/M4A, or WAV in that order.
- Pins the working codec per endpoint for the app session and retries the same
  sentence after a genuine format/decode failure.
- Preserves the response's real MIME type and isolates caches by endpoint,
  authorization fingerprint, payload, and format.
- Uses one ordered window of ten fetch jobs (current sentence plus nine ahead).
  Preload shares its bounded priority pool; network completion may be out of
  order, but playback is not.
- Does not downgrade codecs for authentication errors, rate limits, or ordinary
  transient network failures.

This code path is shared by Readest's desktop and mobile webviews. No Opus or
AAC assumption is tied to the operating-system name: the actual decoder probe
decides, and WAV remains the universal final rung.

## Build the Linux AppImage

```bash
./build-appimage.sh
```

The script clones official Readest, checks out the exact commit recorded in
`patches/BASE_COMMIT`, applies every patch, installs dependencies, and runs the
Tauri AppImage build. Build dependencies are listed at the top of the script.

For iOS, Android, Windows, or macOS, apply the same patch series to a normal
Readest checkout and use that platform's existing Readest/Tauri build command.

## Configure Readest

1. Start the Mac server with `../server/install.sh`.
2. Open a book and select **OpenAI-Compatible TTS**.
3. Set the endpoint to `http://<mac-address>:8787`.
4. Leave the API key empty for the supplied local server, or provide the key
   required by a reverse proxy.
5. Select a full Siri asset id and start reading.

## Maintaining the patch stack

Always rebase against the official remote:

```bash
git remote add upstream https://github.com/readest/readest.git
git fetch upstream
git rebase upstream/main
```

After tests pass, regenerate the canonical patches and base marker:

```bash
rm -f /path/to/macos-tts-server/readest/patches/*.patch
git format-patch upstream/main -o /path/to/macos-tts-server/readest/patches
git rev-parse upstream/main > /path/to/macos-tts-server/readest/patches/BASE_COMMIT
```

Keep unrelated packaging work on a separate stacked branch so codec changes
can continue to rebase independently.

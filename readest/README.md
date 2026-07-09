# Readest fork: OpenAI-compatible TTS client

Our Readest changes live on branch `custom-openai-tts`:

- Fork: https://github.com/xrishox/readest (branch `custom-openai-tts`)
- Also distributed as patch files in `patches/` (applied on top of the upstream commit
  recorded in `patches/BASE_COMMIT`), which is what `build-appimage.sh` uses.

Nothing is ever submitted upstream (no PRs/issues).

## Build the AppImage (on the Linux box)

```bash
./build-appimage.sh
```

The script clones upstream Readest, applies the patches, and runs the Tauri AppImage
build. Install the build deps listed at the top of the script first.

## Use it

1. Start the Mac server (`../server/install.sh`, or it auto-starts at login).
2. Launch the patched AppImage.
3. Open a book → TTS panel → select the **OpenAI-compatible TTS** client.
4. Set the endpoint URL: `http://<mac-address>:8787` (API key: leave empty).
5. Pick a voice (Premium/Enhanced tiers are labeled) and read.

## Maintaining the fork

To rebase onto a newer Readest: in a clone, `git checkout custom-openai-tts`,
`git rebase <new-upstream-tag>`, resolve conflicts (the diff is one new client file plus
small settings/controller edits), then regenerate patches:

```bash
git format-patch <new-upstream-tag> -o /path/to/this/repo/readest/patches/
git rev-parse <new-upstream-tag> > /path/to/this/repo/readest/patches/BASE_COMMIT
```

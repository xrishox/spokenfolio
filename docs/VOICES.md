# Getting high-quality Apple voices

Out of the box, macOS only has *default*-quality (compact) voices installed — fine for
directions, underwhelming for audiobooks. The good voices are free downloads:

1. Open **System Settings → Accessibility → Spoken Content**.
2. Click **System Voices → Manage Voices…**.
3. Find a language (e.g. English (US)) and download voices marked **(Enhanced)** or
   **(Premium)**. Premium is the highest tier. Good audiobook picks for en-US:
   **Zoe (Premium)**, **Ava (Premium)**, **Evan (Enhanced)**, **Nathan (Enhanced)**.
   Each is a few hundred MB.

No restart needed — the server picks up new voices on its next start:

```bash
launchctl kickstart -k gui/$(id -u)/com.local.speech-server
```

Verify they're visible (the smoke test also reports quality tiers):

```bash
curl -s http://localhost:8787/v1/audio/voices/all | python3 -m json.tool | grep -B2 -A1 premium
```

Select voices by **full identifier** (e.g. `com.apple.voice.premium.en-US.Zoe`) — names
alone are ambiguous when the same voice exists at multiple quality tiers.

**Not available:** Siri voices. Apple does not expose them to any public API (`say`,
AVSpeechSynthesizer, or anything else). Premium is the best accessible tier.

**Sample a voice:**

```bash
curl -s -X POST http://localhost:8787/v1/audio/speech \
  -H 'Content-Type: application/json' \
  -d '{"model":"tts-1","input":"This is what I sound like reading your book.","voice":"com.apple.voice.premium.en-US.Zoe"}' \
  -o sample.wav && afplay sample.wav
```

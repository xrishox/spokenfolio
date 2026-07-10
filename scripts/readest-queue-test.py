#!/usr/bin/env python3
"""Exercise Siri TTS using Readest's ordered, ten-request lookahead window."""

import concurrent.futures
import json
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path


SENTENCES = [
    "The morning train crossed the river while the city slowly woke beneath a pale blue sky.",
    "Mara closed the old book and listened to rain tapping gently against the library windows.",
    "Beyond the garden wall, a narrow path wound uphill through cedar trees and silver mist.",
    "Every successful journey begins with a clear destination and one deliberate first step.",
    "The captain checked the compass twice before steering the vessel toward the distant harbor.",
    "Warm bread, fresh coffee, and quiet conversation made the little kitchen feel like home.",
    "A red fox paused at the edge of the meadow, alert to every sound carried by the wind.",
    "By noon, the clouds had lifted and sunlight glittered across the surface of the lake.",
    "The engineer reviewed each measurement carefully before allowing the final test to begin.",
    "Sometimes the most important details are hidden between ordinary moments.",
    "An ancient clock in the hallway marked each hour with a deep and patient chime.",
    "She packed only what she needed: a map, a notebook, and courage for the road ahead.",
    "The orchestra fell silent for one breath before the conductor raised her hand again.",
    "Snow gathered on the rooftops while golden light shone from every window.",
    "Good tools disappear into the work, leaving people free to focus on what matters.",
    "At the summit, they could see green valleys stretching all the way to the western sea.",
    "The scientist repeated the experiment until the unexpected result could not be dismissed.",
    "A soft breeze moved through the window and scattered papers across the wooden floor.",
    "He told the story slowly, giving every character enough room to become real.",
    "When the final sentence ended, the room remained quiet before the next chapter began.",
]


def main() -> None:
    server = (sys.argv[1] if len(sys.argv) > 1 else "http://nac:8787").rstrip("/")
    window = 10
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    output = Path(tempfile.mkdtemp(prefix="readest-siri-tts-"))

    with opener.open(server + "/v1/audio/voices/all", timeout=15) as response:
        voices = json.load(response).get("voices", [])
    if not voices:
        raise SystemExit("FAIL: server returned no Siri voices")

    selected = next((v for v in voices if ".natural." in v.get("id", "").lower()), None)
    selected = selected or next((v for v in voices if v.get("quality") == "premium"), None)
    selected = selected or voices[0]
    voice = selected["id"]

    print(f"Server: {server}")
    print(f"Voice:  {selected.get('name', voice)} ({voice})")
    print(f"Output: {output}")
    print(f"Submitting a Readest-style ordered window of {window} requests...\n")

    def synthesize(index: int, sentence: str):
        payload = json.dumps({
            "model": "tts-1",
            "input": sentence,
            "voice": voice,
            "response_format": "opus",
            "speed": 1.0,
        }).encode()
        request = urllib.request.Request(
            server + "/v1/audio/speech",
            data=payload,
            headers={"Content-Type": "application/json", "Accept": "audio/ogg"},
            method="POST",
        )
        began = time.monotonic()
        with opener.open(request, timeout=120) as response:
            audio = response.read()
            content_type = response.headers.get("Content-Type", "")
        if not audio.startswith(b"OggS"):
            raise RuntimeError(f"sentence {index}: response is not an Ogg stream")
        if "audio/ogg" not in content_type.lower():
            raise RuntimeError(f"sentence {index}: unexpected Content-Type {content_type!r}")
        path = output / f"{index:02d}.ogg"
        path.write_bytes(audio)
        return path, len(audio), time.monotonic() - began

    def verify(index: int, result) -> str:
        path, byte_count, latency = result
        if shutil.which("ffprobe"):
            probe = subprocess.run(
                [
                    "ffprobe", "-v", "error", "-select_streams", "a:0",
                    "-show_entries", "stream=codec_name,sample_rate,channels",
                    "-of", "default=noprint_wrappers=1", str(path),
                ],
                capture_output=True,
                text=True,
                check=True,
            ).stdout.strip().replace("\n", ", ")
            if "codec_name=opus" not in probe:
                raise RuntimeError(f"sentence {index}: ffprobe did not identify Opus: {probe}")
        else:
            probe = "Ogg signature valid (install ffmpeg for codec validation)"
        return f"{path.name}, {byte_count / 1024:.1f} KiB, {latency:.2f}s, {probe}"

    started = time.monotonic()
    with concurrent.futures.ThreadPoolExecutor(max_workers=window) as executor:
        active = {}
        next_to_start = 1
        while next_to_start <= window:
            active[next_to_start] = executor.submit(
                synthesize, next_to_start, SENTENCES[next_to_start - 1]
            )
            print(f"QUEUED   {next_to_start:02d}")
            next_to_start += 1

        for index in range(1, len(SENTENCES) + 1):
            result = active.pop(index).result()
            print(f"CONSUMED {index:02d} in order: {verify(index, result)}")
            if next_to_start <= len(SENTENCES):
                active[next_to_start] = executor.submit(
                    synthesize, next_to_start, SENTENCES[next_to_start - 1]
                )
                print(f"QUEUED   {next_to_start:02d}")
                next_to_start += 1

    elapsed = time.monotonic() - started
    print(f"\nPASS: 20 sentences, ordered 10-wide window, {elapsed:.2f}s total")
    print(f"Audio files retained in: {output}")


if __name__ == "__main__":
    main()

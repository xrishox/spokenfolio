#!/usr/bin/env python3
"""Compare whole-EPUB text with Storyteller transcripts using unique n-grams."""

from __future__ import annotations

import argparse
import importlib.util
import json
import re
from pathlib import Path
from xml.etree import ElementTree as ET
from zipfile import ZipFile


def load_audit_module():
    path = Path(__file__).with_name("audit_readalouds.py")
    spec = importlib.util.spec_from_file_location("readaloud_audit", path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


audit = load_audit_module()


def epub_tokens(path: Path) -> list[str]:
    chunks = []
    with ZipFile(path) as archive:
        for name in archive.namelist():
            if not name.lower().endswith((".xhtml", ".html", ".htm")):
                continue
            raw = archive.read(name)
            try:
                chunks.append(" ".join(ET.fromstring(raw).itertext()))
            except ET.ParseError:
                chunks.append(re.sub(r"<[^>]+>", " ", raw.decode("utf-8", "ignore")))
    return audit.tokens(" ".join(chunks))


def transcript_value(data: dict) -> str:
    if isinstance(data.get("transcript"), str):
        return data["transcript"]
    timeline = data.get("timeline") or data.get("wordTimeline") or []
    return " ".join(str(item.get("text", "")) for item in timeline if isinstance(item, dict))


def transcript_tokens(directory: Path) -> list[str]:
    chunks = []
    for path in sorted(directory.glob("*.json")):
        try:
            chunks.append(transcript_value(json.loads(path.read_text(encoding="utf-8"))))
        except (OSError, ValueError, TypeError):
            continue
    return audit.tokens(" ".join(chunks))


def grams(values: list[str], width: int) -> set[tuple[str, ...]]:
    return {
        tuple(values[index : index + width])
        for index in range(max(0, len(values) - width + 1))
    }


def identity_hint(transcript_coverage: float | None, epub_coverage: float | None) -> str:
    if transcript_coverage is None or epub_coverage is None:
        return "insufficient_evidence"
    if transcript_coverage < 0.10 and epub_coverage < 0.10:
        return "probable_wrong_work_or_translation"
    if transcript_coverage >= 0.70 and epub_coverage < 0.60:
        return "probable_edition_or_abridgment_mismatch"
    if transcript_coverage >= 0.70 and epub_coverage >= 0.70:
        return "same_work_likely"
    return "review"


def choose_epub(directory: Path) -> Path | None:
    candidates = sorted((directory / "text").glob("*.epub"))
    if not candidates:
        candidates = sorted((directory / "aligned").glob("*.epub"))
    return candidates[0] if candidates else None


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Detect wrong works, translations, and edition asymmetry before timing analysis."
    )
    parser.add_argument("--assets-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, default=Path("content-identity.json"))
    parser.add_argument("--book", action="append", help="exact book-folder name; repeatable")
    parser.add_argument("--width", type=int, default=5, help="n-gram width (default: 5)")
    args = parser.parse_args()
    if args.width < 2:
        parser.error("--width must be at least 2")

    if args.book:
        books = args.book
    else:
        books = sorted(path.name for path in args.assets_root.iterdir() if path.is_dir())

    rows = []
    for index, book in enumerate(books, 1):
        directory = args.assets_root / book
        epub = choose_epub(directory)
        transcripts = directory / "transcriptions"
        print(f"[{index}/{len(books)}] {book}", flush=True)
        if epub is None or not transcripts.is_dir():
            rows.append(
                {
                    "book": book,
                    "identity_hint": "insufficient_evidence",
                    "error": "missing text/aligned EPUB or transcriptions directory",
                }
            )
            continue
        ebook_words = epub_tokens(epub)
        spoken_words = transcript_tokens(transcripts)
        ebook_grams = grams(ebook_words, args.width)
        spoken_grams = grams(spoken_words, args.width)
        overlap = ebook_grams & spoken_grams
        ebook_coverage = len(overlap) / len(ebook_grams) if ebook_grams else None
        spoken_coverage = len(overlap) / len(spoken_grams) if spoken_grams else None
        rows.append(
            {
                "book": book,
                "epub": str(epub),
                "ngram_width": args.width,
                "epub_tokens": len(ebook_words),
                "transcript_tokens": len(spoken_words),
                "epub_unique_ngrams": len(ebook_grams),
                "transcript_unique_ngrams": len(spoken_grams),
                "shared_unique_ngrams": len(overlap),
                "epub_ngram_coverage": ebook_coverage,
                "transcript_ngram_coverage": spoken_coverage,
                "jaccard": (
                    len(overlap) / len(ebook_grams | spoken_grams)
                    if ebook_grams or spoken_grams
                    else None
                ),
                "identity_hint": identity_hint(spoken_coverage, ebook_coverage),
            }
        )

    audit.atomic_json(args.output, rows)
    counts = {}
    for row in rows:
        hint = row["identity_hint"]
        counts[hint] = counts.get(hint, 0) + 1
    print(json.dumps({"books": len(rows), "hints": counts}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

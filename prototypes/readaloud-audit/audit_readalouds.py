#!/usr/bin/env python3
"""Systematic, read-only Storyteller ReadAloud EPUB alignment audit.

This is an isolated prototype. It depends on the on-disk Storyteller work
layout but does not import or modify SpokenFolio application code. Checkpoints
make long corpus scans safely resumable.
"""

from __future__ import annotations

import argparse
import bisect
import csv
import hashlib
import json
import math
import os
import posixpath
import re
import shutil
import statistics
import subprocess
import sys
import time
import unicodedata
import urllib.parse
import zlib
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor, as_completed
from difflib import SequenceMatcher
from html.parser import HTMLParser
from pathlib import Path
from tempfile import NamedTemporaryFile
from typing import Any, Iterable
from xml.etree import ElementTree as ET
from zipfile import BadZipFile, ZipFile


DEFAULT_OUTPUT = Path("readaloud-audit-output")
FFPROBE_EXECUTABLE = shutil.which("ffprobe") or "ffprobe"
SENTENCE_ID = re.compile(r"-s\d+$")
TOKEN = re.compile(r"[^\W_]+(?:'[^\W_]+)?", re.UNICODE)
NS_CONTAINER = {"c": "urn:oasis:names:tc:opendocument:xmlns:container"}


def local_name(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def atomic_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with NamedTemporaryFile("w", encoding="utf-8", dir=path.parent, delete=False) as handle:
        json.dump(value, handle, indent=2, ensure_ascii=False, sort_keys=True)
        handle.write("\n")
        temporary = Path(handle.name)
    os.replace(temporary, path)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(4 * 1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def crc32(path: Path) -> int:
    value = 0
    with path.open("rb") as handle:
        while chunk := handle.read(4 * 1024 * 1024):
            value = zlib.crc32(chunk, value)
    return value & 0xFFFFFFFF


def normalize_text(value: str) -> str:
    value = unicodedata.normalize("NFKC", value).casefold()
    return value.replace("’", "'").replace("‘", "'")


def tokens(value: str) -> list[str]:
    return TOKEN.findall(normalize_text(value))


def excerpt(value: str, limit: int = 20) -> str:
    words = value.replace("\n", " ").split()
    result = " ".join(words[:limit])
    return result + (" …" if len(words) > limit else "")


def parse_clock(value: str | None) -> float:
    if value is None:
        raise ValueError("missing clock value")
    raw = value.strip().lower()
    if raw.endswith("ms"):
        return float(raw[:-2]) / 1000.0
    if raw.endswith("s"):
        return float(raw[:-1])
    if raw.endswith("min"):
        return float(raw[:-3]) * 60.0
    if raw.endswith("h"):
        return float(raw[:-1]) * 3600.0
    parts = raw.split(":")
    if len(parts) > 1:
        return sum(float(part) * (60**index) for index, part in enumerate(reversed(parts)))
    return float(raw)


def resolve_member(base: str, reference: str) -> tuple[str, str | None]:
    parsed = urllib.parse.urlsplit(reference)
    if parsed.scheme or parsed.netloc:
        raise ValueError(f"external reference: {reference}")
    decoded = urllib.parse.unquote(parsed.path)
    resolved = posixpath.normpath(posixpath.join(posixpath.dirname(base), decoded))
    if resolved == ".." or resolved.startswith("../") or resolved.startswith("/"):
        raise ValueError(f"unsafe reference: {reference}")
    return resolved, urllib.parse.unquote(parsed.fragment) if parsed.fragment else None


def quantile(values: list[float], fraction: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]
    position = (len(ordered) - 1) * fraction
    low = math.floor(position)
    high = math.ceil(position)
    if low == high:
        return ordered[low]
    return ordered[low] + (ordered[high] - ordered[low]) * (position - low)


def union_duration(intervals: Iterable[tuple[float, float]]) -> float:
    ordered = sorted(intervals)
    if not ordered:
        return 0.0
    total = 0.0
    start, end = ordered[0]
    for next_start, next_end in ordered[1:]:
        if next_start <= end:
            end = max(end, next_end)
        else:
            total += max(0.0, end - start)
            start, end = next_start, next_end
    return total + max(0.0, end - start)


def ffprobe(path: Path) -> dict[str, Any]:
    command = [
        FFPROBE_EXECUTABLE,
        "-v",
        "error",
        "-show_entries",
        "format=duration:format_tags=title,album,artist,composer,author,language:stream=index,codec_type,codec_name,sample_rate,channels",
        "-of",
        "json",
        str(path),
    ]
    try:
        completed = subprocess.run(command, capture_output=True, text=True, timeout=60, check=True)
        data = json.loads(completed.stdout)
        duration = float(data.get("format", {}).get("duration", 0.0) or 0.0)
        audio_stream = next(
            (stream for stream in data.get("streams", []) if stream.get("codec_type") == "audio"),
            {},
        )
        return {
            "duration": duration,
            "codec": audio_stream.get("codec_name"),
            "sample_rate": int(audio_stream.get("sample_rate", 0) or 0),
            "channels": int(audio_stream.get("channels", 0) or 0),
            "tags": data.get("format", {}).get("tags", {}),
            "error": None,
        }
    except Exception as error:  # preserve per-book progress on malformed media
        return {
            "duration": 0.0,
            "codec": None,
            "sample_rate": 0,
            "channels": 0,
            "tags": {},
            "error": str(error),
        }


def probe_many(paths: list[Path], workers: int = 8) -> dict[str, dict[str, Any]]:
    results: dict[str, dict[str, Any]] = {}
    with ThreadPoolExecutor(max_workers=workers) as pool:
        futures = {pool.submit(ffprobe, path): path for path in paths}
        for future in as_completed(futures):
            path = futures[future]
            results[path.name] = future.result()
    return results


def word_timeline(data: dict[str, Any]) -> list[dict[str, Any]]:
    timeline = data.get("timeline") or data.get("wordTimeline") or []
    words = []
    for entry in timeline:
        if entry.get("type", "word") != "word" or not entry.get("text"):
            continue
        start = entry.get("startTime", entry.get("start", 0.0))
        end = entry.get("endTime", entry.get("end", start))
        try:
            words.append({"text": str(entry["text"]), "start": float(start), "end": float(end)})
        except (TypeError, ValueError):
            continue
    words.sort(key=lambda word: (word["start"], word["end"]))
    return words


def score_tokens(reference: list[str], spoken: list[str]) -> tuple[float, float, float, int]:
    if not reference or not spoken:
        return 0.0, 0.0, 0.0, 0
    matcher = SequenceMatcher(None, reference, spoken, autojunk=False)
    matched = sum(block.size for block in matcher.get_matching_blocks())
    recall = matched / len(reference)
    precision = matched / len(spoken)
    f1 = 2 * precision * recall / (precision + recall) if precision + recall else 0.0
    return precision, recall, f1, matched


def title_similarity(first: str | None, second: str | None) -> float | None:
    if not first or not second:
        return None
    a = tokens(first)
    b = tokens(second)
    if not a or not b:
        return None
    return SequenceMatcher(None, a, b, autojunk=False).ratio()


class LenientIDTextParser(HTMLParser):
    """Collect element IDs and descendant text from imperfect XHTML."""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.stack: list[tuple[str, str | None]] = []
        self.buffers: dict[str, list[str]] = defaultdict(list)

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        fragment = next((value for name, value in attrs if name == "id" and value), None)
        self.stack.append((tag, fragment))
        if fragment:
            self.buffers[fragment]

    def handle_startendtag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        fragment = next((value for name, value in attrs if name == "id" and value), None)
        if fragment:
            self.buffers[fragment]

    def handle_endtag(self, tag: str) -> None:
        for index in range(len(self.stack) - 1, -1, -1):
            if self.stack[index][0] == tag:
                del self.stack[index:]
                return

    def handle_data(self, data: str) -> None:
        for _, fragment in self.stack:
            if fragment:
                self.buffers[fragment].append(data)

    def values(self) -> dict[str, str]:
        return {fragment: "".join(parts).strip() for fragment, parts in self.buffers.items()}


def classify(metrics: dict[str, Any]) -> tuple[str, list[str]]:
    reasons: list[str] = []
    if metrics["smil_count"] == 0 or metrics["embedded_audio_count"] == 0:
        return "definite_failure", ["no functional SMIL/audio overlay"]
    if metrics["structural_errors"]:
        return "definite_failure", ["structural errors: " + "; ".join(metrics["structural_errors"][:3])]

    overlay = metrics.get("overlay_coverage")
    raw = metrics.get("raw_match_coverage")
    audio = metrics.get("audio_coverage")
    similarity = metrics.get("weighted_similarity")
    low_fraction = metrics.get("fraction_below_050")
    metadata_contradiction = metrics.get("metadata_contradiction", False)

    if raw is not None and raw < 0.50:
        reasons.append(f"raw sentence match {raw:.1%}")
    if similarity is not None and similarity < 0.60:
        reasons.append(f"semantic similarity {similarity:.1%}")
    if overlay is not None and overlay < 0.25:
        reasons.append(f"marked-text overlay coverage {overlay:.1%}")
    if audio is not None and audio < 0.25:
        reasons.append(f"audio coverage {audio:.1%}")
    if reasons:
        return "definite_failure", reasons

    severe: list[str] = []
    if overlay is not None and overlay < 0.60:
        severe.append(f"overlay {overlay:.1%} < 60%")
    if raw is not None and raw < 0.75:
        severe.append(f"raw match {raw:.1%} < 75%")
    if audio is not None and audio < 0.75:
        severe.append(f"audio {audio:.1%} < 75%")
    if similarity is not None and similarity < 0.70:
        severe.append(f"semantic {similarity:.1%} < 70%")
    if low_fraction is not None and low_fraction > 0.20:
        severe.append(f"{low_fraction:.1%} clips below 50% similarity")
    if metadata_contradiction:
        severe.append("title metadata contradiction")
    if len(severe) >= 2:
        return "definite_failure", severe

    gates: list[str] = []
    if overlay is None or overlay < 0.85:
        gates.append("overlay coverage below 85%")
    if raw is not None and raw < 0.90:
        gates.append("raw sentence match below 90%")
    if audio is None or audio < 0.90:
        gates.append("audio coverage unavailable or below 90%")
    if similarity is None or similarity < 0.85:
        gates.append("semantic similarity unavailable or below 85%")
    if low_fraction is None or low_fraction > 0.05:
        gates.append("more than 5% low-similarity clips or no semantic evidence")
    if metrics.get("longest_low_run", 0) >= 10:
        gates.append("at least 10 consecutive low-similarity clips")
    if metrics.get("provenance_mismatch_count", 0):
        gates.append("embedded audio does not match retained transcript sidecars")
    if metrics.get("zero_duration_clip_count", 0):
        gates.append("zero-duration overlay clip")
    if metrics.get("invalid_clip_count", 0):
        gates.append("invalid overlay clip range")
    if metrics.get("overlap_clip_count", 0):
        gates.append("backward/overlapping clip transition")
    if metadata_contradiction:
        gates.append("title metadata warning")
    if gates:
        return "needs_review", gates
    return "pass", []


class BookAudit:
    def __init__(self, book: str, source_dir: Path, copied_epub: Path):
        self.book = book
        self.source_dir = source_dir
        self.copied_epub = copied_epub
        source_candidates = list((source_dir / "aligned").glob("*.epub"))
        self.source_epub = source_candidates[0] if source_candidates else copied_epub
        self.errors: list[str] = []
        self.warnings: list[str] = []

    def run(self) -> dict[str, Any]:
        started = time.time()
        result: dict[str, Any] = {
            "book": self.book,
            "source_epub": str(self.source_epub),
            "copied_epub": str(self.copied_epub),
            "epub_size": self.copied_epub.stat().st_size,
            "structural_errors": self.errors,
            "warnings": self.warnings,
        }
        try:
            with ZipFile(self.copied_epub) as archive:
                result.update(self.inspect_epub(archive))
        except (BadZipFile, ET.ParseError, OSError, ValueError) as error:
            self.errors.append(f"EPUB parse failed: {error}")
            result.update(
                {
                    "smil_count": 0,
                    "embedded_audio_count": 0,
                    "structural_errors": self.errors,
                    "warnings": self.warnings,
                }
            )

        report_path = self.source_dir / ".storyteller" / "report.json"
        raw_match = None
        report_schema = "missing"
        if report_path.exists():
            try:
                report = json.loads(report_path.read_text(encoding="utf-8"))
                chapters = report.get("chapters") or []
                aligned = sum(int(chapter.get("alignedSentenceCount", 0) or 0) for chapter in chapters)
                chapter_total = sum(int(chapter.get("chapterSentenceCount", 0) or 0) for chapter in chapters)
                raw_match = aligned / chapter_total if chapter_total else None
                report_schema = "current" if "audioFiles" in report else "legacy"
                result["report_aligned_sentences"] = aligned
                result["report_chapter_sentences"] = chapter_total
                result["report_aligned_chapters"] = len(chapters)
                result["report_unaligned_chapters"] = len(report.get("unalignedChapters") or [])
                result["report_unaligned_audio"] = len(report.get("unalignedAudioFiles") or [])
                report_audio = report.get("audioFiles") or []
                report_audio_total = sum(float(item.get("duration", 0.0) or 0.0) for item in report_audio)
                report_audio_aligned = sum(
                    float(item.get("alignedDuration", 0.0) or 0.0) for item in report_audio
                )
                result["report_audio_coverage"] = (
                    report_audio_aligned / report_audio_total if report_audio_total else None
                )
                if result["report_audio_coverage"] is not None:
                    result["smil_audio_coverage"] = result.get("audio_coverage")
                    result["audio_coverage"] = result["report_audio_coverage"]
            except Exception as error:
                self.warnings.append(f"could not parse Storyteller report: {error}")
        result["raw_match_coverage"] = raw_match
        result["report_schema"] = report_schema

        first_transcript = next(iter(sorted((self.source_dir / "transcriptions").glob("*.json"))), None)
        if first_transcript:
            try:
                first_data = json.loads(first_transcript.read_text(encoding="utf-8"))
                result["first_announcement"] = excerpt(str(first_data.get("transcript", "")), 35)
            except Exception as error:
                self.warnings.append(f"could not read first transcript: {error}")
                result["first_announcement"] = ""
        else:
            result["first_announcement"] = ""

        audiobook = next(iter(sorted((self.source_dir / "audio").glob("*"))), None)
        if audiobook and audiobook.is_file():
            source_audio = ffprobe(audiobook)
            result["source_audiobook"] = str(audiobook)
            result["source_audiobook_duration"] = source_audio["duration"]
            result["source_audiobook_tags"] = source_audio["tags"]
            audio_title = source_audio["tags"].get("title") or source_audio["tags"].get("album") or audiobook.stem
            result["audio_title"] = audio_title
            result["title_similarity"] = title_similarity(result.get("epub_title"), audio_title)
            result["metadata_contradiction"] = (
                result["title_similarity"] is not None and result["title_similarity"] < 0.35
            )
        else:
            result["source_audiobook"] = None
            result["metadata_contradiction"] = False

        severity, reasons = classify(result)
        result["auto_severity"] = severity
        result["auto_reasons"] = reasons
        result["final_category"] = severity
        result["elapsed_seconds"] = round(time.time() - started, 3)
        return result

    def inspect_epub(self, archive: ZipFile) -> dict[str, Any]:
        names = archive.namelist()
        name_set = set(names)
        for name in names:
            normalized = posixpath.normpath(name)
            if name.startswith("/") or normalized == ".." or normalized.startswith("../"):
                self.errors.append(f"unsafe ZIP member: {name}")

        mimetype_ok = bool(names and names[0] == "mimetype" and archive.read("mimetype") == b"application/epub+zip")
        if not mimetype_ok:
            self.warnings.append("mimetype is missing, not first, or has the wrong value")

        container = ET.fromstring(archive.read("META-INF/container.xml"))
        rootfile = container.find(".//c:rootfile", NS_CONTAINER)
        if rootfile is None or not rootfile.get("full-path"):
            raise ValueError("container.xml has no rootfile")
        opf_path = rootfile.get("full-path")
        assert opf_path is not None
        if opf_path not in name_set:
            raise ValueError(f"missing OPF: {opf_path}")
        opf = ET.fromstring(archive.read(opf_path))

        metadata: dict[str, list[str]] = defaultdict(list)
        duration_meta: dict[str | None, float] = {}
        for element in opf.iter():
            name = local_name(element.tag)
            value = "".join(element.itertext()).strip()
            if name in {"title", "creator", "language", "identifier"} and value:
                metadata[name].append(value)
            if name == "meta" and element.get("property") == "media:duration" and value:
                try:
                    refines = element.get("refines")
                    duration_meta[refines[1:] if refines and refines.startswith("#") else None] = parse_clock(value)
                except ValueError:
                    self.warnings.append(f"invalid media:duration value {value!r}")

        manifest: dict[str, dict[str, Any]] = {}
        for element in opf.iter():
            if local_name(element.tag) != "item" or not element.get("id") or not element.get("href"):
                continue
            try:
                member, _ = resolve_member(opf_path, element.get("href", ""))
            except ValueError as error:
                self.errors.append(str(error))
                continue
            manifest[element.get("id", "")] = {
                "id": element.get("id"),
                "href": element.get("href"),
                "member": member,
                "media_type": element.get("media-type"),
                "media_overlay": element.get("media-overlay"),
                "properties": (element.get("properties") or "").split(),
            }

        spine_ids = [
            element.get("idref", "")
            for element in opf.iter()
            if local_name(element.tag) == "itemref" and element.get("idref")
        ]
        spine_items = [manifest[item_id] for item_id in spine_ids if item_id in manifest]
        if len(spine_items) != len(spine_ids):
            self.errors.append("spine contains unresolved manifest idref")

        content_items = [
            item
            for item in manifest.values()
            if item["media_type"] in {"application/xhtml+xml", "text/html"}
            or item["member"].lower().endswith((".xhtml", ".html", ".htm"))
        ]
        document_ids: dict[str, dict[str, str]] = {}
        marked_spine: set[str] = set()
        spine_members = {item["member"] for item in spine_items}
        for item in content_items:
            member = item["member"]
            if member not in name_set:
                self.errors.append(f"missing content document: {member}")
                continue
            try:
                root = ET.fromstring(archive.read(member))
                ids = {
                    element.get("id", ""): "".join(element.itertext()).strip()
                    for element in root.iter()
                    if element.get("id")
                }
                document_ids[member] = ids
                if member in spine_members:
                    marked_spine.update(
                        f"{member}#{fragment}" for fragment in ids if SENTENCE_ID.search(fragment)
                    )
            except ET.ParseError as error:
                parser = LenientIDTextParser()
                try:
                    parser.feed(archive.read(member).decode("utf-8", "replace"))
                    ids = parser.values()
                    document_ids[member] = ids
                    if member in spine_members:
                        marked_spine.update(
                            f"{member}#{fragment}" for fragment in ids if SENTENCE_ID.search(fragment)
                        )
                    self.warnings.append(f"leniently parsed non-well-formed content {member}: {error}")
                except Exception as fallback_error:
                    self.errors.append(
                        f"could not parse content {member}: XML {error}; HTML fallback {fallback_error}"
                    )

        overlay_smil_ids: list[str] = []
        for item in spine_items:
            overlay_id = item.get("media_overlay")
            if overlay_id:
                if overlay_id not in manifest:
                    self.errors.append(f"unresolved media-overlay {overlay_id} for {item['member']}")
                else:
                    overlay_smil_ids.append(overlay_id)
        for item in manifest.values():
            if item["media_type"] == "application/smil+xml" and item["id"] not in overlay_smil_ids:
                overlay_smil_ids.append(item["id"])

        clips: list[dict[str, Any]] = []
        referenced_sentences: set[str] = set()
        referenced_audio: set[str] = set()
        smil_durations: dict[str, float] = {}
        zero_duration = 0
        invalid_clip_count = 0
        overlap_clip_count = 0
        last_end_by_audio: dict[str, float] = {}
        smil_count = 0
        for smil_id in overlay_smil_ids:
            item = manifest.get(smil_id)
            if not item:
                continue
            smil_member = item["member"]
            if smil_member not in name_set:
                self.errors.append(f"missing SMIL document: {smil_member}")
                continue
            if item["media_type"] != "application/smil+xml":
                self.errors.append(f"SMIL {smil_member} has media type {item['media_type']}")
            try:
                smil_root = ET.fromstring(archive.read(smil_member))
            except ET.ParseError as error:
                self.errors.append(f"invalid SMIL XML {smil_member}: {error}")
                continue
            smil_count += 1
            smil_total = 0.0
            for par in (element for element in smil_root.iter() if local_name(element.tag) == "par"):
                text_element = next((element for element in par if local_name(element.tag) == "text"), None)
                audio_element = next((element for element in par if local_name(element.tag) == "audio"), None)
                if text_element is None or audio_element is None:
                    self.errors.append(f"SMIL par without text and audio in {smil_member}")
                    continue
                try:
                    text_member, fragment = resolve_member(smil_member, text_element.get("src", ""))
                    audio_member, _ = resolve_member(smil_member, audio_element.get("src", ""))
                    begin = parse_clock(audio_element.get("clipBegin"))
                    end = parse_clock(audio_element.get("clipEnd"))
                except (ValueError, TypeError) as error:
                    self.errors.append(f"invalid SMIL reference/clock in {smil_member}: {error}")
                    continue
                if not fragment:
                    self.errors.append(f"SMIL text reference has no fragment in {smil_member}")
                    continue
                key = f"{text_member}#{fragment}"
                text = document_ids.get(text_member, {}).get(fragment)
                if text is None:
                    self.errors.append(f"missing text target: {key}")
                    text = ""
                if audio_member not in name_set:
                    self.errors.append(f"missing embedded audio: {audio_member}")
                if begin < 0 or end < begin:
                    invalid_clip_count += 1
                if math.isclose(begin, end, abs_tol=0.0005):
                    zero_duration += 1
                previous_end = last_end_by_audio.get(audio_member)
                if previous_end is not None and begin < previous_end - 0.05:
                    overlap_clip_count += 1
                last_end_by_audio[audio_member] = max(previous_end or 0.0, end)
                referenced_sentences.add(key)
                referenced_audio.add(audio_member)
                smil_total += max(0.0, end - begin)
                clips.append(
                    {
                        "smil": smil_member,
                        "chapter": text_member,
                        "fragment": fragment,
                        "text": text,
                        "audio_member": audio_member,
                        "audio_name": posixpath.basename(audio_member),
                        "begin": begin,
                        "end": end,
                    }
                )
            smil_durations[smil_id] = smil_total
            declared = duration_meta.get(smil_id)
            if declared is None:
                self.warnings.append(f"missing refined media:duration for {smil_id}")
            elif abs(declared - smil_total) > 0.05:
                self.warnings.append(
                    f"duration mismatch for {smil_id}: declared {declared:.3f}, clips {smil_total:.3f}"
                )

        declared_total = duration_meta.get(None)
        clip_total = sum(smil_durations.values())
        if smil_count and declared_total is None:
            self.warnings.append("missing total media:duration")
        elif declared_total is not None and abs(declared_total - clip_total) > 0.10:
            self.warnings.append(
                f"total media:duration mismatch: declared {declared_total:.3f}, clips {clip_total:.3f}"
            )

        audio_items = [
            item
            for item in manifest.values()
            if (item["media_type"] or "").startswith("audio/")
            or item["member"].lower().endswith((".mp3", ".mp4", ".m4a", ".m4b", ".ogg", ".opus"))
        ]
        audio_members = {item["member"] for item in audio_items if item["member"] in name_set}
        orphan_audio = sorted(audio_members - referenced_audio)
        if orphan_audio:
            self.warnings.append(f"{len(orphan_audio)} embedded audio files are not referenced by SMIL")

        sidecar_dir = self.source_dir / "transcoded audio"
        transcript_dir = self.source_dir / "transcriptions"
        sidecars = sorted(sidecar_dir.glob("*.mp4"))
        probes = probe_many(sidecars) if sidecars else {}
        embedded_infos = {
            member: archive.getinfo(member)
            for member in audio_members
            if member in name_set
        }
        exact_audio_names: set[str] = set()
        provenance_mismatch = 0
        missing_sidecar = 0
        for member, info in embedded_infos.items():
            name = posixpath.basename(member)
            sidecar = sidecar_dir / name
            if not sidecar.exists():
                missing_sidecar += 1
                provenance_mismatch += 1
                continue
            if sidecar.stat().st_size != info.file_size:
                provenance_mismatch += 1
                continue
            if crc32(sidecar) != info.CRC:
                provenance_mismatch += 1
                continue
            exact_audio_names.add(name)
            duration = probes.get(name, {}).get("duration", 0.0)
            if duration and last_end_by_audio.get(member, 0.0) > duration + 0.10:
                invalid_clip_count += 1

        intervals_by_audio: dict[str, list[tuple[float, float]]] = defaultdict(list)
        for clip in clips:
            intervals_by_audio[clip["audio_name"]].append((clip["begin"], clip["end"]))
        source_audio_duration = sum(probe.get("duration", 0.0) for probe in probes.values())
        referenced_duration = sum(
            union_duration(intervals_by_audio.get(sidecar.name, [])) for sidecar in sidecars
        )
        audio_coverage = (
            referenced_duration / source_audio_duration
            if source_audio_duration > 0 and provenance_mismatch == 0
            else None
        )

        score_result = self.score_clips(clips, exact_audio_names, transcript_dir)
        codec_counts: dict[str, int] = defaultdict(int)
        for name in exact_audio_names:
            codec_counts[str(probes.get(name, {}).get("codec") or "unknown")] += 1
        if codec_counts.get("opus") and any(
            item["media_type"] == "audio/mp4" for item in audio_items
        ):
            self.warnings.append(
                "Storyteller Opus-in-MP4 is labeled audio/mp4; treat as a compatibility warning, not an alignment failure"
            )
        if overlap_clip_count:
            self.warnings.append(
                f"{overlap_clip_count} backward/overlapping clip transitions require timestamp review"
            )
        if invalid_clip_count:
            self.warnings.append(f"{invalid_clip_count} invalid/out-of-bounds clip ranges require timestamp review")

        overlay_coverage = (
            len(referenced_sentences & marked_spine) / len(marked_spine) if marked_spine else None
        )
        return {
            "mimetype_ok": mimetype_ok,
            "opf_path": opf_path,
            "epub_title": metadata.get("title", [self.book])[0],
            "epub_creators": metadata.get("creator", []),
            "epub_languages": metadata.get("language", []),
            "spine_count": len(spine_items),
            "smil_count": smil_count,
            "smil_par_count": len(clips),
            "embedded_audio_count": len(audio_members),
            "referenced_audio_count": len(referenced_audio),
            "orphan_audio_count": len(orphan_audio),
            "marked_spine_sentences": len(marked_spine),
            "referenced_marked_sentences": len(referenced_sentences & marked_spine),
            "overlay_coverage": overlay_coverage,
            "declared_media_duration": declared_total,
            "clip_media_duration": clip_total,
            "source_transcoded_audio_count": len(sidecars),
            "source_audio_duration": source_audio_duration,
            "referenced_audio_duration": referenced_duration,
            "audio_coverage": audio_coverage,
            "audio_codecs": dict(codec_counts),
            "provenance_exact_count": len(exact_audio_names),
            "provenance_mismatch_count": provenance_mismatch,
            "missing_sidecar_count": missing_sidecar,
            "zero_duration_clip_count": zero_duration,
            "invalid_clip_count": invalid_clip_count,
            "overlap_clip_count": overlap_clip_count,
            "structural_errors": self.errors,
            "warnings": self.warnings,
            **score_result,
        }

    def score_clips(
        self, clips: list[dict[str, Any]], exact_audio_names: set[str], transcript_dir: Path
    ) -> dict[str, Any]:
        clips_by_audio: dict[str, list[tuple[int, dict[str, Any]]]] = defaultdict(list)
        for index, clip in enumerate(clips):
            clips_by_audio[clip["audio_name"]].append((index, clip))

        scores_by_index: dict[int, dict[str, Any]] = {}
        missing_transcripts = 0
        for audio_name, audio_clips in clips_by_audio.items():
            if audio_name not in exact_audio_names:
                continue
            transcript_path = transcript_dir / f"{Path(audio_name).stem}.json"
            if not transcript_path.exists():
                missing_transcripts += 1
                continue
            try:
                data = json.loads(transcript_path.read_text(encoding="utf-8"))
                words = word_timeline(data)
            except Exception as error:
                self.warnings.append(f"invalid transcript {transcript_path.name}: {error}")
                missing_transcripts += 1
                continue
            starts = [word["start"] for word in words]
            for index, clip in audio_clips:
                reference = tokens(clip["text"])
                if len(reference) < 5:
                    continue
                low = max(0, bisect.bisect_left(starts, clip["begin"]) - 3)
                high = min(len(words), bisect.bisect_left(starts, clip["end"]) + 3)
                selected = [
                    word["text"]
                    for word in words[low:high]
                    if clip["begin"] - 0.03
                    <= (word["start"] + word["end"]) / 2
                    <= clip["end"] + 0.03
                ]
                spoken = tokens(" ".join(selected))
                precision, recall, f1, matched = score_tokens(reference, spoken)
                scores_by_index[index] = {
                    "f1": f1,
                    "precision": precision,
                    "recall": recall,
                    "matched": matched,
                    "reference_tokens": len(reference),
                    "spoken_tokens": len(spoken),
                    "spoken": " ".join(selected),
                }

        eligible = [scores_by_index[index] for index in sorted(scores_by_index)]
        values = [score["f1"] for score in eligible]
        token_weight = sum(score["reference_tokens"] for score in eligible)
        weighted = (
            sum(score["f1"] * score["reference_tokens"] for score in eligible) / token_weight
            if token_weight
            else None
        )
        low_indices = {index for index, score in scores_by_index.items() if score["f1"] < 0.50}
        longest_run = 0
        current_run = 0
        current_indices: list[int] = []
        worst_run_indices: list[int] = []
        for index in range(len(clips)):
            if index in low_indices:
                current_run += 1
                current_indices.append(index)
                if current_run > longest_run:
                    longest_run = current_run
                    worst_run_indices = list(current_indices)
            else:
                current_run = 0
                current_indices = []

        worst = sorted(scores_by_index.items(), key=lambda pair: (pair[1]["f1"], -pair[1]["reference_tokens"]))[:20]
        evidence_indices = []
        if worst_run_indices:
            evidence_indices.extend(
                [worst_run_indices[0], worst_run_indices[len(worst_run_indices) // 2], worst_run_indices[-1]]
            )
        evidence_indices.extend(index for index, _ in worst[:6])
        evidence = []
        for index in dict.fromkeys(evidence_indices):
            if index not in scores_by_index:
                continue
            clip = clips[index]
            score = scores_by_index[index]
            evidence.append(
                {
                    "chapter": clip["chapter"],
                    "fragment": clip["fragment"],
                    "audio": clip["audio_name"],
                    "clip_begin": clip["begin"],
                    "clip_end": clip["end"],
                    "similarity": score["f1"],
                    "reference_excerpt": excerpt(clip["text"]),
                    "transcript_excerpt": excerpt(score["spoken"]),
                }
            )

        chapter_scores: dict[str, list[dict[str, Any]]] = defaultdict(list)
        for index, score in scores_by_index.items():
            chapter_scores[clips[index]["chapter"]].append(score)
        chapter_summary = []
        for chapter, chapter_values in chapter_scores.items():
            weight = sum(value["reference_tokens"] for value in chapter_values)
            chapter_summary.append(
                {
                    "chapter": chapter,
                    "eligible_clips": len(chapter_values),
                    "weighted_similarity": (
                        sum(value["f1"] * value["reference_tokens"] for value in chapter_values) / weight
                        if weight
                        else None
                    ),
                    "fraction_below_050": sum(value["f1"] < 0.50 for value in chapter_values)
                    / len(chapter_values),
                }
            )
        chapter_summary.sort(key=lambda value: value["weighted_similarity"] or 0.0)

        return {
            "eligible_clip_count": len(eligible),
            "missing_transcript_count": missing_transcripts,
            "weighted_similarity": weighted,
            "similarity_p01": quantile(values, 0.01),
            "similarity_p05": quantile(values, 0.05),
            "similarity_p10": quantile(values, 0.10),
            "similarity_median": statistics.median(values) if values else None,
            "fraction_below_050": sum(value < 0.50 for value in values) / len(values) if values else None,
            "fraction_below_070": sum(value < 0.70 for value in values) / len(values) if values else None,
            "fraction_below_080": sum(value < 0.80 for value in values) / len(values) if values else None,
            "longest_low_run": longest_run,
            "worst_chapters": chapter_summary[:15],
            "evidence": evidence,
        }


def pct(value: Any) -> str:
    return "—" if value is None else f"{float(value):.1%}"


def markdown_escape(value: Any) -> str:
    return str(value).replace("|", "\\|").replace("\n", " ")


def render_outputs(output: Path, rows: list[dict[str, Any]]) -> None:
    rows = sorted(rows, key=lambda row: (row["auto_severity"] != "definite_failure", row["auto_severity"] != "needs_review", row["book"]))
    scalar_fields = [
        "book",
        "auto_severity",
        "final_category",
        "epub_size",
        "smil_count",
        "smil_par_count",
        "embedded_audio_count",
        "marked_spine_sentences",
        "referenced_marked_sentences",
        "overlay_coverage",
        "raw_match_coverage",
        "audio_coverage",
        "weighted_similarity",
        "similarity_p10",
        "similarity_median",
        "fraction_below_050",
        "longest_low_run",
        "provenance_exact_count",
        "provenance_mismatch_count",
        "zero_duration_clip_count",
        "title_similarity",
        "elapsed_seconds",
    ]
    with (output / "summary.csv").open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=scalar_fields + ["auto_reasons", "warnings", "structural_errors"])
        writer.writeheader()
        for row in rows:
            flattened = {field: row.get(field) for field in scalar_fields}
            flattened["auto_reasons"] = "; ".join(row.get("auto_reasons", []))
            flattened["warnings"] = "; ".join(row.get("warnings", []))
            flattened["structural_errors"] = "; ".join(row.get("structural_errors", []))
            writer.writerow(flattened)
    atomic_json(output / "summary.json", rows)

    counts = {severity: sum(row["auto_severity"] == severity for row in rows) for severity in ("definite_failure", "needs_review", "pass")}
    lines = [
        "# Storyteller Readaloud Alignment Audit",
        "",
        f"Audited **{len(rows)}** aligned EPUB artifacts: **{counts['definite_failure']} definite failures**, "
        f"**{counts['needs_review']} requiring review**, and **{counts['pass']} automatic passes**.",
        "",
        "The automatic labels combine EPUB Media Overlay integrity, marked-text and audio coverage, Storyteller's direct-match report, and exact-clip transcript similarity. Isolated short headings and omitted front/back matter require contextual review.",
        "",
        "## Ranked results",
        "",
        "| Severity | Book | Overlay | Raw match | Audio | Semantic | <50% clips | Longest run | Reason |",
        "|---|---|---:|---:|---:|---:|---:|---:|---|",
    ]
    for row in rows:
        lines.append(
            "| {severity} | {book} | {overlay} | {raw} | {audio} | {semantic} | {low} | {run} | {reason} |".format(
                severity=markdown_escape(row["auto_severity"]),
                book=markdown_escape(row["book"]),
                overlay=pct(row.get("overlay_coverage")),
                raw=pct(row.get("raw_match_coverage")),
                audio=pct(row.get("audio_coverage")),
                semantic=pct(row.get("weighted_similarity")),
                low=pct(row.get("fraction_below_050")),
                run=row.get("longest_low_run", 0),
                reason=markdown_escape("; ".join(row.get("auto_reasons", [])) or "—"),
            )
        )

    lines.extend(["", "## Evidence for flagged titles", ""])
    for row in rows:
        if row["auto_severity"] == "pass":
            continue
        lines.extend(
            [
                f"### {row['book']}",
                "",
                f"- Automatic result: `{row['auto_severity']}` — {'; '.join(row.get('auto_reasons', [])) or 'no reason recorded'}",
                f"- EPUB / audiobook title similarity: {pct(row.get('title_similarity'))}",
                f"- Opening announcement: {row.get('first_announcement') or 'unavailable'}",
            ]
        )
        if row.get("structural_errors"):
            lines.append("- Structural errors: " + "; ".join(row["structural_errors"][:8]))
        for item in row.get("evidence", [])[:5]:
            lines.append(
                f"- `{item['chapter']}#{item['fragment']}` at {item['audio']} {item['clip_begin']:.2f}–{item['clip_end']:.2f}s, similarity {item['similarity']:.1%}: "
                f"text “{item['reference_excerpt']}”; transcript “{item['transcript_excerpt']}”"
            )
        lines.append("")

    (output / "report.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    fresh = [
        {
            "book": row["book"],
            "reason": row.get("auto_reasons", []),
            "provenance_mismatch_count": row.get("provenance_mismatch_count", 0),
            "recommended_samples": 3,
        }
        for row in rows
        if row["auto_severity"] != "pass" and (
            row.get("provenance_mismatch_count", 0)
            or row.get("weighted_similarity") is None
            or 0.60 <= (row.get("weighted_similarity") or 0.0) < 0.85
        )
    ]
    atomic_json(output / "needs_fresh_asr.json", fresh)


def discover(copies: Path, source: Path, selected: str | None) -> list[tuple[str, Path, Path]]:
    books = []
    for epub in copies.glob("*/aligned/*.epub"):
        book = epub.parent.parent.name
        if selected and selected.casefold() not in book.casefold():
            continue
        books.append((book, source / book, epub))
    return sorted(books)


def main() -> int:
    global FFPROBE_EXECUTABLE
    parser = argparse.ArgumentParser(
        description="Audit copied Storyteller ReadAloud EPUBs without modifying the asset tree."
    )
    parser.add_argument(
        "--assets-root", "--source", dest="source", type=Path, required=True,
        help="Storyteller assets root containing one directory per book",
    )
    parser.add_argument(
        "--readaloud-root", "--copies", dest="copies", type=Path, required=True,
        help="read-only copy root containing <book>/aligned/*.epub",
    )
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument(
        "--ffprobe", default=FFPROBE_EXECUTABLE,
        help="ffprobe executable used for source and sidecar duration/codec checks",
    )
    parser.add_argument("--book", help="case-insensitive book-folder substring")
    parser.add_argument("--force", action="store_true", help="replace existing per-book checkpoints")
    args = parser.parse_args()
    FFPROBE_EXECUTABLE = args.ffprobe
    args.output.mkdir(parents=True, exist_ok=True)
    state_dir = args.output / "state"
    state_dir.mkdir(parents=True, exist_ok=True)
    discovered = discover(args.copies, args.source, args.book)
    if not discovered:
        print("no copied EPUBs found", file=sys.stderr)
        return 2

    rows: list[dict[str, Any]] = []
    for index, (book, source_dir, epub) in enumerate(discovered, 1):
        state_name = hashlib.sha256(book.encode("utf-8")).hexdigest()[:16] + ".json"
        state_path = state_dir / state_name
        if state_path.exists() and not args.force:
            result = json.loads(state_path.read_text(encoding="utf-8"))
            if result.get("epub_size") == epub.stat().st_size:
                print(f"[{index}/{len(discovered)}] resume {book}", flush=True)
                rows.append(result)
                continue
        print(f"[{index}/{len(discovered)}] audit {book}", flush=True)
        result = BookAudit(book, source_dir, epub).run()
        atomic_json(state_path, result)
        evidence_path = args.output / "evidence" / (hashlib.sha256(book.encode()).hexdigest()[:12] + ".json")
        atomic_json(evidence_path, {"book": book, "evidence": result.get("evidence", []), "worst_chapters": result.get("worst_chapters", [])})
        rows.append(result)
        print(
            f"  -> {result['auto_severity']} overlay={pct(result.get('overlay_coverage'))} "
            f"raw={pct(result.get('raw_match_coverage'))} audio={pct(result.get('audio_coverage'))} "
            f"semantic={pct(result.get('weighted_similarity'))} ({result['elapsed_seconds']:.1f}s)",
            flush=True,
        )
    render_outputs(args.output, rows)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

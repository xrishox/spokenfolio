#!/usr/bin/env python3
"""Separate uncovered main prose from likely notes, indexes, and bonus matter."""

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
FRONT_BACK = re.compile(
    r"(?i)\b(copyright|contents|table of contents|title page|dedication|epigraph|"
    r"acknowledg|bibliograph|index|notes|about the author|also by|preview|praise|"
    r"newsletter|endnotes|footnotes|works cited|suggested reading|glossary|colophon|cover)\b"
)


def parse_ids(raw: bytes) -> tuple[dict[str, str], str]:
    try:
        root = ET.fromstring(raw)
        ids = {
            element.get("id"): "".join(element.itertext()).strip()
            for element in root.iter()
            if element.get("id")
        }
        title = next(
            (
                "".join(element.itertext()).strip()
                for element in root.iter()
                if audit.local_name(element.tag) in {"title", "h1", "h2"}
                and "".join(element.itertext()).strip()
            ),
            "",
        )
        return ids, title
    except ET.ParseError:
        parser = audit.LenientIDTextParser()
        parser.feed(raw.decode("utf-8", "replace"))
        return parser.values(), ""


def analyze_book(book: str, epub: Path) -> dict:
    with ZipFile(epub) as archive:
        names = set(archive.namelist())
        container = ET.fromstring(archive.read("META-INF/container.xml"))
        rootfile = container.find(".//c:rootfile", audit.NS_CONTAINER)
        if rootfile is None or not rootfile.get("full-path"):
            raise ValueError("container.xml has no rootfile")
        opf_path = rootfile.get("full-path")
        assert opf_path
        opf = ET.fromstring(archive.read(opf_path))
        manifest = {}
        for element in opf.iter():
            if audit.local_name(element.tag) == "item" and element.get("id") and element.get("href"):
                member, _ = audit.resolve_member(opf_path, element.get("href", ""))
                manifest[element.get("id")] = {"member": member}
        spine = [
            manifest[element.get("idref")]["member"]
            for element in opf.iter()
            if audit.local_name(element.tag) == "itemref" and element.get("idref") in manifest
        ]
        references = set()
        for name in names:
            if not name.lower().endswith(".smil"):
                continue
            root = ET.fromstring(archive.read(name))
            for element in root.iter():
                if audit.local_name(element.tag) != "text" or not element.get("src"):
                    continue
                member, fragment = audit.resolve_member(name, element.get("src", ""))
                if fragment:
                    references.add(f"{member}#{fragment}")

        documents = []
        for member in spine:
            if not member.lower().endswith((".xhtml", ".html", ".htm")) or member not in names:
                continue
            ids, title = parse_ids(archive.read(member))
            marked = [(fragment, text) for fragment, text in ids.items() if audit.SENTENCE_ID.search(fragment)]
            if not marked:
                continue
            uncovered = [
                (fragment, text)
                for fragment, text in marked
                if f"{member}#{fragment}" not in references
            ]
            uncovered_text = " ".join(text for _, text in uncovered)
            uncovered_words = audit.tokens(uncovered_text)
            if not uncovered_words:
                continue
            context = f"{member} {title} {audit.excerpt(uncovered_text, 35)}"
            kind = "front_back" if FRONT_BACK.search(context) else "body_or_unknown"
            documents.append(
                {
                    "member": member,
                    "title": title,
                    "marked_sentences": len(marked),
                    "uncovered_sentences": len(uncovered),
                    "uncovered_tokens": len(uncovered_words),
                    "kind": kind,
                    "excerpt": audit.excerpt(uncovered_text, 35),
                }
            )
        documents.sort(key=lambda item: item["uncovered_tokens"], reverse=True)
        return {
            "book": book,
            "epub": str(epub),
            "uncovered_tokens": sum(item["uncovered_tokens"] for item in documents),
            "front_back_tokens": sum(
                item["uncovered_tokens"] for item in documents if item["kind"] == "front_back"
            ),
            "body_or_unknown_tokens": sum(
                item["uncovered_tokens"]
                for item in documents
                if item["kind"] == "body_or_unknown"
            ),
            "documents": documents[:30],
        }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Explain low overlay coverage by classifying uncovered marked documents."
    )
    parser.add_argument("--readaloud-root", type=Path, required=True)
    parser.add_argument("--audit-output", type=Path, required=True)
    parser.add_argument("--output", type=Path, help="default: <audit-output>/omission_analysis.json")
    parser.add_argument("--book", action="append", help="exact book-folder name; repeatable")
    parser.add_argument("--threshold", type=float, default=0.85)
    args = parser.parse_args()

    summary = json.loads((args.audit_output / "summary.json").read_text(encoding="utf-8"))
    if args.book:
        books = args.book
    else:
        books = sorted(
            row["book"]
            for row in summary
            if (row.get("overlay_coverage") or 0.0) < args.threshold
        )
    results = []
    for index, book in enumerate(books, 1):
        candidates = sorted((args.readaloud_root / book / "aligned").glob("*.epub"))
        if not candidates:
            print(f"[{index}/{len(books)}] skip {book}: no copied aligned EPUB", flush=True)
            continue
        print(f"[{index}/{len(books)}] {book}", flush=True)
        results.append(analyze_book(book, candidates[0]))
    output = args.output or args.audit_output / "omission_analysis.json"
    audit.atomic_json(output, results)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Copy Storyteller aligned EPUBs into a disposable, verified workspace."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
from pathlib import Path
from tempfile import NamedTemporaryFile


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(8 * 1024 * 1024):
            value.update(chunk)
    return value.hexdigest()


def atomic_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with NamedTemporaryFile("w", encoding="utf-8", dir=path.parent, delete=False) as handle:
        json.dump(value, handle, indent=2, ensure_ascii=False)
        handle.write("\n")
        temporary = Path(handle.name)
    os.replace(temporary, path)


def discover(assets_root: Path, selected: str | None) -> list[Path]:
    epubs = []
    for path in assets_root.glob("*/aligned/*.epub"):
        book = path.parent.parent.name
        if selected and selected.casefold() not in book.casefold():
            continue
        epubs.append(path)
    return sorted(epubs)


def copy_atomic(source: Path, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_name(f".{destination.name}.{os.getpid()}.copying")
    try:
        shutil.copy2(source, temporary)
        os.replace(temporary, destination)
    finally:
        temporary.unlink(missing_ok=True)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Copy and SHA-256 verify every <book>/aligned/*.epub artifact."
    )
    parser.add_argument("--assets-root", type=Path, required=True)
    parser.add_argument("--destination", type=Path, required=True)
    parser.add_argument(
        "--manifest",
        type=Path,
        help="JSON manifest path (default: <destination>/../copy-manifest.json)",
    )
    parser.add_argument("--book", help="case-insensitive book-folder substring")
    parser.add_argument("--force", action="store_true", help="replace destination files")
    args = parser.parse_args()

    sources = discover(args.assets_root, args.book)
    if not sources:
        parser.error("no <book>/aligned/*.epub files found")
    manifest = args.manifest or args.destination.parent / "copy-manifest.json"

    rows = []
    failures = 0
    for index, source in enumerate(sources, 1):
        relative = source.relative_to(args.assets_root)
        destination = args.destination / relative
        print(f"[{index}/{len(sources)}] {relative}", flush=True)
        source_hash = digest(source)
        copied = False
        if args.force or not destination.exists():
            copy_atomic(source, destination)
            copied = True
        destination_hash = digest(destination)
        if destination_hash != source_hash and not copied:
            copy_atomic(source, destination)
            copied = True
            destination_hash = digest(destination)
        verified = source_hash == destination_hash
        failures += not verified
        rows.append(
            {
                "relative_path": str(relative),
                "source_path": str(source),
                "copied_path": str(destination),
                "source_size": source.stat().st_size,
                "copied_size": destination.stat().st_size,
                "source_sha256": source_hash,
                "copied_sha256": destination_hash,
                "copied_this_run": copied,
                "verified": verified,
            }
        )

    atomic_json(manifest, rows)
    checksum_path = manifest.with_suffix(".sha256")
    checksum_path.write_text(
        "".join(f"{row['copied_sha256']}  {row['relative_path']}\n" for row in rows),
        encoding="utf-8",
    )
    print(
        f"verified={len(rows) - failures} failed={failures} "
        f"bytes={sum(row['copied_size'] for row in rows)} manifest={manifest}"
    )
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())

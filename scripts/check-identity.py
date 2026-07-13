#!/usr/bin/env python3
"""Guard the product identity and retired menu-bar architecture."""

from __future__ import annotations

import pathlib
import plistlib
import sys


ROOT = pathlib.Path(__file__).resolve().parents[1]
EXPECTED_PLIST = {
    "CFBundleDisplayName": "SpokenFolio",
    "CFBundleExecutable": "spokenfolio",
    "CFBundleIdentifier": "com.xrishox.spokenfolio",
    "CFBundleName": "SpokenFolio",
}
LEGACY_ALLOWLIST = {
    pathlib.Path("Sources/SpokenFolioApp/Application/AppIdentity.swift"),
    pathlib.Path("Tests/SpokenFolioAppTests/IdentityMigrationTests.swift"),
    pathlib.Path("docs/OPERATIONS.md"),
    pathlib.Path("scripts/check-identity.py"),
    pathlib.Path("scripts/install.sh"),
}
LEGACY_TERMS = (
    "com.xrishox.macos-tts-server",
    "siri-tts-server",
    "Siri TTS Server",
    "Siri TTS Studio",
)
RETIRED_TERMS = ("NSStatusItem", "NSStatusBar", "LSUIElement", ".accessory")


def fail(message: str) -> None:
    print(f"identity check: {message}", file=sys.stderr)
    global FAILED
    FAILED = True


FAILED = False
with (ROOT / "Resources/Info.plist").open("rb") as handle:
    plist = plistlib.load(handle)
for key, expected in EXPECTED_PLIST.items():
    if plist.get(key) != expected:
        fail(f"Resources/Info.plist {key} must be {expected!r}")
if "LSUIElement" in plist:
    fail("Resources/Info.plist must not declare LSUIElement")

text_files = [ROOT / "README.md", ROOT / "AGENTS.md", ROOT / "CLAUDE.md"]
for directory, suffixes in (("Sources", {".swift"}), ("Tests", {".swift"}),
                            ("docs", {".md"}), ("scripts", {".sh", ".py"})):
    text_files.extend(
        path for path in (ROOT / directory).rglob("*") if path.suffix in suffixes
    )

for path in text_files:
    relative = path.relative_to(ROOT)
    text = path.read_text(encoding="utf-8")
    if relative not in LEGACY_ALLOWLIST:
        for term in LEGACY_TERMS:
            if term in text:
                fail(f"legacy term {term!r} is not allowed in {relative}")
    if relative.parts[0] == "Sources":
        for term in RETIRED_TERMS:
            if term in text:
                fail(f"retired desktop mechanism {term!r} remains in {relative}")

if FAILED:
    raise SystemExit(1)

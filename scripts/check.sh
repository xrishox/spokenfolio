#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

swift test
bash -n scripts/*.sh
python3 scripts/check-identity.py
cmp -s AGENTS.md CLAUDE.md
git diff --check
git show --check --oneline --no-renames HEAD >/dev/null

python3 - <<'PY'
import pathlib
import re
import sys

root = pathlib.Path.cwd()
failed = False
for document in [root / "README.md", root / "AGENTS.md", *sorted((root / "docs").glob("*.md"))]:
    text = document.read_text(encoding="utf-8")
    for target in re.findall(r"\[[^]]+\]\(([^)]+)\)", text):
        target = target.split("#", 1)[0]
        if not target or "://" in target or target.startswith("mailto:"):
            continue
        path = (document.parent / target).resolve()
        if not path.exists():
            print(f"broken Markdown link: {document.relative_to(root)} -> {target}", file=sys.stderr)
            failed = True
if failed:
    raise SystemExit(1)
PY

if [[ "${CHECK_BUNDLE:-0}" == "1" ]]; then
    CODE_SIGN_IDENTITY=- ./scripts/build-app.sh
    codesign --verify --deep --strict "dist/SpokenFolio.app"
fi

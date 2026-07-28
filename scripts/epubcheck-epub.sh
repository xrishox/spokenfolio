#!/bin/bash
# Official EPUB3 conformance check via W3C epubcheck.
#
# Usage: scripts/epubcheck-epub.sh <file.epub> [more.epub ...]
#
# Requires Java plus the epubcheck jar. Point EPUBCHECK_JAR at the jar, or
# install epubcheck so the `epubcheck` command is on PATH (brew install
# epubcheck). Fails on any FATAL or ERROR; warnings are reported but pass.
#
# This is the spec-conformance complement to `spokenfolio readaloud verify`:
# our verifier proves alignment semantics (coverage, timing, identity, audio)
# and strict XML well-formedness, while epubcheck proves the whole package
# obeys the EPUB 3 specification the way reading systems expect.
set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "usage: $0 <file.epub> [more.epub ...]" >&2
    exit 64
fi

run_epubcheck() {
    if [[ -n "${EPUBCHECK_JAR:-}" ]]; then
        java -jar "${EPUBCHECK_JAR}" "$@"
    elif command -v epubcheck >/dev/null 2>&1; then
        epubcheck "$@"
    else
        echo "error: epubcheck not found; set EPUBCHECK_JAR or 'brew install epubcheck'" >&2
        exit 69
    fi
}

status=0
for epub in "$@"; do
    echo "== epubcheck: ${epub}"
    if ! run_epubcheck "${epub}"; then
        status=1
    fi
done
exit "${status}"

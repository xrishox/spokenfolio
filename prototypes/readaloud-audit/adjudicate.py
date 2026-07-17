#!/usr/bin/env python3
"""Combine audit stages into conservative final triage with optional overrides."""

from __future__ import annotations

import argparse
import csv
import json
from collections import Counter
from pathlib import Path


FAIL_CATEGORIES = {
    "probable_wrong_work_or_translation",
    "probable_edition_or_abridgment_mismatch",
    "failed_no_overlay",
    "structural_failure",
    "severe_alignment_failure",
    "partial_alignment_failure",
}


def load_rows(path: Path | None) -> dict[str, dict]:
    if path is None or not path.exists():
        return {}
    value = json.loads(path.read_text(encoding="utf-8"))
    return {row["book"]: row for row in value}


def pct(value) -> str:
    return "—" if value is None else f"{float(value):.1%}"


def classify(row: dict, identity: dict, omission: dict, fresh: dict) -> tuple[str, str]:
    hint = identity.get("identity_hint")
    if hint == "probable_wrong_work_or_translation":
        return (
            hint,
            "Whole-book text and transcript have near-zero phrase overlap; inspect opening text, "
            "credits, and edition/translation metadata before replacing either source.",
        )
    if hint == "probable_edition_or_abridgment_mismatch":
        return (
            hint,
            "The transcript is largely contained in the EPUB, but much of the EPUB is absent from "
            "the transcript; this is consistent with another edition or an abridged audiobook.",
        )
    if row.get("structural_errors"):
        return "structural_failure", "; ".join(row["structural_errors"][:3])
    if not row.get("smil_count") or not row.get("embedded_audio_count"):
        return "failed_no_overlay", "No functional SMIL Media Overlay and embedded-audio pair exists."
    if row.get("auto_severity") == "definite_failure":
        return "severe_alignment_failure", "; ".join(row.get("auto_reasons") or ["multiple severe audit signals"])

    fresh_score = fresh.get("weighted_similarity")
    fresh_count = fresh.get("sample_count") or 0
    if fresh_count >= 3 and fresh_score is not None and fresh_score < 0.45:
        return (
            "partial_alignment_failure",
            "Fresh ASR confirmed badly displaced sampled regions. Interpret as whole-book failure "
            "only when samples were distributed across the book.",
        )

    overlay = row.get("overlay_coverage") or 0.0
    raw = row.get("raw_match_coverage")
    semantic = row.get("weighted_similarity")
    front_back = omission.get("front_back_tokens") or 0
    body = omission.get("body_or_unknown_tokens") or 0
    if overlay < 0.85 and (raw or 0.0) >= 0.90 and (semantic or 0.0) >= 0.90:
        if front_back > body:
            return "good_with_omitted_extras", "Low coverage is dominated by likely notes, index, bibliography, or other front/back matter."
        return "needs_omission_review", "Referenced narration aligns, but uncovered text may include main prose."
    if row.get("auto_severity") == "needs_review":
        return "good_with_local_defects", "The main result appears usable, but automated checks found localized timing, coverage, or zero-duration warnings."
    return "pass", "No material mismatch was detected by the available automated evidence."


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Merge automated stages into review-oriented JSON, CSV, and Markdown output."
    )
    parser.add_argument("--audit-output", type=Path, required=True)
    parser.add_argument("--content-identity", type=Path)
    parser.add_argument("--omissions", type=Path)
    parser.add_argument("--fresh-asr", type=Path)
    parser.add_argument(
        "--decisions",
        type=Path,
        help="optional JSON object keyed by book with category, severity, and diagnosis overrides",
    )
    parser.add_argument("--output-prefix", default="final")
    args = parser.parse_args()

    identity = load_rows(args.content_identity)
    omissions = load_rows(args.omissions)
    fresh = load_rows(args.fresh_asr)
    decisions = (
        json.loads(args.decisions.read_text(encoding="utf-8"))
        if args.decisions and args.decisions.exists()
        else {}
    )
    rows = json.loads((args.audit_output / "summary.json").read_text(encoding="utf-8"))
    final = []
    for source in rows:
        row = dict(source)
        book = row["book"]
        category, diagnosis = classify(
            row, identity.get(book, {}), omissions.get(book, {}), fresh.get(book, {})
        )
        severity = "fail" if category in FAIL_CATEGORIES else ("pass" if category == "pass" else "warning")
        override = decisions.get(book, {})
        row["final_category"] = override.get("category", category)
        row["final_severity"] = override.get("severity", severity)
        row["diagnosis"] = override.get("diagnosis", diagnosis)
        row["content_identity_hint"] = identity.get(book, {}).get("identity_hint")
        row["transcript_ngram_coverage"] = identity.get(book, {}).get("transcript_ngram_coverage")
        row["epub_ngram_coverage"] = identity.get(book, {}).get("epub_ngram_coverage")
        row["fresh_asr_similarity"] = fresh.get(book, {}).get("weighted_similarity")
        row["fresh_asr_samples"] = fresh.get(book, {}).get("sample_count")
        row["uncovered_body_tokens"] = omissions.get(book, {}).get("body_or_unknown_tokens")
        row["uncovered_front_back_tokens"] = omissions.get(book, {}).get("front_back_tokens")
        final.append(row)

    order = {"fail": 0, "warning": 1, "pass": 2}
    final.sort(key=lambda row: (order.get(row["final_severity"], 1), row["book"].casefold()))
    json_path = args.audit_output / f"{args.output_prefix}_summary.json"
    csv_path = args.audit_output / f"{args.output_prefix}_summary.csv"
    report_path = args.audit_output / f"{args.output_prefix}_report.md"
    json_path.write_text(json.dumps(final, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    fields = [
        "final_severity", "final_category", "book", "overlay_coverage",
        "raw_match_coverage", "weighted_similarity", "transcript_ngram_coverage",
        "epub_ngram_coverage", "fresh_asr_similarity", "fresh_asr_samples",
        "uncovered_body_tokens", "uncovered_front_back_tokens", "diagnosis", "copied_epub",
    ]
    with csv_path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(final)

    counts = Counter(row["final_severity"] for row in final)
    lines = [
        "# ReadAloud audit triage",
        "",
        f"Audited **{len(final)}** books: **{counts['fail']} fail**, **{counts['warning']} warning**, **{counts['pass']} pass**.",
        "",
        "> These are conservative triage labels, not proof of edition identity. Review evidence before deleting or replacing source material.",
        "",
        "| Status | Book | Category | Overlay | Direct | Semantic | Global transcript | Fresh ASR | Diagnosis |",
        "|---|---|---|---:|---:|---:|---:|---:|---|",
    ]
    for row in final:
        lines.append(
            f"| {row['final_severity']} | {row['book'].replace('|', chr(92) + '|')} | "
            f"{row['final_category']} | {pct(row.get('overlay_coverage'))} | "
            f"{pct(row.get('raw_match_coverage'))} | {pct(row.get('weighted_similarity'))} | "
            f"{pct(row.get('transcript_ngram_coverage'))} | {pct(row.get('fresh_asr_similarity'))} | "
            f"{row['diagnosis'].replace('|', chr(92) + '|')} |"
        )
    report_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(json.dumps({"books": len(final), "severity": counts}, default=dict, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

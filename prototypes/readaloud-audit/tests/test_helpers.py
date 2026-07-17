from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent


def load(name: str, filename: str):
    path = ROOT / filename
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


audit = load("readaloud_audit_test", "audit_readalouds.py")
identity = load("readaloud_identity_test", "check_content_identity.py")


class ClockTests(unittest.TestCase):
    def test_supported_clock_forms(self):
        self.assertEqual(audit.parse_clock("1500ms"), 1.5)
        self.assertEqual(audit.parse_clock("1.5s"), 1.5)
        self.assertEqual(audit.parse_clock("1:02.5"), 62.5)
        self.assertEqual(audit.parse_clock("1:02:03"), 3723.0)


class ArchiveReferenceTests(unittest.TestCase):
    def test_resolves_relative_member_and_fragment(self):
        self.assertEqual(
            audit.resolve_member("EPUB/overlays/chapter.smil", "../text/chapter.xhtml#sentence-1"),
            ("EPUB/text/chapter.xhtml", "sentence-1"),
        )

    def test_rejects_archive_escape(self):
        with self.assertRaises(ValueError):
            audit.resolve_member("chapter.smil", "../../outside.mp4")


class SimilarityTests(unittest.TestCase):
    def test_normalization_handles_case_and_curly_apostrophe(self):
        self.assertEqual(audit.tokens("Don’t STOP"), ["don't", "stop"])

    def test_identical_tokens_have_perfect_score(self):
        precision, recall, f1, matched = audit.score_tokens(
            ["the", "same", "book"], ["the", "same", "book"]
        )
        self.assertEqual((precision, recall, f1, matched), (1.0, 1.0, 1.0, 3))

    def test_interval_union_does_not_double_count_overlap(self):
        self.assertEqual(audit.union_duration([(0, 2), (1, 3), (5, 6)]), 4.0)


class IdentityHintTests(unittest.TestCase):
    def test_near_zero_overlap_flags_wrong_work_or_translation(self):
        self.assertEqual(
            identity.identity_hint(0.001, 0.003),
            "probable_wrong_work_or_translation",
        )

    def test_asymmetric_overlap_flags_edition_or_abridgment(self):
        self.assertEqual(
            identity.identity_hint(0.90, 0.45),
            "probable_edition_or_abridgment_mismatch",
        )

    def test_high_bidirectional_overlap_supports_same_work(self):
        self.assertEqual(identity.identity_hint(0.85, 0.80), "same_work_likely")


if __name__ == "__main__":
    unittest.main()

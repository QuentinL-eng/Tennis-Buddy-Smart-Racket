"""Regression checks: python -m unittest discover -s ml -p test_training.py"""
from pathlib import Path
import tempfile
import unittest

import numpy as np

from features import extract, extract_window
from train import export_header, forward_q
from train_combined import fit_linear, metrics, split_indices, verify_export


class TrainingChecks(unittest.TestCase):
    def test_split_is_reproducible_disjoint_and_exhaustive(self):
        sessions = np.array(["old"] * 97 + ["new"] * 177)
        sweet = np.array([1] * 16 + [0] * 81 + [1] * 92 + [0] * 85)
        split = split_indices(sessions, sweet)
        again = split_indices(sessions, sweet)
        joined = np.concatenate(list(split.values()))
        self.assertEqual(len(joined), 274)
        self.assertEqual(len(set(joined)), 274)
        for key, ids in split.items():
            np.testing.assert_array_equal(ids, again[key])
            self.assertEqual(set(sessions[ids]), {"old", "new"})
            self.assertEqual(set(sweet[ids]), {0, 1})

    def test_majority_prediction_is_not_a_good_balanced_classifier(self):
        result = metrics(np.array([[-1, .5]] * 10), np.array([1] * 4 + [8] * 6))
        self.assertEqual(result["accuracy"], .6)
        self.assertEqual(result["balanced_accuracy"], .5)
        self.assertEqual(result["sweet_recall"], 0)

    def test_silent_decay_is_finite_and_invalid_window_fails(self):
        self.assertTrue(np.isfinite(extract_window(np.zeros(2048))).all())
        with self.assertRaises(ValueError):
            extract_window(np.zeros(513))

    def test_normal_extractor_still_rejects_long_clips(self):
        with self.assertRaises(AssertionError):
            extract(np.zeros(2048))

    def test_signed_relu_export_matches_linear_output(self):
        rng = np.random.default_rng(1)
        x = rng.normal(size=(40, 12)).astype(np.float32)
        distances = np.where(x[:, 0] > 0, 2, 8).astype(np.float32)
        ids = np.arange(40)
        q, mean, std = fit_linear(x, distances, ids, 1)
        predictions = forward_q(q, (x - mean) / std)
        self.assertGreater(np.mean((predictions[:, 0] > 0) == (distances <= 4)), .9)
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "model.h"
            export_header(q, mean, std, out, "test")
            text = out.read_text()
            self.assertIn("#define SS_H1 24", text)
            self.assertIn("0.0f", text)
            self.assertNotIn(" 0f", text)
            self.assertLess(verify_export(out, (q, mean, std), x), .005)


if __name__ == "__main__":
    unittest.main()

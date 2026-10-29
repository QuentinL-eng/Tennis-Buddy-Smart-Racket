import pickle
import unittest

import numpy as np

from classical_models import BoostedTrees, Forest, KernelRidge, Neighbors, RegressionTree, Standardized
from compare_models import audio_features
from predict_audio import feature_row


class ClassicalModelTests(unittest.TestCase):
    def test_tree_finds_known_boundary(self):
        x = np.arange(10).reshape(-1, 1)
        y = np.array([0] * 5 + [1] * 5)
        tree = RegressionTree(max_depth=2, min_leaf=1, max_features=1).fit(x, y)
        np.testing.assert_array_equal(tree.predict(x), y)

    def test_tree_handles_constant_features(self):
        tree = RegressionTree().fit(np.ones((20, 4)), np.arange(20))
        np.testing.assert_allclose(tree.predict(np.ones((3, 4))), 9.5)

    def test_classifiers_fit_known_signal_and_round_trip(self):
        rng = np.random.default_rng(4)
        x = rng.normal(size=(100, 4))
        y = (x[:, 0] > 0).astype(int)
        for model in [Forest(trees=16, classifier=True), BoostedTrees(classifier=True),
                      Standardized(KernelRidge(alpha=.1, classifier=True)), Standardized(Neighbors(k=3, classifier=True))]:
            model.fit(x, y)
            p = model.predict(x)
            self.assertGreater(np.mean(p == y), .85)
            np.testing.assert_array_equal(p, pickle.loads(pickle.dumps(model)).predict(x))

    def test_audio_features_finite_and_expected_dimension(self):
        for size in (512, 2048):
            for clip in (np.zeros(size), np.full(size, 32767), np.arange(size)):
                spectral, full = audio_features(clip)
                self.assertEqual(spectral.shape, (122,))
                self.assertEqual(full.shape, (156,))
                self.assertTrue(np.isfinite(full).all())

    def test_linear_kernel_can_export_direct_coefficients(self):
        rng = np.random.default_rng(3)
        x = rng.normal(size=(50, 4))
        y = 2*x[:, 0]-x[:, 1]+4
        model = Standardized(KernelRidge(alpha=.1, linear=True)).fit(x, y)
        inner = model.model
        normalized_coeff = inner.x.T @ inner.weights / inner.x.shape[1]
        coeff = normalized_coeff / model.std
        intercept = inner.bias - model.mean @ coeff
        np.testing.assert_allclose(x @ coeff + intercept, model.predict(x), atol=1e-10)

    def test_decay_model_rejects_short_legacy_clip(self):
        with self.assertRaises(ValueError):
            feature_row({"sample_count": 2048}, np.zeros(512, dtype=np.int16), "spectrum")


if __name__ == "__main__":
    unittest.main()

import pickle
import unittest
import numpy as np
from research_methods import (ResearchRegressor, grouped_folds, feature_bank,
                              target, distance_prediction)
from classical_models import KernelRidge, Standardized


class ResearchTests(unittest.TestCase):
    def test_groups_never_cross_train_test(self):
        groups=np.repeat(np.arange(20).astype(str),8)
        labels=np.arange(160)%2
        folds=grouped_folds(groups,labels,5,7)
        held=[]
        for tr,te in folds:
            self.assertFalse(set(groups[tr])&set(groups[te]))
            held.extend(te)
        self.assertEqual(sorted(held),list(range(160)))

    def test_ridge_matches_previous_kernel_implementation(self):
        rng=np.random.default_rng(4);x=rng.normal(size=(50,12));y=rng.uniform(0,12,50)
        previous=Standardized(KernelRidge(alpha=1,linear=True)).fit(x,y)
        model=ResearchRegressor().fit(x,y)
        np.testing.assert_allclose(model.predict(x)[:,0],previous.predict(x),atol=1e-9)

    def test_feature_extraction_finite(self):
        for size in (512,2048):
            bank=feature_bank([np.zeros(size),np.full(size,32767)])
            for x in bank.values():self.assertTrue(np.isfinite(x).all())

    def test_dimension_reduction_and_serialization(self):
        rng=np.random.default_rng(8);x=rng.normal(size=(80,12));y=2*x[:,0]-x[:,1]+4
        for method in ('pls','pcr','ridge','huber','rbf'):
            model=ResearchRegressor(method=method,components=12,strength=.001).fit(x,y)
            pred=model.predict(x)
            self.assertTrue(np.isfinite(pred).all())
            np.testing.assert_allclose(pred,pickle.loads(pickle.dumps(model)).predict(x))
            self.assertLess(np.mean(np.abs(pred[:,0]-y)),.2)

    def test_pls_constant_inputs(self):
        model=ResearchRegressor('pls').fit(np.ones((12,4)),np.ones(12)*3)
        np.testing.assert_allclose(model.predict(np.ones((2,4))),3)

    def test_coordinate_targets_have_correct_radius(self):
        xy=np.array([[-3.,4.],[0.,-2.]])
        d=np.linalg.norm(xy,axis=1)
        for kind in ('signed_xy','abs_xy','radius_squared','radius'):
            encoded=target(d,xy,kind)
            if encoded.ndim==1:encoded=encoded[:,None]
            np.testing.assert_allclose(distance_prediction(encoded,kind),d)


if __name__=='__main__':unittest.main()

import pickle
import unittest
import numpy as np
from multitask_audio import MultiTaskAudio,region_labels
from train_scattering_multitask import scattering_features


class MultiTaskTests(unittest.TestCase):
    def test_joint_gradient_finite_difference(self):
        rng=np.random.default_rng(5)
        z=rng.normal(size=(6,3));t=rng.uniform(size=(6,3));r=np.array([0,1,2,0,1,2]);weights=np.array([.8,1.,1.2])
        p=[rng.normal(size=(3,4))*.1,rng.normal(size=4)*.1,rng.normal(size=(4,6))*.1,rng.normal(size=6)*.1]
        _,grad=MultiTaskAudio.objective(p,z,t,r,weights,.03)
        for j in range(4):
            for index in [tuple(0 for _ in p[j].shape),tuple(n-1 for n in p[j].shape)]:
                old=p[j][index];p[j][index]=old+1e-6;a=MultiTaskAudio.objective(p,z,t,r,weights,.03)[0]
                p[j][index]=old-1e-6;b=MultiTaskAudio.objective(p,z,t,r,weights,.03)[0];p[j][index]=old
                self.assertAlmostEqual((a-b)/2e-6,grad[j][index],places=7)

    def test_physical_region_boundaries(self):
        np.testing.assert_array_equal(region_labels(np.array([0,4,4.01,8,8.01])),[0,0,1,1,2])

    def test_fitting_and_pickle_roundtrip(self):
        rng=np.random.default_rng(2);x=rng.normal(size=(80,6));d=5+3*np.tanh(x[:,0]);xy=np.column_stack([d*.8,d*.6])
        model=MultiTaskAudio(epochs=400,decay=.001).fit(x,d,xy)
        result=model.predict(x)
        self.assertLess(model.loss_history[-1],model.loss_history[0])
        self.assertLess(np.mean(np.abs(result['distance']-d)),.5)
        self.assertTrue(np.isfinite(result['abs_xy']).all())
        np.testing.assert_allclose(result['region_probability'].sum(1),1)
        restored=pickle.loads(pickle.dumps(model))
        np.testing.assert_allclose(result['distance'],restored.predict(x)['distance'])

    def test_constant_input_training_is_finite(self):
        x=np.ones((12,4));d=np.ones(12)*3;xy=np.column_stack([d,np.zeros(12)])
        model=MultiTaskAudio(epochs=10).fit(x,d,xy)
        self.assertTrue(np.isfinite(model.predict(x)['distance']).all())

    def test_official_scattering_has_second_order_paths(self):
        rng=np.random.default_rng(4);x=rng.normal(size=512)*100
        f,meta=scattering_features([x,2*x,np.zeros(512)])
        self.assertEqual(meta['package'],'kymatio')
        self.assertGreater(meta['order2_paths'],0)
        self.assertTrue(np.isfinite(f).all())
        np.testing.assert_allclose(f[0],f[1],atol=1e-6)


if __name__=='__main__':unittest.main()

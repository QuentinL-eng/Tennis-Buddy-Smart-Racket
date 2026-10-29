"""Fixed-configuration epsilon-SVR checks; SciPy QP solver, no extra packages."""
import csv
import json
from pathlib import Path
import numpy as np
from scipy.optimize import minimize
from research_methods import grouped_folds, mfcc_features, score, SEED

ROOT=Path(__file__).resolve().parents[1]


class EpsilonSVR:
    def __init__(self,c=10,epsilon=.5):self.c,self.epsilon=c,epsilon

    def kernel(self,a,b):
        distance=np.maximum(np.sum(a*a,1)[:,None]+np.sum(b*b,1)[None,:]-2*a@b.T,0)
        return np.exp(-distance/a.shape[1])

    def fit(self,x,y):
        self.mean,self.std=x.mean(0),x.std(0)+1e-6
        self.x=(x-self.mean)/self.std;n=len(y);kernel=self.kernel(self.x,self.x)
        def objective(v):
            z=v[:n]-v[n:];kz=kernel@z
            return .5*z@kz+self.epsilon*np.sum(v)-y@z
        def gradient(v):
            z=v[:n]-v[n:];g=kernel@z-y
            return np.r_[g+self.epsilon,-g+self.epsilon]
        constraint=np.r_[np.ones(n),-np.ones(n)]
        result=minimize(objective,np.zeros(2*n),jac=gradient,method='SLSQP',
            bounds=[(0,self.c)]*(2*n),constraints=[{'type':'eq','fun':lambda v:constraint@v,'jac':lambda v:constraint}],
            options={'maxiter':250,'ftol':1e-7})
        if not result.success:raise RuntimeError(f'SVR solver failed: {result.message}')
        self.coef=result.x[:n]-result.x[n:]
        residual=y-kernel@self.coef
        free=(np.abs(self.coef)>1e-5)&(np.abs(self.coef)<self.c-1e-5)
        self.bias=float(np.mean(residual[free]-self.epsilon*np.sign(self.coef[free]))) if np.any(free) else float(np.median(np.r_[residual-self.epsilon,residual+self.epsilon]))
        self.constraint_error=float(abs(self.coef.sum()))
        return self

    def predict(self,x):return np.maximum(0,self.kernel((x-self.mean)/self.std,self.x)@self.coef+self.bias)


def main():
    run=ROOT/'ml/runs/20261028-reviewed-combined';out=ROOT/'ml/runs/20261028-research'
    with (run/'manifest.csv').open(newline='') as fh:rows=list(csv.DictReader(fh))
    dist=np.array([float(r['dist_cm']) for r in rows])
    groups=np.array([r['source_session']+':block'+str((int(Path(r['source_file']).stem.split('-')[-1])-1)//8).zfill(3) for r in rows])
    current=np.load(ROOT/'ml/runs/20261028-classical-ml/features.npz')['spectrum_envelope']
    mfcc=np.stack([mfcc_features(np.fromfile(run/'dataset'/r['file'],dtype='<i2')[:512]) for r in rows])
    folds=grouped_folds(groups,dist<=4,5,SEED);report=[]
    for name,x in [('current156',current),('mfcc_time',mfcc)]:
        for c in (1,10):
            pred=np.zeros(len(dist));constraints=[]
            for k,(tr,te) in enumerate(folds):
                model=EpsilonSVR(c=c).fit(x[tr],dist[tr]);pred[te]=model.predict(x[te]);constraints.append(model.constraint_error)
                print(f'SVR {name} C={c}, grouped fold {k+1}/5 complete',flush=True)
            report.append({'features':name,'C':c,'epsilon_cm':.5,'max_dual_constraint_error':max(constraints),**score(dist,pred)})
            np.save(out/f'svr_{name}_C{c}_predictions.npy',pred)
            (out/'svr_results.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2),flush=True)


if __name__=='__main__':main()

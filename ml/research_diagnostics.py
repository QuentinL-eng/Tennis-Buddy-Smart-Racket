"""Reproduce preprocessing and exploratory target-shuffling diagnostics.

Run after research_methods.py. Does not modify source sessions or firmware.
"""
import csv
import json
from pathlib import Path
import pickle
import numpy as np
from compare_models import audio_features
from research_methods import ResearchRegressor,grouped_folds,SEED,score

ROOT=Path(__file__).resolve().parents[1]


def main():
    base=ROOT/'ml/runs/20261028-reviewed-combined';out=ROOT/'ml/runs/20261028-research'
    with (base/'manifest.csv').open(newline='') as fh:rows=list(csv.DictReader(fh))
    clips=[np.fromfile(base/'dataset'/r['file'],dtype='<i2')[:512] for r in rows]
    d=np.array([float(r['dist_cm']) for r in rows]);sessions=np.array([r['source_session'] for r in rows])
    groups=np.array([r['source_session']+':block'+str((int(Path(r['source_file']).stem.split('-')[-1])-1)//8).zfill(3) for r in rows])
    folds=grouped_folds(groups,d<=4,5,SEED)
    x=np.stack([audio_features(c)[1] for c in clips]);invariant=np.delete(x,[120,121],axis=1)
    rng=np.random.default_rng(SEED);aug=[]
    for c in clips:
        variants=[]
        for offset in [-8,0,8]:
            shifted=np.zeros(512,dtype=float)
            if offset<0:shifted[:offset]=c[-offset:]
            elif offset>0:shifted[offset:]=c[:-offset]
            else:shifted=c.astype(float)
            variants.append(audio_features(shifted)[1])
        noise=c.astype(float)+rng.normal(size=512)*max(float(np.std(c)),1)*.02
        variants.append(audio_features(np.clip(np.round(noise),-32768,32767))[1]);aug.append(variants)
    aug=np.array(aug);report=[]
    for name,feature,augment in [('fixed_ridge',x,False),('remove_absolute_level_and_clipping',invariant,False),('jitter_noise_augmentation',x,True)]:
        pred=np.zeros(len(d))
        for tr,te in folds:
            train_x=aug[tr].reshape(-1,x.shape[1]) if augment else feature[tr]
            train_y=np.repeat(d[tr],aug.shape[1]) if augment else d[tr]
            model=ResearchRegressor().fit(train_x,train_y);pred[te]=np.maximum(model.predict(feature[te])[:,0],0)
        report.append({'method':name,**score(d,pred)})
        np.save(out/(name+'_predictions.npy'),pred)
    all_model=ResearchRegressor().fit(x,d)
    with (out/'ridge_refit_all274.pkl').open('wb') as fh:
        pickle.dump({'features':'current156','model':all_model,'training_clips':274,'research_only':True,
                     'accuracy_note':'No independent test set remains; see grouped OOF estimates.'},fh)
    pred=np.load(out/'combined_oof.npz')['fixed_current_ridge'];certain=np.abs(pred-4)>1
    report.append({'method':'fixed_ridge_with_1cm_uncertainty_margin','coverage':float(certain.mean()),
        'count_reported':int(certain.sum()),'count_uncertain':int((~certain).sum()),**score(d[certain],pred[certain])})
    (out/'preprocessing_results.json').write_text(json.dumps(report,indent=2)+'\n')
    errors=[]
    for iteration in range(99):
        perm=d.copy()
        for session in sorted(set(sessions)):
            ids=np.flatnonzero(sessions==session);perm[ids]=rng.permutation(perm[ids])
        prediction=np.zeros(len(d))
        for tr,te in grouped_folds(groups,perm<=4,5,SEED):
            model=ResearchRegressor().fit(x[tr],perm[tr]);prediction[te]=np.maximum(model.predict(x[te])[:,0],0)
        errors.append(float(np.mean(np.abs(perm-prediction))))
    actual=float(np.mean(np.abs(d-pred)))
    result={'method':'fixed ridge, grouped OOF, within-session target shuffling','permutations':99,
            'actual_mae_cm':actual,'permuted_mae_cm_mean':float(np.mean(errors)),
            'permuted_mae_cm_range':[min(errors),max(errors)],
            'empirical_p_lower_mae':(1+sum(v<=actual for v in errors))/100,
            'note':'Exploratory association check on reviewed development data, not an independent field accuracy test.'}
    (out/'permutation_diagnostic.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result,indent=2))


if __name__=='__main__':main()

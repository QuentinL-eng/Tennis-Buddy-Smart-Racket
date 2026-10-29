"""Descriptive paired-block resampling; no independent field-accuracy claim."""
import json
from pathlib import Path
import numpy as np

ROOT=Path(__file__).resolve().parents[1]


def main():
    p=ROOT/'ml/runs/20261028-scattering-multitask'
    o=np.load(p/'combined_oof.npz');d=o['distances'];groups=o['groups'];names=np.array(sorted(set(groups)));y=d<=4
    baseline=o['fixed_ridge_sweet'];candidate=o['mae_selected_sweet']
    bp=o['fixed_ridge_distance'];cp=o['mae_selected_distance']
    rng=np.random.default_rng(3301);delta=[];mae_delta=[]
    for _ in range(5000):
        sample=rng.choice(names,len(names),replace=True)
        ids=np.concatenate([np.flatnonzero(groups==g) for g in sample])
        delta.append(float(np.mean(candidate[ids]==y[ids])-np.mean(baseline[ids]==y[ids])))
        mae_delta.append(float(np.mean(np.abs(cp[ids]-d[ids]))-np.mean(np.abs(bp[ids]-d[ids]))))
    r=json.loads((p/'combined_results.json').read_text());folds=[]
    for fold in r['folds']:
        ids=np.flatnonzero(np.isin(groups,fold['held_out_groups']))
        a=float(np.mean(candidate[ids]==y[ids])-np.mean(baseline[ids]==y[ids]))
        e=float(np.mean(np.abs(cp[ids]-d[ids]))-np.mean(np.abs(bp[ids]-d[ids])))
        folds.append({'fold':fold['fold'],'n':len(ids),'accuracy_delta':a,'mae_delta_cm':e})
    summary={'method':'paired chronological-group bootstrap, descriptive only; not an independent or calibrated field confidence interval',
        'resamples':5000,'accuracy_delta':float(np.mean(candidate==y)-np.mean(baseline==y)),
        'accuracy_delta_percentile_2_5_97_5':np.percentile(delta,[2.5,97.5]).tolist(),
        'mae_delta_cm':float(np.mean(np.abs(cp-d))-np.mean(np.abs(bp-d))),
        'mae_delta_percentile_2_5_97_5_cm':np.percentile(mae_delta,[2.5,97.5]).tolist(),
        'gained_correct':int(np.sum((candidate==y)&(baseline!=y))),
        'lost_correct':int(np.sum((candidate!=y)&(baseline==y))),'folds':folds}
    (p/'stability.json').write_text(json.dumps(summary,indent=2)+'\n')
    print(json.dumps(summary,indent=2))


if __name__=='__main__':main()

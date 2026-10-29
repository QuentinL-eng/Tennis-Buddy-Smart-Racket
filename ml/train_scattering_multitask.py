"""Full Kymatio scattering and small multi-task networks: nested grouped CV.

Research only: saves candidates, never changes active firmware or labels.
"""
import argparse
import csv
import hashlib
import json
from pathlib import Path
import pickle
import sys

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'firmware/.pio/research-deps'))
import numpy as np
import kymatio
from kymatio.numpy import Scattering1D
from compare_models import audio_features,classification_metrics
from research_methods import ResearchRegressor,grouped_folds,normalize,SEED
from multitask_audio import MultiTaskAudio


def scattering_features(clips):
    samples=len(clips[0]);j=6 if samples==512 else 8
    transform=Scattering1D(J=j,shape=samples,Q=4,max_order=2)
    metadata=transform.meta();include=metadata['order']>0
    assert np.any(metadata['order']==2),'Second-order coefficients missing'
    x=np.stack([normalize(c) for c in clips])
    s=transform(x)[:,include,:]
    middle=s.shape[-1]//2
    result=np.concatenate([np.log10(s.mean(-1)+1e-8),np.log10(s.std(-1)+1e-8),
            np.log10(s[:,:,:middle].mean(-1)+1e-8),np.log10(s[:,:,middle:].mean(-1)+1e-8)],axis=1)
    if not np.isfinite(result).all():raise ValueError('Scattering features are not finite')
    return result.astype(np.float32),{'package':'kymatio','version':kymatio.__version__,
        'J':j,'Q':4,'max_order':2,'samples':samples,'order1_paths':int(np.sum(metadata['order']==1)),
        'order2_paths':int(np.sum(metadata['order']==2)),'features':result.shape[1]}


def configurations():
    configs=[]
    for feature in ('current','scattering','current_scattering'):
        for method,alpha in [('ridge',.1),('ridge',1),('ridge',10),('pls',1),('rbf',1)]:
            configs.append({'feature':feature,'kind':'classical','method':method,'alpha':alpha})
        for epochs,decay in [(150,.01),(400,.01),(150,.1),(400,.1)]:
            configs.append({'feature':feature,'kind':'multitask','epochs':epochs,'decay':decay})
    return configs


def fit_predict(bank,dist,xy,tr,te,cfg):
    x=bank[cfg['feature']]
    if cfg['kind']=='multitask':
        model=MultiTaskAudio(epochs=cfg['epochs'],decay=cfg['decay']).fit(x[tr],dist[tr],xy[tr])
        result=model.predict(x[te])
        return result['distance'],result['sweet'],model
    model=ResearchRegressor(method=cfg['method'],strength=cfg['alpha'],components=2).fit(x[tr],dist[tr])
    d=np.maximum(model.predict(x[te])[:,0],0)
    return d,d<=4,model


def score(dist,pred,sweet):
    return {'mae_cm':float(np.mean(np.abs(dist-pred))),**classification_metrics(dist<=4,sweet)}


def evaluate(clips,dist,xy,groups,out,name):
    current=np.stack([audio_features(c)[1] for c in clips])
    scatter,settings=scattering_features(clips)
    bank={'current':current,'scattering':scatter,'current_scattering':np.hstack([current,scatter])}
    np.savez(out/(name+'_features.npz'),**bank,distances=dist,xy=xy,groups=groups)
    print(f'{name}: {len(clips)} recordings; official scattering {settings}',flush=True)
    configs=configurations();outer=grouped_folds(groups,dist<=4,5,SEED)
    keys=['mae_selected','classification_selected','fixed_ridge']
    distances={key:np.zeros(len(dist)) for key in keys}
    decisions={key:np.zeros(len(dist),dtype=bool) for key in keys}
    details=[];boards=[]
    # Additional fold-isolated selectors: establish what each family contributes.
    family_keys=['scattering_classical','multitask_current','multitask_scattering']
    for key in family_keys:distances[key]=np.zeros(len(dist));decisions[key]=np.zeros(len(dist),dtype=bool)
    for fold,(tr,te) in enumerate(outer):
        inner=grouped_folds(groups[tr],dist[tr]<=4,3,SEED+fold+1);board=[]
        for cfg in configs:
            d=np.zeros(len(tr));s=np.zeros(len(tr),dtype=bool)
            for it,iv in inner:
                d[iv],s[iv],_=fit_predict(bank,dist,xy,tr[it],tr[iv],cfg)
            # Distance and classification heads are assessed separately, before seeing outer labels.
            board.append({'config':cfg,'region_head':score(dist[tr],d,s),
                          'distance_head':score(dist[tr],d,d<=4)})
        mae=min(board,key=lambda r:r['distance_head']['mae_cm'])
        head_options=[(r,head) for r in board for head in ('region_head','distance_head')]
        classification=max(head_options,key=lambda item:(item[0][item[1]]['balanced_accuracy'],-item[0][item[1]]['mae_cm']))
        selections={'mae_selected':(mae,'distance_head'),'classification_selected':classification}
        for key in family_keys:
            eligible=[(r,h) for r,h in head_options if (
                key=='scattering_classical' and r['config']['kind']=='classical' and r['config']['feature']!='current'
                or key=='multitask_current' and r['config']['kind']=='multitask' and r['config']['feature']=='current'
                or key=='multitask_scattering' and r['config']['kind']=='multitask' and r['config']['feature']!='current')]
            selections[key]=max(eligible,key=lambda item:(item[0][item[1]]['balanced_accuracy'],-item[0][item[1]]['mae_cm']))
        diag={'fold':fold,'train':len(tr),'test':len(te),'held_out_groups':sorted(set(groups[te])),'selections':{}}
        for key,(row,head) in selections.items():
            d,s,_=fit_predict(bank,dist,xy,tr,te,row['config'])
            distances[key][te]=d;decisions[key][te]=s if head=='region_head' else d<=4
            diag['selections'][key]={'config':row['config'],'head':head,'inner':row[head]}
        baseline={'feature':'current','kind':'classical','method':'ridge','alpha':1}
        distances['fixed_ridge'][te],decisions['fixed_ridge'][te],_=fit_predict(bank,dist,xy,tr,te,baseline)
        details.append(diag);boards.append(board)
        (out/(name+'_progress.json')).write_text(json.dumps(details,indent=2)+'\n')
        print(f'{name}: grouped outer fold {fold+1}/5 complete',flush=True)
    result={'recordings':len(dist),'groups':len(set(groups)),'scattering':settings,
        'configurations':len(configs),'metrics':{k:score(dist,distances[k],decisions[k]) for k in distances},
        'folds':details,'inner_results':boards}
    (out/(name+'_results.json')).write_text(json.dumps(result,indent=2)+'\n')
    np.savez(out/(name+'_oof.npz'),distances=dist,groups=groups,
             **{k+'_distance':v for k,v in distances.items()},**{k+'_sweet':v for k,v in decisions.items()})
    # Final candidate fitting uses pooled inner-fold scores; no choice uses outer scores.
    best_index=min(range(len(configs)),key=lambda i:np.mean([b[i]['distance_head']['mae_cm'] for b in boards]))
    cfg=configs[best_index];_,_,model=fit_predict(bank,dist,xy,np.arange(len(dist)),np.arange(len(dist)),cfg)
    with (out/(name+'_candidate.pkl')).open('wb') as fh:
        pickle.dump({'model':model,'config':cfg,'scattering':settings,'recordings':len(dist),'research_only':True},fh)
    print(name,json.dumps(result['metrics'],indent=2),flush=True)
    return result


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--out',type=Path,default=ROOT/'ml/runs/20261028-scattering-multitask')
    args=ap.parse_args();args.out.mkdir(parents=True,exist_ok=False)
    base=ROOT/'ml/runs/20261028-reviewed-combined'
    with (base/'manifest.csv').open(newline='') as fh:rows=list(csv.DictReader(fh))
    clips=[];xy=[];groups=[];positions={}
    for r in rows:
        raw=(base/'dataset'/r['file']).read_bytes();assert hashlib.sha256(raw).hexdigest()==r['sha256']
        clips.append(np.frombuffer(raw,dtype='<i2'))
        session=r['source_session']
        if session not in positions:
            with (base/'source_review'/session/'positions.csv').open(newline='') as fh:
                positions[session]={v['file']:v for v in csv.DictReader(fh)}
        p=positions[session][r['source_file']];xy.append([float(p['x_cm']),float(p['y_cm'])])
        number=int(Path(r['source_file']).stem.split('-')[-1]);groups.append(f'{session}:block{(number-1)//8:03d}')
    dist=np.array([float(r['dist_cm']) for r in rows]);xy=np.array(xy);groups=np.array(groups)
    combined=evaluate([c[:512] for c in clips],dist,xy,groups,args.out,'combined')
    ids=[];tails=[]
    for i,c in enumerate(clips):
        saturated=np.flatnonzero(np.abs(c.astype(np.int32))>=30000)
        start=int(saturated[-1])+1 if len(saturated) else 64
        if len(c)-start>=2048:ids.append(i);tails.append(c[start:start+2048])
    ids=np.array(ids);tail=evaluate(tails,dist[ids],xy[ids],groups[ids],args.out,'tail')
    summary={'combined':combined['metrics'],'tail':tail['metrics'],
        'notes':['Grouped nested cross-validation on development data, not an independent club test.',
        'All PCA/scaling/network fitting and selection occurs inside training folds.',
        'Region-head and distance-head decisions are distinct; head selection occurs in inner folds.',
        'No source recordings, labels, rejected detections, app files or firmware were changed.']}
    (args.out/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')


if __name__=='__main__':main()

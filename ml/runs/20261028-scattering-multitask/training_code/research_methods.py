"""Research-only grouped/nested evaluation. Does not modify labels or firmware.

python ml/research_methods.py --out ml/runs/20261028-research
Requires only existing NumPy/SciPy dependencies.
"""
import argparse
import csv
import hashlib
import json
from pathlib import Path
import pickle

import numpy as np
from scipy.fft import dct

from compare_models import audio_features, classification_metrics

ROOT = Path(__file__).resolve().parents[1]
SEED = 294108


def normalize(clip):
    x = np.asarray(clip, dtype=float)
    x = x - x.mean()
    return x / max(float(np.sqrt(np.mean(x*x))), 1.)


def mfcc_features(clip):
    x = normalize(clip)
    width = 256
    frames = np.lib.stride_tricks.sliding_window_view(x, width)[::64]
    spectrum = np.abs(np.fft.rfft(frames * np.hanning(width), n=512))**2
    # HTK mel spacing; explicit implementation, not claimed identical to librosa defaults.
    mel = lambda f: 2595*np.log10(1+f/700)
    edges = 700*(10**(np.linspace(mel(40), mel(7800), 26)/2595)-1)
    freq = np.fft.rfftfreq(512, 1/16000)
    filters = np.stack([np.maximum(0, np.minimum((freq-a)/(b-a), (c-freq)/(c-b)))
                        for a, b, c in zip(edges, edges[1:], edges[2:])])
    energy = spectrum @ filters.T
    energy /= np.maximum(energy.sum(axis=1, keepdims=True), 1e-20)
    logmel = np.log10(energy+1e-8)
    cep = dct(logmel, axis=1, norm="ortho")[:, 1:14]
    return np.r_[cep.mean(0), cep.std(0), cep[-1]-cep[0], logmel.mean(0)].astype(np.float32)


def wavelet_packet_features(clip):
    x = normalize(clip)
    def packet(segment):
        nodes = [segment]
        for _ in range(4):
            nodes = [v for n in nodes for v in ((n[::2]+n[1::2])/np.sqrt(2), (n[::2]-n[1::2])/np.sqrt(2))]
        energy = np.array([np.mean(v*v) for v in nodes])
        return energy/max(float(energy.sum()), 1e-20)
    # Four one-sample shifts reduce sensitivity of the Haar packet to trigger jitter.
    parts = [np.mean([packet(np.roll(seg, shift)) for shift in range(4)], axis=0)
             for seg in (x, x[:len(x)//2], x[len(x)//2:])]
    return np.log10(np.concatenate(parts)+1e-8).astype(np.float32)


def modal_features(clip):
    x = normalize(clip)
    edges = np.array([0, 60, 120, 200, 300, 500, 800, 1200, 2000, 4000, 8001])
    output = []
    for segment in (x, x[:len(x)//2], x[len(x)//2:]):
        power = np.abs(np.fft.rfft(segment*np.hanning(len(segment))))**2
        freq = np.fft.rfftfreq(len(segment), 1/16000)
        power[0] = 0
        power /= max(float(power.sum()), 1e-20)
        output.extend(np.log10(np.array([power[(freq>=a)&(freq<b)].sum() for a,b in zip(edges,edges[1:])])+1e-8))
    # Relative decay slopes in broad frame/string bands, computed on fixed windows.
    fft = np.fft.rfft(x)
    freq = np.fft.rfftfreq(len(x), 1/16000)
    for lo, hi in ((40, 300), (300, 800), (800, 2000), (2000, 6000)):
        band = np.fft.irfft(fft*((freq>=lo)&(freq<hi)), n=len(x))
        energy = np.array([np.mean(v*v) for v in np.array_split(band, 4)])
        output.extend(np.log10(energy/max(float(energy.sum()),1e-20)+1e-8))
    return np.array(output, dtype=np.float32)


def feature_bank(clips):
    current = np.stack([audio_features(c)[1] for c in clips])
    mfcc = np.stack([mfcc_features(c) for c in clips])
    packet = np.stack([wavelet_packet_features(c) for c in clips])
    modal = np.stack([modal_features(c) for c in clips])
    return {"current156": current, "mfcc_time": mfcc, "wavelet_packet": packet,
            "modal_decay": modal, "mfcc_wavelet_modal": np.hstack([mfcc, packet, modal])}


class ResearchRegressor:
    def __init__(self, method="ridge", strength=1, components=6):
        self.method, self.strength, self.components = method, strength, components

    def fit(self, x, y):
        x = np.asarray(x, dtype=float)
        y = np.asarray(y, dtype=float)
        if y.ndim == 1: y = y[:, None]
        self.mean, self.std = x.mean(0), x.std(0)+1e-6
        z = (x-self.mean)/self.std
        self.bias = y.mean(0)
        centered_y = y-self.bias
        self.projection = np.eye(z.shape[1])
        if self.method == "pcr":
            _, _, vh = np.linalg.svd(z, full_matrices=False)
            self.projection = vh[:min(self.components,len(vh))].T
            z = z @ self.projection
        if self.method == "pls":
            residual_x, residual_y = z.copy(), centered_y.copy()
            weights, loadings, responses = [], [], []
            for _ in range(min(self.components, z.shape[1], len(z)-1)):
                cross = residual_x.T@residual_y
                w = np.linalg.svd(cross, full_matrices=False)[0][:, 0]
                t = residual_x@w
                energy = float(t@t)
                if energy < 1e-12: break
                p, q = residual_x.T@t/energy, residual_y.T@t/energy
                residual_x -= np.outer(t,p)
                residual_y -= np.outer(t,q)
                weights.append(w); loadings.append(p); responses.append(q)
            if weights:
                w, p, q = np.stack(weights,1), np.stack(loadings,1), np.stack(responses,1)
                self.coef = w@np.linalg.pinv(p.T@w)@q.T
            else:
                self.coef = np.zeros((z.shape[1],y.shape[1]))
        elif self.method == "rbf":
            self.train_x = z.copy()
            kernel = self.kernel(z,z)
            self.coef = np.linalg.solve(kernel+self.strength*np.eye(len(z)),centered_y)
        elif self.method == "huber":
            # Fixed 1.5 cm Huber loss via IRLS, L2 penalty; no labels are deleted.
            design = np.column_stack([z,np.ones(len(z))])
            penalty = self.strength*z.shape[1]*np.eye(design.shape[1]);penalty[-1,-1]=0
            coefficient = np.zeros((design.shape[1],y.shape[1]));coefficient[-1]=self.bias
            for _ in range(25):
                residual = np.sqrt(np.mean((design@coefficient-y)**2,axis=1))
                weight = np.minimum(1,1.5/np.maximum(residual,1e-12))
                update = np.linalg.solve(design.T@(weight[:,None]*design)+penalty,design.T@(weight[:,None]*y))
                if np.max(np.abs(update-coefficient))<1e-6:
                    coefficient=update;break
                coefficient=update
            self.coef,self.bias=coefficient[:-1],coefficient[-1]
        else:
            self.coef = np.linalg.solve(z.T@z+self.strength*z.shape[1]*np.eye(z.shape[1]),z.T@centered_y)
        return self

    def kernel(self,a,b):
        d=np.maximum(np.sum(a*a,1)[:,None]+np.sum(b*b,1)[None,:]-2*a@b.T,0)
        return np.exp(-d/a.shape[1])

    def predict(self,x):
        z=(x-self.mean)/self.std
        if self.method=="rbf": value=self.kernel(z,self.train_x)@self.coef+self.bias
        else:value=(z@self.projection)@self.coef+self.bias
        return value


def grouped_folds(groups, labels, folds, seed):
    rng=np.random.default_rng(seed)
    names=np.array(sorted(set(groups)));rng.shuffle(names)
    rows={g:np.flatnonzero(groups==g) for g in names}
    # Greedily balance classes while keeping each chronological block intact.
    names=sorted(names,key=lambda g:max(np.sum(labels[rows[g]]==0),np.sum(labels[rows[g]]==1)),reverse=True)
    total=np.array([np.sum(labels==0),np.sum(labels==1)],dtype=float)
    counts=np.zeros((folds,2));assign=[[] for _ in range(folds)]
    for g in names:
        c=np.array([np.sum(labels[rows[g]]==0),np.sum(labels[rows[g]]==1)])
        costs=[]
        for k in range(folds):
            proposal=counts.copy();proposal[k]+=c
            costs.append(np.var(proposal/np.maximum(total,1),axis=0).sum())
        k=int(np.argmin(costs));counts[k]+=c;assign[k].extend(rows[g])
    all_ids=np.arange(len(groups))
    return [(np.setdiff1d(all_ids,held),np.array(sorted(held),dtype=int)) for held in assign]


def target(dist,xy,kind):
    if kind=="signed_xy":return xy
    if kind=="abs_xy":return np.abs(xy)
    if kind=="radius_squared":return dist**2
    return dist


def distance_prediction(value,kind):
    value=np.asarray(value)
    if kind in ("signed_xy","abs_xy"):
        if kind=="abs_xy":value=np.maximum(value,0)
        return np.linalg.norm(value,axis=1)
    if kind=="radius_squared":return np.sqrt(np.maximum(value[:,0],0))
    return np.maximum(value[:,0],0)


def candidates(bank):
    configs=[]
    for name in bank:
        for method,strength,components in [("ridge",.1,6),("ridge",1,6),("ridge",10,6),
                ("pls",1,2),("pls",1,6),("pcr",1,8),("huber",1,6),("rbf",1,6)]:
            configs.append({"features":name,"method":method,"strength":strength,"components":components,"target":"radius"})
    for name in (n for n in ("current156","mfcc_wavelet_modal","onset_tail_ratios") if n in bank):
        for kind in ("signed_xy","abs_xy","radius_squared"):
            configs.append({"features":name,"method":"ridge","strength":1,"components":6,"target":kind})
    return configs


def fit_predict(bank,dist,xy,fit_ids,test_ids,cfg):
    x=bank[cfg["features"]]
    model=ResearchRegressor(cfg["method"],cfg["strength"],cfg["components"])
    model.fit(x[fit_ids],target(dist[fit_ids],xy[fit_ids],cfg["target"]))
    return distance_prediction(model.predict(x[test_ids]),cfg["target"]),model


def score(dist,prediction):
    return {"mae_cm":float(np.mean(np.abs(dist-prediction))),
            **classification_metrics(dist<=4,prediction<=4)}


def nested_evaluate(bank,dist,xy,groups,out,prefix):
    configs=candidates(bank)
    outer=grouped_folds(groups,dist<=4,5,SEED)
    predictions={"nested_mae_selector":np.zeros(len(dist)),"nested_balanced_selector":np.zeros(len(dist)),
                 "fixed_current_ridge":np.zeros(len(dist)),"training_median":np.zeros(len(dist))}
    diagnostics=[];ranking=[]
    baseline={"features":"current156","method":"ridge","strength":1,"components":6,"target":"radius"}
    for fold,(train_ids,test_ids) in enumerate(outer):
        inner=grouped_folds(groups[train_ids],dist[train_ids]<=4,3,SEED+fold+1)
        board=[]
        for cfg in configs:
            inner_prediction=np.zeros(len(train_ids))
            for it,iv in inner:
                pred,_=fit_predict(bank,dist,xy,train_ids[it],train_ids[iv],cfg)
                inner_prediction[iv]=pred
            board.append({"config":cfg,**score(dist[train_ids],inner_prediction)})
        mae_best=min(board,key=lambda r:(r["mae_cm"],-r["balanced_accuracy"]))
        balanced_best=max(board,key=lambda r:(r["balanced_accuracy"],-r["mae_cm"]))
        for key,selected in (("nested_mae_selector",mae_best),("nested_balanced_selector",balanced_best)):
            predictions[key][test_ids],_=fit_predict(bank,dist,xy,train_ids,test_ids,selected["config"])
        predictions["fixed_current_ridge"][test_ids],_=fit_predict(bank,dist,xy,train_ids,test_ids,baseline)
        predictions["training_median"][test_ids]=np.median(dist[train_ids])
        diagnostics.append({"fold":fold,"train":len(train_ids),"test":len(test_ids),
            "held_out_groups":sorted(set(groups[test_ids])),"mae_selection":mae_best,"balanced_selection":balanced_best})
        ranking.append(board)
        (out/f"{prefix}_progress.json").write_text(json.dumps(diagnostics,indent=2)+'\n')
        print(f"{prefix} outer fold {fold+1}/5 complete; MAE-selected {mae_best['config']}; balanced-selected {balanced_best['config']}",flush=True)
    result={"n":len(dist),"groups":len(set(groups)),"candidate_count":len(configs),
            "metrics":{key:score(dist,value) for key,value in predictions.items()},"folds":diagnostics,"inner_leaderboards":ranking}
    (out/f"{prefix}_results.json").write_text(json.dumps(result,indent=2)+'\n')
    np.savez(out/f"{prefix}_oof.npz",distances=dist,groups=groups,**predictions)
    # Final fit chosen by pooled inner-CV ranking; OOF estimates above remain separate.
    mean_scores=[]
    for index,cfg in enumerate(configs):
        mean_scores.append((float(np.mean([board[index]["mae_cm"] for board in ranking])),cfg))
    _,cfg=min(mean_scores,key=lambda p:p[0])
    _,model=fit_predict(bank,dist,xy,np.arange(len(dist)),np.arange(len(dist)),cfg)
    with (out/f"{prefix}_candidate.pkl").open('wb') as fh:pickle.dump({"config":cfg,"model":model,"research_only":True},fh)
    return result


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--out',type=Path,default=ROOT/'ml/runs/20261028-research')
    args=ap.parse_args();args.out.mkdir(parents=True,exist_ok=False)
    base=ROOT/'ml/runs/20261028-reviewed-combined'
    with (base/'manifest.csv').open(newline='') as fh:rows=list(csv.DictReader(fh))
    clips=[];xy=[];groups=[];positions={}
    for row in rows:
        session=row['source_session']
        if session not in positions:
            with (base/'source_review'/session/'positions.csv').open(newline='') as fh:
                positions[session]={r['file']:r for r in csv.DictReader(fh)}
        pos=positions[session][row['source_file']];xy.append([float(pos['x_cm']),float(pos['y_cm'])])
        path=base/'dataset'/row['file'];raw=path.read_bytes()
        assert hashlib.sha256(raw).hexdigest()==row['sha256']
        clips.append(np.frombuffer(raw,dtype='<i2'))
        number=int(Path(row['source_file']).stem.split('-')[-1]);groups.append(f'{session}:block{(number-1)//8:03d}')
    dist=np.array([float(r['dist_cm']) for r in rows]);xy=np.array(xy);groups=np.array(groups)
    discrepancy=float(np.max(np.abs(np.linalg.norm(xy,axis=1)-dist)))
    if discrepancy>.05:raise ValueError(f'Coordinate/radius mismatch {discrepancy} cm')
    bank=feature_bank([c[:512] for c in clips])
    print(f'{len(clips)} clips, {len(set(groups))} chronological groups; coordinate consistency {discrepancy:.4f} cm',flush=True)
    combined=nested_evaluate(bank,dist,xy,groups,args.out,'combined')
    ids=[];tails=[]
    for i,c in enumerate(clips):
        clipped=np.flatnonzero(np.abs(c.astype(np.int32))>=30000)
        start=int(clipped[-1])+1 if len(clipped) else 64
        if len(c)-start>=2048:ids.append(i);tails.append(c[start:start+2048])
    ids=np.array(ids)
    tails_result=nested_evaluate(feature_bank(tails),dist[ids],xy[ids],groups[ids],args.out,'tail')
    summary={"combined":combined['metrics'],"tail":tails_result['metrics'],
        "coordinate_label_max_difference_cm":discrepancy,"notes":[
        'Groups contain eight consecutive trigger numbers within each session; every outer fold holds out whole groups.',
        'All normalization and supervised dimension reduction are fit inside training folds.',
        'All model/feature selection is nested inside the outer evaluation; no label changes or firmware updates.',
        'This is a development-data reanalysis, not an independent tennis-club test.',
        'The tail fixed-current-ridge result is the same feature recipe applied to 128 ms, not the deployed 32 ms model.']}
    (args.out/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
    print(json.dumps(summary,indent=2),flush=True)


if __name__=='__main__':main()

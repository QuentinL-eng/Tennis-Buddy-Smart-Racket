"""Compare onset + decay fusion on the same long recordings, with nested grouped CV."""
import csv
import json
from pathlib import Path
import numpy as np
from scipy.stats import spearmanr
from compare_models import audio_features
from research_methods import nested_evaluate

ROOT=Path(__file__).resolve().parents[1]


def main():
    base=ROOT/'ml/runs/20261028-reviewed-combined';out=ROOT/'ml/runs/20261028-research'
    with (base/'manifest.csv').open(newline='') as fh:rows=list(csv.DictReader(fh))
    onset=[];tails=[];metadata=[];dist=[];groups=[];xy=[];positions={}
    for r in rows:
        c=np.fromfile(base/'dataset'/r['file'],dtype='<i2').astype(float)
        saturated=np.flatnonzero(np.abs(c)>=30000);start=int(saturated[-1])+1 if len(saturated) else 64
        if len(c)-start<2048:continue
        session=r['source_session']
        if session not in positions:
            with (base/'source_review'/session/'positions.csv').open(newline='') as fh:positions[session]={v['file']:v for v in csv.DictReader(fh)}
        p=positions[session][r['source_file']];xy.append([float(p['x_cm']),float(p['y_cm'])])
        tail=c[start:start+2048];onset.append(audio_features(c[:512])[1]);tails.append(audio_features(tail)[1])
        rms=lambda v:np.sqrt(np.mean((v-v.mean())**2))
        levels=np.array([rms(c[:512]),*[rms(v) for v in np.array_split(tail,4)]])
        metadata.append([len(c)/16000,(start-64)/16000,len(saturated)/len(c),*np.log10((levels+1)/(levels[0]+1))])
        dist.append(float(r['dist_cm']));number=int(Path(r['source_file']).stem.split('-')[-1]);groups.append(f'{session}:block{(number-1)//8:03d}')
    onset,tail,meta=np.stack(onset),np.stack(tails),np.array(metadata)
    # nested_evaluate requires these two named feature sets for target-transform checks.
    features={'current156':onset,'onset_tail_ratios':np.hstack([onset,tail,meta]),
              'tail_only':tail,'clipping_decay_ratios':meta}
    result=nested_evaluate(features,np.array(dist),np.array(xy),np.array(groups),out,'window_fusion')
    result['feature_names']={key:value.shape[1] for key,value in features.items()}
    result['duration_distance_spearman']=float(spearmanr(meta[:,0],dist).statistic)
    (out/'window_fusion_results.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result['metrics'],indent=2),flush=True)


if __name__=='__main__':main()

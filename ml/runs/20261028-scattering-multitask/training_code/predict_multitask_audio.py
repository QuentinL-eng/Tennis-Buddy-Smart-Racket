"""Offline candidate inference only. Does not change the racket model."""
import argparse
import json
from pathlib import Path
import pickle
import numpy as np
from train_scattering_multitask import scattering_features
from compare_models import audio_features

ROOT=Path(__file__).resolve().parents[1]


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('clip',type=Path)
    ap.add_argument('--model',type=Path,default=ROOT/'ml/runs/20261028-scattering-multitask/combined_candidate.pkl')
    args=ap.parse_args()
    with args.model.open('rb') as fh:checkpoint=pickle.load(fh)
    raw=np.fromfile(args.clip,dtype='<i2');count=checkpoint['scattering']['samples'];start=0
    if count==2048:
        near=np.flatnonzero(np.abs(raw.astype(np.int32))>=30000)
        start=int(near[-1])+1 if len(near) else 64
    if len(raw)-start<count:raise SystemExit('Recording does not contain the required model window.')
    clip=raw[start:start+count];cfg=checkpoint['config']
    current=audio_features(clip)[1][None,:]
    if cfg['feature']=='current':x=current
    else:
        scat,_=scattering_features([clip])
        x=scat if cfg['feature']=='scattering' else np.hstack([current,scat])
    if cfg['kind']=='multitask':
        prediction=checkpoint['model'].predict(x);d=float(prediction['distance'][0])
        extra={'region_head_sweet':bool(prediction['sweet'][0]),'region_head_probabilities_uncalibrated':prediction['region_probability'][0].tolist()}
    else:
        d=max(0,float(checkpoint['model'].predict(x)[0,0]));extra={}
    print(json.dumps({'distance_cm':d,'sweet_by_distance':d<=4,'model':cfg,'offline_candidate_only':True,**extra},indent=2))


if __name__=='__main__':main()

"""Render an MP4 data replay of the recorded synthetic iPhone test."""
from pathlib import Path
import json
import subprocess
import sys
import cv2
import numpy as np
import imageio_ffmpeg

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'src'))
from tennisrobot.physics import FlightModel
from tennisrobot.types import BallState

SOURCE = ROOT / 'runs/run-20261026-094759-73724.jsonl'
OUT = ROOT / 'runs/tennis_ball_test_replay.mp4'
events = [json.loads(line) for line in SOURCE.read_text().splitlines()]
start = events[0]['t']
obs = [e for e in events if e['kind'] == 'observation']
fits = [e for e in events if e['kind'] == 'fit']
plans = [e for e in events if e['kind'] == 'plan']
sent = [e for e in events if e['kind'] == 'strike_sent']
completed = [e for e in events if e['kind'] == 'outcome']
selected = [max((p for p in plans if p['t'] <= s['t']), key=lambda p:p['t']) for s in sent]
flight = FlightModel(max_step_s=0.01)
predictions = {}
for fit in fits:
 state = BallState(fit['t_ref'], fit['position'], fit['velocity'])
 points = []
 for step in range(101):
  if step:
   state = flight.propagate_to(state, fit['t_ref'] + step * .01)
  points.append(state.position_m.tolist())
 predictions[fit['t']] = points

W,H,FPS = 1280,720,30
BG=(24,18,12); PANEL=(42,32,23); WHITE=(245,240,232); GREY=(171,157,139)
YELLOW=(61,231,255); CYAN=(232,201,69); GREEN=(134,221,124)

def label(im,s,x,y,size=.6,color=WHITE,thick=1):
 cv2.putText(im,s,(x,y),cv2.FONT_HERSHEY_SIMPLEX,size,color,thick,cv2.LINE_AA)

def yz(p):
 return (int(802 + p[1]/7*420),int(465-p[2]/2.5*265))

def render(t):
 im=np.full((H,W,3),BG,np.uint8)
 label(im,'TENNIS BALL / PC TRACKING TEST',40,52,.92,WHITE,2)
 label(im,'DATA REPLAY  |  SYNTHETIC INPUT  |  MOCK ARM ONLY',42,85,.52,YELLOW)
 label(im,'0.5x playback',1060,51,.55,CYAN)
 cv2.rectangle(im,(30,112),(755,505),PANEL,-1)
 cv2.rectangle(im,(775,112),(1250,505),PANEL,-1)
 label(im,'iPHONE PACKETS: IMAGE COORDINATES',48,143,.57,CYAN)
 label(im,'PC PREDICTION: SIDE VIEW',794,143,.57,CYAN)
 for x in range(55,740,85): cv2.line(im,(x,167),(x,477),(65,51,38),1)
 for y in range(175,480,60): cv2.line(im,(52,y),(734,y),(65,51,38),1)
 label(im,'1920 x 1080  |  nominal 240 fps',48,491,.43,GREY)
 recent=[o for o in obs if t-.16<=o['t']<=t]
 for i,o in enumerate(recent):
  p=(int(52+o['u']/1920*680),int(165+o['v']/1080*310))
  if 52<=p[0]<=734 and 165<=p[1]<=478:
   cv2.circle(im,p,max(2,int(o['r']*.35)),YELLOW,1,cv2.LINE_AA)
 if recent:
  o=recent[-1]
  label(im,f"u {o['u']:.0f} px   v {o['v']:.0f} px   radius {o['r']:.1f} px",48,530,.49,YELLOW)
 else: label(im,'Waiting for ball observations',48,530,.5,GREY)
 for z in (0,1,2):
  a,b=yz([0,0,z]),yz([0,7,z]); cv2.line(im,a,b,(65,51,38),1)
  label(im,f'{z}m',780,a[1]+4,.35,GREY)
 for y in (0,2,4,6):
  p=yz([0,y,0]); label(im,f'{y}m',p[0]-4,483,.35,GREY)
 intercept_x=yz([0,.58,0])[0]
 cv2.line(im,(intercept_x,177),(intercept_x,465),GREEN,1)
 label(im,'strike plane',intercept_x+5,188,.4,GREEN)
 active=[f for f in fits if t-.65<=f['t']<=t]
 if active and recent:
  f=active[-1]
  path=[yz(p) for p in predictions[f['t']] if 0<=p[2]<=2.6 and 0<=p[1]<=7]
  if len(path)>1: cv2.polylines(im,[np.array(path,np.int32)],False,CYAN,2,cv2.LINE_AA)
  current=flight.propagate_to(BallState(f['t_ref'],f['position'],f['velocity']),max(t,f['t_ref']))
  p=yz(current.position_m)
  if 800<p[0]<1245 and 175<p[1]<470: cv2.circle(im,p,7,YELLOW,-1,cv2.LINE_AA)
  label(im,f"Fit residual {f['rms_px']:.2f} px",797,530,.48,CYAN)
 else: label(im,'Prediction shown during tracked flight',797,530,.43,GREY)
 for idx,p in enumerate(selected):
  if p['t']<=t<=p['strike_time']+.4:
   q=yz(p['impact']); cv2.circle(im,q,11,GREEN,2,cv2.LINE_AA)
   label(im,f"BALL {idx+1}  target z={p['impact'][2]:.2f} m",797,560,.51,GREEN)
 n=sum(e['t']<=t for e in completed)
 label(im,f'MOCK STRIKES COMPLETE: {n} / 3',48,572,.64,GREEN,2)
 label(im,f'Test time {max(0,t-start):.2f} / 8.00 s',48,604,.5,GREY)
 for idx,e in enumerate(completed):
  x=350+idx*285
  done=e['t']<=t
  label(im,f'BALL {idx+1}: '+('COMPLETE' if done else 'PENDING'),x,604,.49,GREEN if done else GREY)
 cv2.line(im,(48,630),(1230,630),GREY,1)
 cv2.line(im,(48,630),(int(48+1182*min(1,max(0,(t-start)/8))),630),CYAN,4)
 label(im,'REPLAY OF RECORDED DATA - NOT CAMERA FOOTAGE OR EPSON RC+ MOTION',48,670,.53,YELLOW)
 label(im,'Hits, robot reach, collision clearance and real timing are not verified.',48,699,.47,GREY)
 return im

ffmpeg=imageio_ffmpeg.get_ffmpeg_exe()
cmd=[ffmpeg,'-y','-f','rawvideo','-vcodec','rawvideo','-pix_fmt','bgr24','-s',f'{W}x{H}','-r',str(FPS),'-i','-','-an','-c:v','libx264','-preset','fast','-crf','20','-pix_fmt','yuv420p','-movflags','+faststart',str(OUT)]
proc=subprocess.Popen(cmd,stdin=subprocess.PIPE,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
for i in range(18*FPS):
 t=start+min(8,max(0,(i/FPS-1)*.5))
 frame=render(t)
 if i==80: cv2.imwrite(str(OUT.with_suffix('.preview.png')),frame)
 proc.stdin.write(frame.tobytes())
proc.stdin.close()
errors=proc.stderr.read().decode(errors='replace')
if proc.wait()!=0: raise RuntimeError(errors)
cap=cv2.VideoCapture(str(OUT))
print(json.dumps({'path':str(OUT),'bytes':OUT.stat().st_size,'frames':cap.get(cv2.CAP_PROP_FRAME_COUNT),'fps':cap.get(cv2.CAP_PROP_FPS),'readable':cap.read()[0]}))
cap.release()

import React from 'react';
import { AbsoluteFill, OffthreadVideo, staticFile, useCurrentFrame } from 'remotion';
import { Effect } from '../components/Timeline';
import { Backdrop } from '../components/ui';
import { colors, fonts } from '../config/brand';
import twin from '../config/liveTwin.json';
import { GRADE } from '../hype/kit';
import { enter } from '../lib/anim';

const FPS = 30;
/** Frames of one segment on screen. scripts/cut-selects.py cuts both videos to these same lengths. */
const frames = (s: (typeof twin.segments)[number]) => Math.round(((s.r[1] - s.r[0]) / s.speed) * FPS);
const starts = twin.segments.reduce<number[]>((all, s, i) => [...all, (all[i - 1] ?? 0) + (i ? frames(twin.segments[i - 1]) : 0)], []);
/** Local frame of each ball contact. The camera has no sound at 120 fps, so the impact goes here. */
const twinContacts = twin.segments.map((s, i) => starts[i] + Math.round(((s.contact - s.r[0]) / s.speed) * FPS));

const panel = (hit: number): React.CSSProperties => ({
  position: 'absolute', overflow: 'hidden', background: '#000', borderRadius: 26,
  border: `3px solid ${hit > 0.02 ? colors.accent : colors.track}`,
  boxShadow: `0 0 ${10 + hit * 60}px rgba(221,232,91,${hit * 0.55})`,
});
const LABEL: React.CSSProperties = { fontFamily: fonts.mono, fontSize: 24, letterSpacing: 3, color: colors.muted };

// The camera and the phone's own screen recording, cut to the same real moments. Nothing is synced by hand or re-labelled:
// both play at one speed from one offset, measured from the motion in each (config/liveTwin.json).
export const LiveTwin: React.FC = () => {
  const frame = useCurrentFrame();
  let i = twin.segments.length - 1;
  while (i > 0 && frame < starts[i]) i--;
  const seg = twin.segments[i];
  const hit = Math.max(0, ...twinContacts.map((c) => (frame >= c ? Math.exp(-(frame - c) / 7) : 0)));
  return (
    <Backdrop glow={0.08}>
      <div style={{ ...panel(hit), left: 36, top: 36, width: 1130, height: 1008 }}>
        <OffthreadVideo muted src={staticFile('footage/twin-cam.mp4')} style={{ width: '100%', height: '100%', objectFit: 'cover', filter: GRADE }} />
        <div style={{ position: 'absolute', left: 26, top: 24, ...LABEL, color: colors.text, background: 'rgba(11,12,9,0.72)', padding: '8px 16px', borderRadius: 8 }}>ON COURT</div>
        <div key={i} style={{ ...enter(frame, starts[i], 8), position: 'absolute', right: 26, top: 24, fontFamily: fonts.mono, fontSize: 26, fontWeight: 700, letterSpacing: 2, color: '#11130c', background: colors.accent, padding: '8px 16px', borderRadius: 8 }}>{seg.chip}</div>
      </div>
      <div style={{ position: 'absolute', left: 1196, top: 40, ...LABEL, color: colors.accent }}>IN THE APP, SAME MOMENT</div>
      <div style={{ ...panel(hit), left: 1196, top: 86, width: 688, height: 630 }}>
        <OffthreadVideo muted src={staticFile('footage/twin-app.mp4')} style={{ width: '100%', height: '100%', objectFit: 'cover' }} />
      </div>
      <AbsoluteFill style={{ left: 1196, top: 744, width: 688, height: 300, justifyContent: 'space-between' }}>
        <div key={i} style={{ ...enter(frame, starts[i], 10), fontFamily: fonts.display, fontSize: 62, fontWeight: 800, letterSpacing: -1, lineHeight: 1.08, color: colors.text }}>{seg.title}</div>
        <div style={{ fontFamily: fonts.mono, fontSize: 21, lineHeight: 1.45, color: colors.muted }}>
          120 fps camera beside the iPhone screen recording, lined up from the motion in each.
        </div>
      </AbsoluteFill>
      {twinContacts.map((c) => <Effect key={c} cue={{ sfx: 'impact', volume: 0.75, at: 0 }} frame={c} />)}
    </Backdrop>
  );
};

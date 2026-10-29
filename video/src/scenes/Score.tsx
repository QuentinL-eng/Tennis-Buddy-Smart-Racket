import React from 'react';
import { AbsoluteFill, useCurrentFrame } from 'remotion';
import { Backdrop, Title } from '../components/ui';
import { colors, fonts } from '../config/brand';
import { copy } from '../config/copy';
import { enter, ramp } from '../lib/anim';

// Each double-tap on the handle awards a point. Frames of each tap pair:
const TAPS = [36, 100];
const POINTS = ['0', '15', '30', '40'];
// [you, opponent] point index, games, sets before/after each tap pair
const STATES = [
  { pts: [2, 1], games: [3, 2] },
  { pts: [3, 1], games: [3, 2] },
  { pts: [0, 0], games: [4, 2] },
];

const Row: React.FC<{ name: string; sets: number; games: number; pts: string; serving?: boolean; flash: number }> = ({ name, sets, games, pts, serving, flash }) => (
  <div style={{ display: 'flex', alignItems: 'center', height: 110, fontFamily: fonts.sans, fontWeight: 700, fontSize: 52 }}>
    <div style={{ width: 60, color: colors.accent, fontSize: 30 }}>{serving ? '●' : ''}</div>
    <div style={{ flex: 1, letterSpacing: 2 }}>{name}</div>
    <div style={{ width: 90, textAlign: 'center' }}>{sets}</div>
    <div style={{ width: 90, textAlign: 'center', color: colors.accent }}>{games}</div>
    <div style={{ width: 150, textAlign: 'center', background: `rgba(243,245,236,${0.92})`, color: '#7a3d2c', height: '100%', display: 'flex', alignItems: 'center', justifyContent: 'center', transform: `scale(${1 + flash * 0.12})` }}>{pts}</div>
  </div>
);

export const Score: React.FC = () => {
  const frame = useCurrentFrame();
  const step = TAPS.filter((t) => frame >= t + 8).length;
  const s = STATES[step];
  const flash = TAPS.reduce((m, t) => Math.max(m, 1 - Math.abs(frame - t - 10) / 8), 0);
  const tapRing = (t: number, d: number) => {
    const p = ramp(frame, t + d, t + d + 14);
    return p > 0 && p < 1 ? p : 0;
  };

  return (
    <Backdrop glow={0.08}>
      <AbsoluteFill style={{ alignItems: 'center', paddingTop: 110, gap: 18 }}>
        <Title size={84} style={enter(frame, 4)}>{copy.score.title}</Title>
        <div style={{ ...enter(frame, 14), fontSize: 36, color: colors.muted }}>{copy.score.sub}</div>
      </AbsoluteFill>
      {/* Handle, seen end-on, with tap ripples */}
      <div style={{ position: 'absolute', left: 300, top: 520, width: 140, height: 330, borderRadius: 30, background: 'linear-gradient(90deg,#1b1d17,#3b3e33,#1b1d17)', border: `2px solid ${colors.track}` }} />
      {TAPS.flatMap((t) => [0, 8].map((d) => {
        const p = tapRing(t, d);
        return p ? <div key={`${t}${d}`} style={{ position: 'absolute', left: 370 - 40 - p * 80, top: 640 - 40 - p * 80, width: 80 + p * 160, height: 80 + p * 160, borderRadius: '50%', border: `4px solid ${colors.accent}`, opacity: 1 - p }} /> : null;
      }))}
      <div style={{ position: 'absolute', left: 300, top: 880, width: 140, textAlign: 'center', fontSize: 28, color: colors.accent, opacity: flash > 0 ? 1 : 0.35 }}>tap · tap</div>
      <div style={{ position: 'absolute', left: 680, top: 560, width: 900, borderRadius: 18, overflow: 'hidden', background: `linear-gradient(90deg, ${colors.score}cc, ${colors.score}88)`, border: '2px solid rgba(255,255,255,0.4)', ...enter(frame, 10) }}>
        <Row name={copy.score.you} sets={1} games={s.games[0]} pts={POINTS[s.pts[0]]} serving flash={flash} />
        <div style={{ height: 1, background: 'rgba(255,255,255,0.25)' }} />
        <Row name={copy.score.opponent} sets={0} games={s.games[1]} pts={POINTS[s.pts[1]]} flash={0} />
      </div>
    </Backdrop>
  );
};

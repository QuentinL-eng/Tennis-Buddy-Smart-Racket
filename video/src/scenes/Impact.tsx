import React from 'react';
import { AbsoluteFill, interpolate, useCurrentFrame, useVideoConfig } from 'remotion';
import { Racket } from '../components/Racket';
import { Stage3D } from '../components/Stage3D';
import { Backdrop, Card, Kicker } from '../components/ui';
import { colors, fonts } from '../config/brand';
import { copy } from '../config/copy';
import { enter, lerp, pop, ramp, rand } from '../lib/anim';

const HIT = 60; // frame the ball meets the strings
const RACKET_X = -1.9;
const SWEET: [number, number, number] = [RACKET_X, 0.78, 0.05];

// Synthetic sensor traces shaped like the real ones: swing bell (gyro),
// impact spike + ringing (high-g), broadband burst (mic). Illustrative, not data.
const N = 220;
const HIT_AT = 0.55;
const signal = (kind: number, i: number) => {
  const x = i / N;
  const after = x - HIT_AT;
  if (kind === 0) return Math.exp(-((x - 0.5) ** 2) / 0.02) * 0.8 - (after > 0 ? 0.25 * Math.exp(-after * 20) : 0) + (rand(i) - 0.5) * 0.04;
  if (kind === 1) return (after >= 0 ? Math.exp(-after * 30) * Math.cos(after * 260) * 0.95 : 0) + (rand(i + 99) - 0.5) * 0.06;
  return (after >= 0 ? Math.exp(-after * 14) * (rand(i + 7) - 0.5) * 1.8 : (rand(i + 7) - 0.5) * 0.05);
};

const Trace: React.FC<{ kind: number; label: string; progress: number }> = ({ kind, label, progress }) => {
  const w = 760, h = 120;
  const count = Math.max(2, Math.floor(N * progress));
  const d = Array.from({ length: count }, (_, i) => `${i ? 'L' : 'M'}${(i / N) * w},${h / 2 - signal(kind, i) * (h / 2 - 6)}`).join(' ');
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 24 }}>
      <div style={{ width: 200, fontSize: 28, color: colors.muted, textAlign: 'right' }}>{label}</div>
      <svg width={w} height={h} style={{ background: colors.card, borderRadius: 14 }}>
        <line x1={HIT_AT * w} x2={HIT_AT * w} y1={0} y2={h} stroke={colors.track} strokeWidth={2} />
        <path d={d} fill="none" stroke={kind === 1 ? colors.accent : colors.text} strokeWidth={3} strokeLinejoin="round" />
      </svg>
    </div>
  );
};

export const Impact: React.FC = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const t = frame - HIT;

  // Ball: in from right-front, out to the left after contact.
  const inT = ramp(frame, 18, HIT, (x) => x);
  const outT = ramp(frame, HIT, HIT + 40, (x) => x);
  const ball: [number, number, number] = frame < HIT
    ? [lerp(2.6, SWEET[0], inT), lerp(1.5, SWEET[1], inT), lerp(3.2, SWEET[2] + 0.15, inT)]
    : [lerp(SWEET[0], SWEET[0] - 2.4, outT), lerp(SWEET[1], 1.9, outT), lerp(SWEET[2] + 0.15, 3.6, outT)];
  const wobble = t > 0 ? Math.exp(-t / 9) * Math.sin(t * 1.9) * 0.05 : 0;
  const ring = t > 0 ? ramp(frame, HIT, HIT + 24) : 0;

  // Traces sweep in sync with the ball: the impact spike draws exactly on HIT.
  const progress = interpolate(frame, [HIT - HIT_AT * 70, HIT + (1 - HIT_AT) * 70], [0, 1], { extrapolateLeft: 'clamp', extrapolateRight: 'clamp' });
  const readout = pop(frame, HIT + 30, fps);
  const speed = Math.round(copy.impact.speed * ramp(frame, HIT + 30, HIT + 60));

  return (
    <Backdrop glow={0.08 + (t > 0 ? 0.2 * Math.exp(-t / 10) : 0)}>
      <Stage3D camera={[0, 0.6, 7.2]} target={[0, 0.3, 0]} fov={34} env="studio" envIntensity={1.4} hero>
        <pointLight position={[-2.4, 2.2, -1.8]} intensity={40} distance={8} color="#ffffff" />
        <Racket position={[RACKET_X, 0, 0]} rotation={[wobble, 0.35, wobble * 0.5]} />
        <mesh position={ball}>
          <sphereGeometry args={[0.15, 48, 48]} />
          <meshStandardMaterial color="#D9EE3F" roughness={0.9} />
        </mesh>
        {ring > 0 && ring < 1 && (
          <mesh position={SWEET} rotation={[0, 0.35, 0]} scale={0.2 + ring * 2.2}>
            <torusGeometry args={[0.5, 0.012, 8, 96]} />
            <meshBasicMaterial color={colors.accent} transparent opacity={1 - ring} />
          </mesh>
        )}
      </Stage3D>
      <AbsoluteFill style={{ padding: '100px 110px', alignItems: 'flex-end', gap: 22 }}>
        <Kicker style={{ ...enter(frame, 4), alignSelf: 'flex-end', marginRight: 0 }}>{copy.impact.kicker}</Kicker>
        {copy.impact.traces.map((label, k) => <Trace key={label} kind={k} label={label} progress={progress} />)}
        <Card style={{ marginTop: 18, width: 760, opacity: readout, transform: `scale(${0.92 + 0.08 * readout})`, transformOrigin: 'right top', border: `2px solid ${colors.better}` }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 18, fontSize: 38, fontWeight: 700 }}>
            {copy.impact.stroke}
            <span style={{ fontSize: 26, color: colors.better, background: 'rgba(94,220,138,0.15)', padding: '4px 14px', borderRadius: 20 }}>{copy.impact.badge}</span>
          </div>
          <div style={{ display: 'flex', alignItems: 'baseline', gap: 14 }}>
            <span style={{ fontFamily: fonts.display, fontSize: 140, fontWeight: 800, lineHeight: 1 }}>{speed}</span>
            <span style={{ fontSize: 44, color: colors.muted }}>{copy.impact.unit}</span>
          </div>
          <div style={{ fontSize: 32, color: colors.muted, marginTop: 6 }}>{copy.impact.sub}</div>
        </Card>
      </AbsoluteFill>
    </Backdrop>
  );
};

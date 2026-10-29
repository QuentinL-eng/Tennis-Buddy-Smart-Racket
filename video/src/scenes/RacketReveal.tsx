import React from 'react';
import { AbsoluteFill, Easing, interpolate, useCurrentFrame } from 'remotion';
import { Racket } from '../components/Racket';
import { Stage3D } from '../components/Stage3D';
import { Backdrop, Title } from '../components/ui';
import { colors } from '../config/brand';
import { copy } from '../config/copy';
import { enter, ramp } from '../lib/anim';

type V3 = [number, number, number];
const ease = Easing.inOut(Easing.cubic);

/** Camera keyframes: [frame, position, target, fov]. Edit these to re-frame the shot. */
const SHOT: [number, V3, V3, number][] = [
  [0, [-0.35, 1.55, 1.15], [-0.95, 1.25, 0], 22], // macro on the top of the hoop
  [55, [0.05, 0.55, 1.9], [-0.85, 0.55, 0], 24], // tracking down the beam
  [125, [0, 0.15, 6.1], [0, 0.05, 0], 32], // hero framing, racket left, title right
];

const along = (frame: number, pick: (k: (typeof SHOT)[number]) => number) =>
  interpolate(frame, SHOT.map((k) => k[0]), SHOT.map(pick), { easing: ease, extrapolateLeft: 'clamp', extrapolateRight: 'clamp' });

// Opening hero shot: macro along the frame, light sweeping the clearcoat, pull back to reveal.
export const RacketReveal: React.FC = () => {
  const frame = useCurrentFrame();
  const cam: V3 = [0, 1, 2].map((i) => along(frame, (k) => k[1][i])) as V3;
  const target: V3 = [0, 1, 2].map((i) => along(frame, (k) => k[2][i])) as V3;
  const fov = along(frame, (k) => k[3]);

  // Edge-on to three-quarter, then a slow drift so the hero frame never sits dead still.
  const turn = interpolate(frame, [0, 125, 200], [1.35, 0.42, 0.32], { easing: Easing.out(Easing.quad), extrapolateRight: 'clamp' });
  const sweepX = interpolate(frame, [0, 90], [-4, 4], { easing: ease, extrapolateRight: 'clamp' });
  const fadeIn = ramp(frame, 0, 18);

  return (
    <Backdrop glow={0.1 * ramp(frame, 60, 125)}>
      <AbsoluteFill style={{ opacity: fadeIn }}>
        <Stage3D camera={cam} target={target} fov={fov} env="studio" envIntensity={1.4} hero>
          {/* back rim light: separates the dark frame from the dark background */}
          <pointLight position={[-0.6, 2.2, -1.8]} intensity={40} distance={8} color="#ffffff" />
          <pointLight position={[-2.2, -1.2, -1.2]} intensity={18} distance={6} color={colors.accent} />
          {/* moving glint across the clearcoat during the macro */}
          <pointLight position={[sweepX, 1.6, 2.2]} intensity={25 * (1 - ramp(frame, 80, 110))} distance={8} color="#ffffff" />
          <Racket position={[-1.1, 0, 0]} rotation={[0.1, turn, -0.16]} glow={ramp(frame, 100, 130)} />
        </Stage3D>
      </AbsoluteFill>
      <AbsoluteFill style={{ justifyContent: 'center', paddingLeft: 1000, gap: 16 }}>
        <Title size={124} style={enter(frame, 100, 18)}>{copy.reveal.name}</Title>
        <div style={{ ...enter(frame, 114, 18), fontSize: 46, color: colors.muted }}>{copy.reveal.tagline}</div>
        <div style={{ ...enter(frame, 126, 18), width: 120, height: 6, borderRadius: 3, background: colors.accent, marginTop: 12 }} />
      </AbsoluteFill>
    </Backdrop>
  );
};

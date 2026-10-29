import { Easing, interpolate, spring } from 'remotion';

const clamp = { extrapolateLeft: 'clamp', extrapolateRight: 'clamp' } as const;

/** 0→1 between two frames, eased. */
export const ramp = (frame: number, start: number, end: number, ease = Easing.out(Easing.cubic)) =>
  interpolate(frame, [start, end], [0, 1], { ...clamp, easing: ease });

/** Fade + rise for text entering at `start`. */
export const enter = (frame: number, start: number, dur = 14, rise = 24) => {
  const t = ramp(frame, start, start + dur);
  return { opacity: t, transform: `translateY(${(1 - t) * rise}px)` };
};

export const pop = (frame: number, start: number, fps: number) =>
  spring({ frame: frame - start, fps, config: { damping: 12, stiffness: 140 } });

export const lerp = (a: number, b: number, t: number) => a + (b - a) * t;

/** Deterministic pseudo-random in [0,1) — Remotion renders frames in parallel, so no Math.random. */
export const rand = (seed: number) => {
  const x = Math.sin(seed * 127.1 + 311.7) * 43758.5453;
  return x - Math.floor(x);
};

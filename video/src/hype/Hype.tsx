// 30-second X hype clip cut to "Keep It Movin'". Everything is timed in beats;
// copy, numbers and beat positions come from src/config/hype.ts.
import React from 'react';
import { AbsoluteFill, Audio, Sequence, interpolate, spring, staticFile, useCurrentFrame, useVideoConfig } from 'remotion';
import { Effect } from '../components/Timeline';
import { Racket } from '../components/Racket';
import { Stage3D } from '../components/Stage3D';
import { colors, fonts } from '../config/brand';
import { hype, hypeCues } from '../config/hype';
import { Glasses, Watch } from '../scenes/Devices';

const FPS = 30;
export const BEAT = (FPS * 60) / hype.song.bpm; // frames per beat (~18.95)
const f = (beat: number) => Math.round(beat * BEAT);
export const hypeFrames = f(hype.beats);

type V3 = [number, number, number];

/** A shot spanning [from, to) beats; children see a local frame starting at 0. */
const Shot: React.FC<{ at: number[] | readonly number[]; children: React.ReactNode }> = ({ at, children }) => (
  <Sequence from={f(at[0])} durationInFrames={f(at[1]) - f(at[0])}>{children}</Sequence>
);

/** 1 on each beat, decaying fast: drives pulses and flashes. */
const pulse = (frame: number, every = 1) => Math.exp(-((frame % (BEAT * every)) / BEAT) * 6);

/** Slam-in: overshooting scale + quick fade, starting at local frame `start`. */
const useSlam = (start: number) => {
  const frame = useCurrentFrame();
  const s = spring({ frame: frame - start, fps: FPS, config: { damping: 11, stiffness: 220 } });
  const shake = frame >= start && frame < start + 5 ? Math.sin(frame * 9.1) * 6 : 0;
  return { opacity: frame < start ? 0 : Math.min(1, (frame - start) / 3), transform: `translate(${shake}px, ${-shake / 2}px) scale(${1.5 - 0.5 * s})` };
};

const Big: React.FC<{ children: React.ReactNode; size?: number; color?: string; style?: React.CSSProperties }> = ({ children, size = 170, color = colors.text, style }) => (
  <div style={{ fontFamily: fonts.display, fontWeight: 800, fontSize: size, lineHeight: 0.95, letterSpacing: -3, color, textTransform: 'uppercase', ...style }}>{children}</div>
);
const Small: React.FC<{ children: React.ReactNode; style?: React.CSSProperties }> = ({ children, style }) => (
  <div style={{ fontFamily: fonts.sans, fontWeight: 600, fontSize: 40, color: colors.muted, letterSpacing: 1, ...style }}>{children}</div>
);
const Center: React.FC<{ children: React.ReactNode; style?: React.CSSProperties }> = ({ children, style }) => (
  <AbsoluteFill style={{ justifyContent: 'center', alignItems: 'center', textAlign: 'center', ...style }}>{children}</AbsoluteFill>
);

// ---------- 1. Ball bouncing on the beat, words slam in ----------
const Ball: React.FC<{ spin: number }> = ({ spin }) => (
  <svg width={110} height={110} viewBox="-55 -55 110 110" style={{ transform: `rotate(${spin}deg)` }}>
    <circle r={52} fill="#D9EE3F" />
    <path d="M -38 -36 C -10 -12, -10 12, -38 36" stroke="#F4F7E6" strokeWidth={6} fill="none" />
    <path d="M 38 -36 C 10 -12, 10 12, 38 36" stroke="#F4F7E6" strokeWidth={6} fill="none" />
  </svg>
);
const Intro: React.FC = () => {
  const frame = useCurrentFrame();
  const phase = (frame % BEAT) / BEAT;
  const h = Math.sin(Math.PI * phase); // 0 on every beat = ball hits the ground
  const beat = Math.floor(frame / BEAT);
  const word = beat >= 2 ? hype.intro.words[Math.min(hype.intro.words.length - 1, Math.floor(beat / 2) - 1)] : null;
  const wordStart = f(Math.floor(beat / 2) * 2);
  const slam = useSlam(wordStart);
  const x = interpolate(frame, [0, f(8)], [-600, 600]);
  const squash = 1 - 0.25 * pulse(frame);
  return (
    <AbsoluteFill>
      <div style={{ position: 'absolute', left: 960 + x - 55, top: 860 - 230 * h - 110, transform: `scale(${1 / squash}, ${squash})`, transformOrigin: 'bottom' }}>
        <Ball spin={frame * 6} />
      </div>
      <div style={{ position: 'absolute', left: 960 + x - 60 * (1 - h * 0.6), top: 862, width: 120 * (1 - h * 0.6), height: 16, borderRadius: '50%', background: 'rgba(0,0,0,0.6)', boxShadow: `0 0 ${30 * pulse(frame)}px ${colors.accent}` }} />
      <div style={{ position: 'absolute', left: 0, right: 0, top: 862, height: 2, background: colors.track }} />
      {word && <Center style={{ paddingBottom: 420 }}><Big key={word} size={190} style={slam}>{word}</Big></Center>}
    </AbsoluteFill>
  );
};

// ---------- 2. Racket: four angles, hard cut every 2 beats ----------
const ANGLES: { cam: V3; target: V3; fov: number; rot: V3; drift: V3 }[] = [
  { cam: [0.75, 1.55, 1.15], target: [0.15, 1.25, 0], fov: 22, rot: [0.1, 1.3, -0.16], drift: [0, -0.2, 0] }, // macro along the hoop
  { cam: [0.45, -1.05, 0.55], target: [0, -1.4, -0.36], fov: 30, rot: [0.25, 0.6, 0], drift: [-0.25, 0, 0] }, // lime ring on the butt cap
  { cam: [0.5, -0.2, 2.2], target: [0, -0.2, 0], fov: 30, rot: [0.1, 0.5, 0], drift: [0, 0.15, 0] }, // throat
  { cam: [0, 0.1, 6.1], target: [0, 0.05, 0], fov: 32, rot: [0.1, 0.35, -0.12], drift: [0, 0, -0.4] }, // hero
];
const RacketCuts: React.FC = () => {
  const frame = useCurrentFrame();
  const i = Math.min(ANGLES.length - 1, Math.floor(frame / f(2)));
  const a = ANGLES[i];
  const t = (frame - f(i * 2)) / f(2);
  const cam: V3 = [a.cam[0] + a.drift[0] * t, a.cam[1] + a.drift[1] * t, a.cam[2] + a.drift[2] * t];
  const slam = useSlam(f(6));
  return (
    <AbsoluteFill>
      <Stage3D camera={cam} target={a.target} fov={a.fov} env="studio" envIntensity={1.4} hero>
        <pointLight position={[0.4, 2.2, -1.8]} intensity={40} distance={8} color="#ffffff" />
        <Racket rotation={[a.rot[0], a.rot[1] + (i === 3 ? t * 0.5 : t * 0.12), a.rot[2]]} glow={0.6 + 0.4 * pulse(frame)} />
      </Stage3D>
      <Center style={{ justifyContent: 'flex-end', paddingBottom: 90 }}>
        <Big size={120} style={slam}>{hype.racket.line}</Big>
      </Center>
    </AbsoluteFill>
  );
};

// ---------- 3. Stats: one slam per 2 beats ----------
const Stat: React.FC<{ item: (typeof hype.stats.items)[number] }> = ({ item }) => {
  const frame = useCurrentFrame();
  const slam = useSlam(0);
  const count = 'value' in item ? Math.round((item.value ?? 0) * Math.min(1, frame / (BEAT * 0.6))) : 0;
  const spike = Array.from({ length: 120 }, (_, k) => {
    const x = k / 119, after = x - 0.5;
    const y = after >= 0 ? Math.exp(-after * 18) * Math.cos(after * 140) : 0;
    return `${k ? 'L' : 'M'}${x * 1920},${540 - y * 260 * pulse(frame, 2)}`;
  }).join(' ');
  return (
    <AbsoluteFill>
      <svg width={1920} height={1080} style={{ position: 'absolute', opacity: 0.35 }}>
        <path d={spike} stroke={colors.accent} strokeWidth={4} fill="none" />
      </svg>
      <Center>
        <div style={slam}>
          {'value' in item ? (
            <Big size={330} color={colors.accent}>{count}<span style={{ fontSize: 110, color: colors.text, marginLeft: 20 }}>{item.unit}</span></Big>
          ) : (
            <Big size={210} color={colors.accent}>{item.text}</Big>
          )}
          <Small style={{ fontSize: 52, marginTop: 14 }}>{item.label}</Small>
        </div>
      </Center>
    </AbsoluteFill>
  );
};

// ---------- 4. Features: 2 beats each ----------
const MiniScore: React.FC = () => {
  const frame = useCurrentFrame();
  const pts = frame < f(1) ? '30' : '40';
  return (
    <div style={{ width: 560, borderRadius: 18, overflow: 'hidden', background: `${colors.score}cc`, fontFamily: fonts.sans, fontWeight: 700, fontSize: 48 }}>
      {[['YOU', 3, pts], ['OPP', 2, '15']].map(([n, g, p]) => (
        <div key={n} style={{ display: 'flex', alignItems: 'center', height: 96, borderBottom: '1px solid rgba(255,255,255,0.25)' }}>
          <div style={{ flex: 1, paddingLeft: 30 }}>{n}</div>
          <div style={{ width: 90, color: colors.accent, textAlign: 'center' }}>{g}</div>
          <div style={{ width: 130, height: '100%', background: '#f3f5ec', color: '#7a3d2c', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>{p}</div>
        </div>
      ))}
    </div>
  );
};
const Friends: React.FC = () => (
  <div style={{ display: 'flex', gap: 24 }}>
    {[['YOU', 74, true], ['SAM', 70, false]].map(([n, v, win]) => (
      <div key={String(n)} style={{ width: 250, padding: 26, borderRadius: 22, background: colors.card, border: `2px solid ${win ? colors.accent : colors.track}`, fontFamily: fonts.sans }}>
        <div style={{ fontSize: 30, color: colors.muted }}>{n}</div>
        <div style={{ fontFamily: fonts.display, fontSize: 96, fontWeight: 800, color: win ? colors.accent : colors.text }}>{v}</div>
        <div style={{ fontSize: 24, color: colors.muted }}>top mph</div>
      </div>
    ))}
  </div>
);
const Feature: React.FC<{ item: (typeof hype.features.items)[number] }> = ({ item }) => {
  const frame = useCurrentFrame();
  const slam = useSlam(0);
  const rise = spring({ frame: frame - 3, fps: FPS, config: { damping: 14 } });
  const visual = { score: <MiniScore />, watch: <Watch />, glasses: <Glasses />, friends: <Friends /> }[item.visual];
  return (
    <AbsoluteFill style={{ flexDirection: 'row', alignItems: 'center', padding: '0 120px', gap: 60 }}>
      <div style={{ flex: 1, ...slam, transformOrigin: 'left center' }}>
        <Big size={150}>{item.title}</Big>
        <Small style={{ marginTop: 18 }}>{item.sub}</Small>
      </div>
      <div style={{ opacity: rise, transform: `translateY(${(1 - rise) * 80}px) scale(${item.visual === 'glasses' ? 1.32 : 1.25})` }}>{visual}</div>
    </AbsoluteFill>
  );
};

// ---------- 5. Muse Spark what-if ----------
const WhatIf: React.FC = () => {
  const frame = useCurrentFrame();
  const w = hype.whatIf;
  const answer = useSlam(f(4));
  const by = interpolate(frame, [f(5), f(5) + 8], [0, 1], { extrapolateLeft: 'clamp', extrapolateRight: 'clamp' });
  return (
    <AbsoluteFill>
      {frame < f(4) ? (
        <Center style={{ flexDirection: 'column' }}>
          {w.question.map((q, i) => (frame >= f(i) ? <Big key={q} size={160} color={i === 2 ? colors.accent : colors.text}>{q}</Big> : null))}
        </Center>
      ) : (
        <Center style={{ flexDirection: 'column', gap: 30 }}>
          <div style={{ display: 'flex', alignItems: 'baseline', gap: 50, ...answer }}>
            <Big size={200} color={colors.muted} style={{ textDecoration: 'line-through', textDecorationThickness: 12 }}>{w.before}</Big>
            <Big size={140} color={colors.muted}>→</Big>
            <Big size={330} color={colors.accent}>{w.after}</Big>
            <Big size={110}>{w.unit}</Big>
          </div>
          <Small style={{ opacity: by, fontSize: 46 }}><span style={{ color: colors.accent }}>✦ </span>{w.by}</Small>
        </Center>
      )}
    </AbsoluteFill>
  );
};

// ---------- 6. Finale ----------
const Finale: React.FC = () => {
  const frame = useCurrentFrame();
  const fin = hype.finale;
  const name = useSlam(0);
  const appear = (b: number) => ({ opacity: interpolate(frame, [f(b), f(b) + 6], [0, 1], { extrapolateLeft: 'clamp', extrapolateRight: 'clamp' }) });
  return (
    <AbsoluteFill>
      <Stage3D camera={[0, 0.1, 6.1]} target={[0, 0.05, 0]} fov={32} env="studio" envIntensity={1.4} hero>
        <pointLight position={[-0.6, 2.2, -1.8]} intensity={40} distance={8} color="#ffffff" />
        <Racket position={[-1.25, 0, 0]} rotation={[0.1, 0.3 + frame * 0.006, -0.16]} glow={0.5 + 0.5 * pulse(frame)} />
      </Stage3D>
      <AbsoluteFill style={{ justifyContent: 'center', paddingLeft: 900, gap: 18 }}>
        <Big size={150} style={{ ...name, transformOrigin: 'left center' }}>{fin.name}</Big>
        <div style={{ ...appear(2), fontFamily: fonts.sans, fontSize: 52, color: colors.text }}>{fin.line}</div>
        <Small style={{ ...appear(4), color: colors.muted }}><span style={{ color: colors.accent }}>✦ </span>{fin.by}</Small>
        <div style={{ ...appear(6), alignSelf: 'flex-start', marginTop: 20, padding: '14px 30px', borderRadius: 40, background: colors.accent, color: '#11130c', fontFamily: fonts.sans, fontWeight: 700, fontSize: 38 }}>{fin.cta}</div>
      </AbsoluteFill>
    </AbsoluteFill>
  );
};

// ---------- finish: grain, downbeat flash, music ----------
const Grain: React.FC = () => {
  const frame = useCurrentFrame();
  return (
    <svg width={1920} height={1080} style={{ position: 'absolute', inset: 0, opacity: 0.09, mixBlendMode: 'overlay', pointerEvents: 'none' }}>
      <filter id="grain"><feTurbulence type="fractalNoise" baseFrequency={0.9} numOctaves={2} seed={frame % 12} /></filter>
      <rect width="100%" height="100%" filter="url(#grain)" />
    </svg>
  );
};
const SECTION_STARTS = [hype.racket.at[0], hype.stats.at[0], hype.features.at[0], hype.whatIf.at[0], hype.finale.at[0]];
const Flash: React.FC = () => {
  const frame = useCurrentFrame();
  const strong = SECTION_STARTS.some((b) => frame >= f(b) && frame < f(b) + 8) ? 0.3 : 0;
  const o = Math.max(strong * pulse(frame, 4), 0.06 * pulse(frame, 4));
  return <AbsoluteFill style={{ background: colors.accent, opacity: o, mixBlendMode: 'screen', pointerEvents: 'none' }} />;
};

export const Hype: React.FC = () => {
  const { durationInFrames } = useVideoConfig();
  const s = hype.song;
  const songStart = s.firstDownbeat + ((s.startBar - 1) * 4 * 60) / s.bpm;
  return (
    <AbsoluteFill style={{ background: colors.bg, color: colors.text, fontFamily: fonts.sans, overflow: 'hidden' }}>
      <AbsoluteFill style={{ background: `radial-gradient(ellipse 70% 60% at 50% 50%, rgba(221,232,91,0.10), rgba(11,12,9,0) 65%)` }} />
      <Shot at={hype.intro.at}><Intro /></Shot>
      <Shot at={hype.racket.at}><RacketCuts /></Shot>
      {hype.stats.items.map((item, i) => (
        <Shot key={i} at={[hype.stats.at[0] + i * 2, hype.stats.at[0] + i * 2 + 2]}><Stat item={item} /></Shot>
      ))}
      {hype.features.items.map((item, i) => (
        <Shot key={i} at={[hype.features.at[0] + i * 2, hype.features.at[0] + i * 2 + 2]}><Feature item={item} /></Shot>
      ))}
      <Shot at={hype.whatIf.at}><WhatIf /></Shot>
      <Shot at={hype.finale.at}><Finale /></Shot>
      <Flash />
      <Grain />
      <Audio
        src={staticFile(s.src)}
        trimBefore={Math.round(songStart * FPS)}
        volume={(fr) => s.volume * interpolate(fr, [durationInFrames - 45, durationInFrames], [1, 0], { extrapolateLeft: 'clamp', extrapolateRight: 'clamp' })}
      />
      {hypeCues.map((c, i) => <Effect key={i} cue={{ ...c, at: 0 }} frame={f(c.beat)} />)}
    </AbsoluteFill>
  );
};

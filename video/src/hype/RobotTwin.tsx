// The Demo's robot-arm beat: real arm, digital twin, real data, cut to the bars of the Demo's own song (no voiceover).
// Every cut lands on the song's beat grid, worked out from where this entry falls in the timeline.
import React from 'react';
import { AbsoluteFill, Easing, Sequence, interpolate, useCurrentFrame } from 'remotion';
import { Effect } from '../components/Timeline';
import { Stage3D } from '../components/Stage3D';
import { colors, fonts } from '../config/brand';
import { copy } from '../config/copy';
import { gyroTrace } from '../config/gyro-trace';
import { demo, demoTransition } from '../config/timeline';
import { RobotArm } from '../scenes/RobotLab';
import { Big, Center, Grain, useSlam } from './Hype';
import { BACK, PANEL_W, THROUGH, TRACE_PEAKS, Trace } from './RobotHype';
import { Brackets, Clip, FPS, Flash, GRADE, SHADOW, Shade, Vignette, clamp, inOut, mix, type V3, whipIn, whipOut } from './kit';

const c = copy.robotTwin;
const BEAT = (FPS * 60) / 95; // "Keep It Movin'": 95 BPM. The Demo starts on the first downbeat, so beat n is at n * BEAT.
const OVERLAP = Math.round(demoTransition * FPS);

const startFrame = () => {
  let t = 0;
  for (const e of demo) {
    if ('scene' in e && e.scene === 'robotTwin') return Math.round(t * FPS);
    t += e.seconds - demoTransition;
  }
  return 0;
};
const START = startFrame();
const FIRST = Math.ceil((START + OVERLAP - 1) / BEAT); // the first beat after the crossfade
/** Local frame of beat `b` of this scene. */
const at = (b: number) => Math.round((FIRST + b) * BEAT) - START;

const CUES: { sfx: 'tap' | 'whoosh' | 'impact' | 'boom' | 'servo' | 'blip'; beat: number; volume: number }[] = [
  { sfx: 'tap', beat: 0, volume: 0.5 }, { sfx: 'tap', beat: 2, volume: 0.5 }, { sfx: 'tap', beat: 4, volume: 0.5 },
  { sfx: 'servo', beat: 6, volume: 0.5 }, { sfx: 'whoosh', beat: 7.6, volume: 0.45 },
  { sfx: 'boom', beat: 8, volume: 0.4 }, { sfx: 'impact', beat: 12, volume: 0.9 },
  { sfx: 'whoosh', beat: 13.7, volume: 0.3 }, { sfx: 'blip', beat: 14, volume: 0.4 }, { sfx: 'blip', beat: 16, volume: 0.4 },
  { sfx: 'impact', beat: 18, volume: 0.7 },
];

const Word: React.FC<{ clip: string; word: string; accent?: boolean; len: number }> = ({ clip, word, accent, len }) => {
  const slam = useSlam(0);
  return (
    <AbsoluteFill>
      <Clip name={clip} len={len} zoom={[1.1, 1]} ease={Easing.out(Easing.cubic)} />
      <Shade />
      <Center><Big size={word.length > 10 ? 190 : 230} color={accent ? colors.accent : colors.text} style={{ ...slam, textShadow: SHADOW }}>{word}</Big></Center>
    </AbsoluteFill>
  );
};

// The racket CAD lies along scene Z at x ~ -2.4: seen from -X, handle to the left and head to the right, as in the real shot.
const CAM = { from: [-5.6, 1.9, 0.4] as V3, to: [-4.9, 1.6, -0.2] as V3, target: [-2.0, 1.25, -0.2] as V3 };
const Twin: React.FC = () => {
  const frame = useCurrentFrame();
  const b = (beat: number) => at(beat) - at(8);
  const contact = b(12), end = b(14);
  const scan = interpolate(frame, [b(8.25), b(9.75)], [0, 1], { ...clamp, easing: inOut });
  const angle = frame < contact - 6
    ? interpolate(frame, [0, contact - 6], [0, BACK], { ...clamp, easing: inOut })
    : BACK + (THROUGH - BACK) * (0.5 + 0.5 * Math.tanh((frame - contact + 1) / 2.2) / Math.tanh(3));
  const cam = mix(CAM.from, CAM.to, interpolate(frame, [0, end], [0, 1], clamp));
  const shake = frame >= contact && frame < contact + 8 ? Math.sin(frame * 7.3) * 12 * (1 - (frame - contact) / 8) : 0;
  const name = useSlam(b(10));
  return (
    <AbsoluteFill style={{ ...whipIn(frame, 0), ...whipOut(frame, end), transform: `translate(${shake}px, ${-shake / 2}px)` }}>
      <Clip name="rt-wide" len={end} zoom={[1, 1.2]} origin="60% 45%" blur={20} />
      <AbsoluteFill style={{ background: 'rgba(11,12,9,0.55)' }} />
      <AbsoluteFill style={{ filter: `${GRADE} blur(0.5px)` }}>
        <Stage3D camera={cam} target={CAM.target} fov={40} rim="#ffe9c9" envIntensity={0.75}>
          <RobotArm angle={angle} grid={false} racket="blue" racketGlow={Math.max(0, 1 - Math.abs(frame - contact) / 6)} />
        </Stage3D>
      </AbsoluteFill>
      <AbsoluteFill style={{ clipPath: `inset(0 ${(1 - scan) * 100}% 0 0)`, background: 'repeating-linear-gradient(0deg, rgba(221,232,91,0.07) 0 2px, transparent 2px 5px)', mixBlendMode: 'screen' }} />
      {scan > 0 && scan < 1 && <div style={{ position: 'absolute', top: 0, bottom: 0, left: scan * 1920 - 2, width: 4, background: colors.accent, boxShadow: `0 0 30px 8px ${colors.accent}` }} />}
      <div style={{ position: 'absolute', left: 110, top: 100, fontFamily: fonts.mono, fontSize: 26, letterSpacing: 3, color: colors.accent }}>{c.cgiLabel}</div>
      <AbsoluteFill style={{ justifyContent: 'flex-end', alignItems: 'flex-end', padding: '0 110px 90px 0', gap: 18 }}>
        <div style={{ display: 'flex', gap: 14 }}>
          {c.tags.map((tag, i) => {
            const o = interpolate(frame, [b(10) + i * 4, b(10) + 6 + i * 4], [0, 1], clamp);
            return <div key={tag} style={{ opacity: o, transform: `translateY(${(1 - o) * 20}px)`, fontFamily: fonts.mono, fontSize: 26, letterSpacing: 2, color: colors.accent, border: `1.5px solid ${colors.accent}`, padding: '6px 14px', borderRadius: 999, background: 'rgba(11,12,9,0.5)' }}>{tag}</div>;
          })}
        </div>
        {frame >= b(10) - 3 && <Big size={150} color={colors.accent} style={{ ...name, transformOrigin: 'right center', textShadow: SHADOW }}>{c.twin}</Big>}
      </AbsoluteFill>
      <Flash at={contact} len={8} peak={0.55} />
    </AbsoluteFill>
  );
};

const Proof: React.FC = () => {
  const frame = useCurrentFrame();
  const len = at(18) - at(14);
  const progress = frame / len;
  const toFrame = (i: number) => (i / (gyroTrace.length - 1)) * len;
  let angle = BACK;
  TRACE_PEAKS.forEach((pk, k) => {
    const s = 0.5 + 0.5 * Math.tanh((frame - toFrame(pk)) / 2.5);
    angle += (k % 2 ? BACK - THROUGH : THROUGH - BACK) * s;
  });
  const hit = Math.max(0, ...TRACE_PEAKS.map((pk) => 1 - Math.abs(frame - toFrame(pk)) / 6));
  const line = frame < at(16) - at(14) ? 0 : 1;
  const slam = useSlam(line ? at(16) - at(14) : 0);
  const label: React.CSSProperties = { fontFamily: fonts.mono, fontSize: 24, letterSpacing: 3, color: colors.accent, background: 'rgba(11,12,9,0.6)', padding: '6px 14px', borderRadius: 6 };
  return (
    <AbsoluteFill style={{ background: colors.bg }}>
      <div style={{ position: 'absolute', left: 420, top: 60, width: 1920, height: 1080 }}>
        <Stage3D camera={[-1.2 + Math.sin(-0.95 + progress * 0.3) * 6.4, 1.4, 0.3 + Math.cos(-0.95 + progress * 0.3) * 6.4]} target={[-1.2, 0.25, 0.3]} fov={38} rim="#ffe9c9" envIntensity={0.75}>
          <RobotArm angle={angle} grid={false} racket="blue" racketGlow={hit} />
        </Stage3D>
      </div>
      <div style={{ position: 'absolute', left: 0, top: 0, width: PANEL_W, height: 1080, overflow: 'hidden', boxShadow: '20px 0 60px rgba(0,0,0,0.6)' }}>
        <Clip name="rh-panel" len={len} zoom={[1, 1.06]} />
        <div style={{ position: 'absolute', left: 30, top: 30, ...label }}>REAL</div>
      </div>
      <div style={{ position: 'absolute', left: PANEL_W + 40, top: 30, ...label }}>DIGITAL TWIN</div>
      <div style={{ position: 'absolute', left: PANEL_W + 90, right: 90, top: 90, textAlign: 'right' }}>
        <Big key={line} size={118} style={{ ...slam, transformOrigin: 'right center', textShadow: SHADOW }}>{c.proof[line]}</Big>
      </div>
      <div style={{ position: 'absolute', left: PANEL_W + 90, right: 90, bottom: 70 }}>
        <div style={{ fontFamily: fonts.mono, fontSize: 22, letterSpacing: 3, color: colors.muted, marginBottom: 12 }}>{c.trace}</div>
        <Trace progress={progress} width={1920 - PANEL_W - 180} height={170} />
      </div>
    </AbsoluteFill>
  );
};

const Truth: React.FC<{ len: number }> = ({ len }) => {
  const slam = useSlam(0);
  return (
    <AbsoluteFill>
      <Clip name="rt-wide" len={len} zoom={[1.15, 1]} ease={Easing.out(Easing.cubic)} />
      <AbsoluteFill style={{ background: 'rgba(11,12,9,0.45)' }} />
      <Brackets />
      <Center style={{ flexDirection: 'column', gap: 22 }}>
        <Big size={210} color={colors.accent} style={{ ...slam, textShadow: SHADOW }}>{c.truth}</Big>
        <div style={{ ...slam, fontFamily: fonts.sans, fontSize: 46, fontWeight: 600, color: colors.text, textShadow: SHADOW }}>{c.truthLine}</div>
      </Center>
    </AbsoluteFill>
  );
};

export const RobotTwin: React.FC = () => {
  const frame = useCurrentFrame();
  const shots = c.shots;
  return (
    <AbsoluteFill style={{ background: colors.bg, color: colors.text, fontFamily: fonts.sans, overflow: 'hidden' }}>
      {shots.map((s, i) => {
        const from = i ? at(i * 2) : 0;
        const len = at((i + 1) * 2) - from;
        return <Sequence key={s.clip} from={from} durationInFrames={len}><Word clip={s.clip} word={s.word} accent={s.accent} len={len} /></Sequence>;
      })}
      <Sequence from={at(6)} durationInFrames={at(8) - at(6)}>
        <AbsoluteFill style={whipOut(frame - at(6), at(8) - at(6))}>
          <Clip name="rt-swing" len={at(8) - at(6)} zoom={[1, 1.08]} />
          <div style={{ position: 'absolute', left: 110, top: 100, fontFamily: fonts.mono, fontSize: 26, letterSpacing: 3, color: colors.text }}>{c.realLabel}</div>
        </AbsoluteFill>
      </Sequence>
      <Sequence from={at(8)} durationInFrames={at(14) - at(8)}><Twin /></Sequence>
      <Sequence from={at(14)} durationInFrames={at(18) - at(14)}><Proof /></Sequence>
      <Sequence from={at(18)}><Truth len={at(20) - at(18) + OVERLAP} /></Sequence>
      <Vignette />
      <Grain />
      {CUES.map((q, i) => <Effect key={i} cue={{ sfx: q.sfx, volume: q.volume, at: 0 }} frame={at(q.beat)} />)}
    </AbsoluteFill>
  );
};

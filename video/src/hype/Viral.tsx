// The sub-minute X cut. No voiceover: type and the song carry it, hard cuts on the bar, and two people's own words near the end.
// The real serve beside the app is the star, so it comes straight after the hook, on the drop.
import React from 'react';
import { AbsoluteFill, Audio, OffthreadVideo, Sequence, interpolate, staticFile, useCurrentFrame } from 'remotion';
import { Effect } from '../components/Timeline';
import { Backdrop } from '../components/ui';
import { colors, fonts } from '../config/brand';
import type { Cue } from '../config/sound';
import { viral as v } from '../config/viral';
import { Devices } from '../scenes/Devices';
import { Endcard } from '../scenes/Endcard';
import { GlassesPov } from '../scenes/GlassesPov';
import { InsideHandle } from '../scenes/InsideHandle';
import { SamTrack } from '../scenes/SamTrack';
import { SwingFilmScene } from '../scenes/SwingFilmScene';
import { Big, Grain, useSlam } from './Hype';
import { TwinShot } from './RobotTwin';
import { Clip, Flash, GRADE, SHADOW, Vignette, beatClock, clamp, makeDuck } from './kit';

const { f } = beatClock(v.song.bpm);
const BAR_S = (4 * 60) / v.song.bpm;
export const viralFrames = f(v.bars * 4);
/** First frame of a bar, counted from 1. */
const bar = (n: number) => f((n - 1) * 4);

const At: React.FC<{ n: number; bars?: number; children: React.ReactNode }> = ({ n, bars = 1, children }) => (
  <Sequence from={bar(n)} durationInFrames={bar(n + bars) - bar(n)}>{children}</Sequence>
);

/** Big type low in the frame, over a dark fade, so it reads on a phone without covering the action. */
const Line: React.FC<{ text: string; accent?: boolean; size?: number; still?: boolean; at?: number }> = ({ text, accent, size = 128, still, at = 0 }) => {
  const frame = useCurrentFrame();
  const slam = useSlam(at);
  if (frame < at) return null;
  return (
    <AbsoluteFill style={{ justifyContent: 'flex-end', alignItems: 'center', textAlign: 'center', padding: '0 60px 76px', background: 'linear-gradient(0deg, rgba(5,6,3,0.82), rgba(5,6,3,0) 46%)' }}>
      <Big size={size} color={accent ? colors.accent : colors.text} style={{ ...(still ? {} : slam), textShadow: SHADOW }}>{text}</Big>
    </AbsoluteFill>
  );
};
const Badge: React.FC<{ text: string; top?: number; left?: number; right?: number }> = ({ text, ...at }) => (
  <div style={{ position: 'absolute', ...at, fontFamily: fonts.sans, fontWeight: 700, fontSize: 32, color: '#11130c', background: colors.accent, padding: '8px 22px', borderRadius: 999 }}>{text}</div>
);

// ---------- The hook: true slow motion, and the contact on the drop ----------
const Hook: React.FC<{ len: number }> = ({ len }) => (
  <AbsoluteFill>
    <Clip name="vx-hook" len={len} zoom={[1, 1.1]} origin="50% 35%" />
    <Sequence durationInFrames={f(4)}><Line text={v.hook[0]} size={150} still /></Sequence>
    <Sequence from={f(4)}><Line text={v.hook[1]} size={134} accent /></Sequence>
  </AbsoluteFill>
);

// ---------- The real serve beside the app ----------
const TwinBar: React.FC<{ i: number }> = ({ i }) => {
  const frame = useCurrentFrame();
  const t = v.twin[i];
  const contact = f(2);
  const hit = frame >= contact ? Math.exp(-(frame - contact) / 7) : 0;
  const slam = useSlam(0);
  const chip: React.CSSProperties = { position: 'absolute', top: 28, fontFamily: fonts.mono, fontSize: 32, fontWeight: 700, letterSpacing: 2, padding: '8px 18px', borderRadius: 8 };
  return (
    <AbsoluteFill style={{ background: colors.bg }}>
      <div style={{ position: 'absolute', left: 0, top: 0, width: 1180, height: 1080, overflow: 'hidden' }}>
        <OffthreadVideo muted src={staticFile(`footage/vx-twin-cam-${i}.mp4`)} style={{ width: '100%', height: '100%', objectFit: 'cover', filter: GRADE }} />
        <div style={{ ...chip, left: 28, color: colors.text, background: 'rgba(11,12,9,0.72)' }}>{v.twinLabels.court}</div>
        <div style={{ ...chip, right: 28, color: '#11130c', background: colors.accent }}>{t.chip}</div>
      </div>
      <div style={{ position: 'absolute', left: 1180, top: 0, width: 740, height: 682, overflow: 'hidden', background: '#000', boxShadow: `0 0 ${hit * 70}px rgba(221,232,91,${hit * 0.8})`, borderBottom: `4px solid ${hit > 0.02 ? colors.accent : colors.track}`, borderLeft: `4px solid ${hit > 0.02 ? colors.accent : colors.track}` }}>
        <OffthreadVideo muted src={staticFile(`footage/vx-twin-app-${i}.mp4`)} style={{ width: '100%', height: '100%', objectFit: 'cover' }} />
        <div style={{ ...chip, top: 18, right: 22, fontSize: 26, color: colors.accent, background: 'rgba(0,0,0,0.75)' }}>{v.twinLabels.app}</div>
      </div>
      <AbsoluteFill style={{ left: 1214, top: 682, width: 672, height: 398, justifyContent: 'center' }}>
        <Big size={92} style={{ ...slam, transformOrigin: 'left center' }}>{t.title}</Big>
      </AbsoluteFill>
    </AbsoluteFill>
  );
};

// ---------- Inside and behind it ----------
const Build: React.FC = () => (
  <AbsoluteFill>
    {v.build.clips.map((name, i) => (
      <Sequence key={name} from={f(i)} durationInFrames={f(i + 1) - f(i)}><Clip name={name} len={f(1)} zoom={[1.14, 1]} /></Sequence>
    ))}
    <Line text={v.build.title} size={136} />
  </AbsoluteFill>
);

const Robot: React.FC = () => (
  <AbsoluteFill>
    <Sequence durationInFrames={f(2)}>
      <Clip name="rt-arm" len={f(2)} zoom={[1.12, 1]} />
      <Line text={v.robot[0]} size={170} />
    </Sequence>
    <Sequence from={f(2)}>
      <Clip name="rt-swing" len={f(2)} zoom={[1, 1.1]} />
      <Line text={v.robot[1]} size={170} accent />
    </Sequence>
  </AbsoluteFill>
);

// ---------- Muse ----------
const Phone: React.FC<{ clip: string }> = ({ clip }) => (
  <div style={{ position: 'absolute', left: 100, top: 40, width: 536, height: 1000, borderRadius: 70, background: '#000', border: '12px solid #2b2d27', overflow: 'hidden', boxShadow: '0 30px 120px rgba(0,0,0,0.7)' }}>
    <OffthreadVideo muted src={staticFile(`footage/${clip}.mp4`)} style={{ width: '100%', height: '100%', objectFit: 'cover' }} />
  </div>
);
const PhoneBar: React.FC<{ clip: string; kicker?: string; title: string; second?: string; stat?: string; badge?: string; size?: number }> = ({ clip, kicker, title, second, stat, badge, size = 118 }) => {
  const slam = useSlam(0);
  const late = useSlam(f(2));
  return (
    <Backdrop glow={0.14}>
      <Phone clip={clip} />
      <AbsoluteFill style={{ left: 730, width: 1130, justifyContent: 'center', gap: 34 }}>
        {kicker && <div style={{ ...slam, fontFamily: fonts.mono, fontSize: 40, letterSpacing: 5, color: colors.accent, transformOrigin: 'left center' }}>{kicker}</div>}
        <Big size={size} style={{ ...slam, transformOrigin: 'left center' }}>{title}</Big>
        {second && <Big size={size} color={colors.accent} style={{ ...late, transformOrigin: 'left center' }}>{second}</Big>}
        {stat && <div style={{ ...late, fontFamily: fonts.sans, fontWeight: 700, fontSize: 56, color: colors.better, transformOrigin: 'left center' }}>{stat}</div>}
      </AbsoluteFill>
      {badge && <div style={{ position: 'absolute', left: 730, bottom: 44, fontFamily: fonts.sans, fontWeight: 600, fontSize: 30, color: colors.muted }}>{badge}</div>}
    </Backdrop>
  );
};

// ---------- Their words ----------
const Person: React.FC<{ p: (typeof v.people)[number] }> = ({ p }) => (
  <AbsoluteFill>
    <OffthreadVideo src={staticFile(`footage/${p.clip}.mp4`)} style={{ width: '100%', height: '100%', objectFit: 'cover', filter: GRADE }} />
    <div style={{ position: 'absolute', left: 60, top: 54, fontFamily: fonts.sans, background: 'rgba(11,12,9,0.82)', borderLeft: `8px solid ${colors.accent}`, padding: '14px 30px', borderRadius: '0 14px 14px 0' }}>
      <div style={{ fontSize: 46, fontWeight: 700, color: colors.text }}>{p.name}</div>
      {p.detail && <div style={{ fontSize: 32, color: colors.muted }}>{p.detail}</div>}
    </div>
    <Line text={p.line} size={86} still />
  </AbsoluteFill>
);

const CUES: (Omit<Cue, 'at'> & { beat: number })[] = [
  { sfx: 'riser', beat: 8, volume: 0.35 }, { sfx: 'whoosh', beat: 7.7, volume: 0.3 }, { sfx: 'impact', beat: 8, volume: 1 },
  { sfx: 'impact', beat: 10, volume: 0.8 }, { sfx: 'impact', beat: 14, volume: 0.8 }, { sfx: 'impact', beat: 18, volume: 0.8 },
  { sfx: 'boom', beat: 20, volume: 0.4 },
  ...[24, 25, 26, 27].map((beat) => ({ sfx: 'tap' as const, beat, volume: 0.6 })),
  { sfx: 'servo', beat: 28, volume: 0.45 }, { sfx: 'whoosh', beat: 31.7, volume: 0.35 }, { sfx: 'impact', beat: 34, volume: 0.9 },
  { sfx: 'swipe', beat: 36, volume: 0.5 }, { sfx: 'ping', beat: 37, volume: 0.5 }, { sfx: 'ping', beat: 38, volume: 0.5 },
  { sfx: 'impact', beat: 41.3, volume: 0.7 }, { sfx: 'ping', beat: 41.7, volume: 0.45 },
  { sfx: 'swipe', beat: 44, volume: 0.5 }, { sfx: 'blip', beat: 46, volume: 0.4 }, { sfx: 'swipe', beat: 48, volume: 0.5 }, { sfx: 'blip', beat: 50, volume: 0.4 },
  { sfx: 'whoosh', beat: 52, volume: 0.3 }, { sfx: 'tap', beat: 56.8, volume: 0.8 }, { sfx: 'impact', beat: 60, volume: 0.6 },
  { sfx: 'swipe', beat: 72, volume: 0.5 }, { sfx: 'boom', beat: 76, volume: 0.45 }, { sfx: 'chime', beat: 76.8, volume: 0.5 },
];
const duck = makeDuck(CUES, f);

export const Viral: React.FC = () => {
  const s = v.song;
  const start = s.firstDownbeat + (s.startBar - 1) * BAR_S;
  const end = viralFrames;
  const talk = [bar(17), bar(19)];
  return (
    <AbsoluteFill style={{ background: colors.bg, color: colors.text, fontFamily: fonts.sans, overflow: 'hidden' }}>
      <At n={1} bars={2}><Hook len={bar(3)} /></At>
      {[3, 4, 5].map((n, i) => <At key={n} n={n}><TwinBar i={i} /></At>)}
      <At n={6}>
        <Sequence from={-110}><InsideHandle /></Sequence>
        <div style={{ position: 'absolute', left: 60, top: 44, fontFamily: fonts.mono, fontSize: 26, letterSpacing: 3, color: colors.accent }}>{v.handle.label}</div>
        <Line text={v.handle.title} size={118} />
      </At>
      <At n={7}><Build /></At>
      <At n={8}><Robot /></At>
      <At n={9}><TwinShot contact={f(2)} end={f(4)} nameAt={0} scan={[0, f(1.5)]} /></At>
      <At n={10}>
        <Sequence from={-40}><Devices /></Sequence>
        <Badge text={v.devices.badge} top={88} right={60} />
        <Line text={v.devices.title} size={116} />
      </At>
      <At n={11}>
        <Sequence from={-20}><GlassesPov /></Sequence>
        <Line text={v.glasses.title} size={112} />
      </At>
      <At n={12}><PhoneBar clip="vx-muse-a" kicker={v.muse.kicker} title={v.muse.first} badge={v.muse.badge} /></At>
      <At n={13}><PhoneBar clip="vx-muse-b" kicker={v.muse.kicker} title={v.muse.second} stat={v.muse.stat} badge={v.muse.badge} /></At>
      <At n={14}>
        <Sequence from={-150}><SwingFilmScene /></Sequence>
        <Badge text={v.muse.filmBadge} top={28} left={420} />
        <Line text={v.muse.third} size={130} accent />
      </At>
      <At n={15}><Clip name="vx-score" len={f(4)} zoom={[1, 1.06]} /><Line text={v.score.title} size={112} /></At>
      <At n={16}>
        <Sequence from={-60}><SamTrack /></Sequence>
        <Line text={v.sam.title} size={108} />
      </At>
      <At n={17}><Person p={v.people[0]} /></At>
      <At n={18}><Person p={v.people[1]} /></At>
      <At n={19}><PhoneBar clip="vx-sim" title={v.cta.first} second={v.cta.second} stat={v.cta.url} size={112} /></At>
      <At n={20} bars={2}><Endcard /></At>
      <Flash at={f(8)} len={8} peak={0.8} />
      <Vignette strength={0.3} />
      <Grain />
      <Audio
        src={staticFile(s.src)}
        trimBefore={Math.round(start * 30)}
        volume={(fr) => {
          const down = interpolate(fr, [talk[0] - 4, talk[0] + 2, talk[1] - 2, talk[1] + 6], [1, 0.1, 0.1, 1], clamp);
          return s.volume * duck(fr) * down * interpolate(fr, [end - 45, end - 3], [1, 0], clamp);
        }}
      />
      {CUES.map((c, i) => <Effect key={i} cue={{ ...c, at: 0 }} frame={f(c.beat)} />)}
    </AbsoluteFill>
  );
};


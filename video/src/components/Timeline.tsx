import { TransitionSeries, linearTiming } from '@remotion/transitions';
import { fade } from '@remotion/transitions/fade';
import React from 'react';
import { AbsoluteFill, Audio, Sequence, interpolate, staticFile, useVideoConfig } from 'remotion';
import { video } from '../config/brand';
import { cues, effects, sound, type Cue } from '../config/sound';
import type { Cut, Entry } from '../config/timeline';
import { voSeconds } from '../config/voiceover';
import { scenes, type SceneId } from '../scenes';
import { FootageSlot } from './FootageSlot';
import { OverlayLayer } from './Overlays';
import { VoiceoverTrack, voFile } from './Voiceover';

const fps = video.fps;

/**
 * Frame length of each entry. Rounded from cumulative time, not per entry, so a
 * long run of beat-length scenes never drifts off the music.
 */
const lengths = (cut: Cut) => {
  let t = 0;
  return cut.entries.map((e, i) => {
    const start = Math.round(t * fps);
    t += e.seconds - (i < cut.entries.length - 1 ? cut.transition : 0);
    const end = Math.round(t * fps) + (i < cut.entries.length - 1 ? Math.round(cut.transition * fps) : 0);
    return end - start;
  });
};
const overlap = (cut: Cut) => Math.round(cut.transition * fps);

/** Total length after crossfades overlap. Root.tsx uses it for durationInFrames. */
export const cutFrames = (cut: Cut) => lengths(cut).reduce((n, l) => n + l, 0) - overlap(cut) * (cut.entries.length - 1);

/** The name a line of voiceover uses for an entry: its scene or footage id. */
const entryId = (e: Entry) => ('scene' in e ? e.scene : e.footage);

/** First frame of each entry in the finished cut. */
const startFrames = (cut: Cut) => {
  const len = lengths(cut);
  const starts = new Map<string, number>();
  cut.entries.reduce((at, e, i) => {
    starts.set(entryId(e), at);
    return at + len[i] - overlap(cut);
  }, 0);
  return starts;
};

/** One sound effect, placed so its hit point lands on `frame`. */
export const Effect: React.FC<{ cue: Cue; frame: number }> = ({ cue, frame }) => {
  const fx = effects[cue.sfx];
  const [from, to] = 'trim' in fx ? fx.trim : [0, undefined];
  const start = frame - Math.round((fx.hit - from) * fps);
  return (
    <Sequence from={start} layout="none">
      <Audio
        src={staticFile(fx.src)}
        trimBefore={Math.max(0, Math.round(from * fps) - Math.min(0, start))}
        trimAfter={to === undefined ? undefined : Math.round(to * fps)}
        volume={cue.volume ?? 1}
      />
    </Sequence>
  );
};

/** A CGI scene plus its sound cues from config/sound.ts, optionally started `skip` frames in. */
export const SceneWithSound: React.FC<{ id: SceneId; skip?: number; children?: React.ReactNode }> = ({ id, skip = 0, children }) => {
  const Scene = scenes[id];
  const { durationInFrames } = useVideoConfig();
  return (
    <AbsoluteFill>
      <Sequence from={-skip}>
        <Scene />
      </Sequence>
      {cues[id].map((c, i) => <Effect key={i} cue={c} frame={c.fromEnd ? durationInFrames - c.at : c.at - skip} />)}
      {children}
    </AbsoluteFill>
  );
};

/** Music bed: ducks under talking footage, fades out at the end. */
const Music: React.FC<{ cut: Cut }> = ({ cut }) => {
  const { durationInFrames } = useVideoConfig();
  const len = lengths(cut);
  const talk: [number, number][] = [];
  const lifted: [number, number, number][] = [];
  cut.entries.reduce((at, e, i) => {
    if ('footage' in e && e.muted === false) talk.push([at, at + len[i]]);
    if ('scene' in e && e.musicVolume) lifted.push([at, at + len[i], e.musicVolume]);
    return at + len[i] - overlap(cut);
  }, 0);
  // Only recorded lines duck the music: a caption alone makes no sound to clear.
  const starts = startFrames(cut);
  const spoken = (cut.voiceover ?? []).filter((l) => voFile(l.id) && starts.has(l.at)).map((l) => {
    const from = starts.get(l.at)! + Math.round((l.lead ?? 0.3) * fps);
    return [from, from + Math.round(voSeconds(l) * fps)];
  });
  const base = cut.music.volume ?? 0.5;
  const volumeAt = (f: number) => {
    const ducked = talk.some(([a, b]) => f >= a - 10 && f <= b + 10);
    const underVo = spoken.some(([a, b]) => f >= a - 10 && f <= b + 10);
    const fade = interpolate(f, [durationInFrames - sound.musicFadeOut * fps, durationInFrames], [1, 0], { extrapolateLeft: 'clamp', extrapolateRight: 'clamp' });
    const lift = lifted.reduce((v, [a, b, to]) => Math.max(v, interpolate(f, [a, a + 8, b - 8, b], [base, to, to, base], { extrapolateLeft: 'clamp', extrapolateRight: 'clamp' })), base);
    return (ducked ? sound.musicUnderTalk : underVo ? sound.musicUnderVoiceover : lift) * fade;
  };
  const from = Math.round((cut.music.from ?? 0) * fps);
  const src = staticFile(cut.music.src);
  const { jump } = cut.music;
  if (!jump) return <Audio src={src} trimBefore={from} loop volume={volumeAt} />; // loops if the cut outlasts the song
  const first = Math.round(jump.at * fps) - from;
  return (
    <>
      <Sequence durationInFrames={first} layout="none"><Audio src={src} trimBefore={from} volume={volumeAt} /></Sequence>
      <Sequence from={first} layout="none"><Audio src={src} trimBefore={Math.round(jump.to * fps)} volume={(f) => volumeAt(f + first)} /></Sequence>
    </>
  );
};

/** Plays a cut: CGI scenes and footage slots, crossfades (or hard cuts), music and effects. */
export const Timeline: React.FC<{ cut: Cut }> = ({ cut }) => {
  const len = lengths(cut);
  return (
    <AbsoluteFill>
      <TransitionSeries>
        {cut.entries.flatMap((e: Entry, i) => {
          const items = [
            <TransitionSeries.Sequence key={`s${i}`} durationInFrames={len[i]}>
              {'scene' in e ? (
                <SceneWithSound id={e.scene} skip={e.skip}>{e.overlays && <OverlayLayer overlays={e.overlays} />}</SceneWithSound>
              ) : (
                <FootageSlot entry={e} />
              )}
            </TransitionSeries.Sequence>,
          ];
          if (i < cut.entries.length - 1 && overlap(cut) > 0)
            items.push(<TransitionSeries.Transition key={`t${i}`} presentation={fade()} timing={linearTiming({ durationInFrames: overlap(cut) })} />);
          return items;
        })}
      </TransitionSeries>
      <Music cut={cut} />
      {cut.voiceover && <VoiceoverTrack lines={cut.voiceover} starts={startFrames(cut)} fps={fps} />}
    </AbsoluteFill>
  );
};

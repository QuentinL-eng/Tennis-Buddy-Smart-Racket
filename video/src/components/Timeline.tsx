import { TransitionSeries, linearTiming } from '@remotion/transitions';
import { fade } from '@remotion/transitions/fade';
import React from 'react';
import { video } from '../config/brand';
import { transitionSeconds, type Entry } from '../config/timeline';
import { scenes } from '../scenes';
import { FootageSlot } from './FootageSlot';

const frames = (s: number) => Math.round(s * video.fps);

/** Total length after crossfades overlap. Root.tsx uses it for durationInFrames. */
export const timelineFrames = (entries: Entry[]) =>
  entries.reduce((n, e) => n + frames(e.seconds), 0) - frames(transitionSeconds) * (entries.length - 1);

/** Plays a list of CGI scenes and footage slots with crossfades between them. */
export const Timeline: React.FC<{ entries: Entry[] }> = ({ entries }) => (
  <TransitionSeries>
    {entries.flatMap((e, i) => {
      const Scene = 'scene' in e ? scenes[e.scene] : null;
      const items = [
        <TransitionSeries.Sequence key={`s${i}`} durationInFrames={frames(e.seconds)}>
          {Scene ? <Scene /> : <FootageSlot entry={e as Extract<Entry, { footage: string }>} />}
        </TransitionSeries.Sequence>,
      ];
      if (i < entries.length - 1 && transitionSeconds > 0)
        items.push(<TransitionSeries.Transition key={`t${i}`} presentation={fade()} timing={linearTiming({ durationInFrames: frames(transitionSeconds) })} />);
      return items;
    })}
  </TransitionSeries>
);

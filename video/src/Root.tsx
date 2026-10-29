import { loadFont as loadDisplay } from '@remotion/google-fonts/BricolageGrotesque';
import { loadFont as loadSans } from '@remotion/google-fonts/DMSans';
import React from 'react';
import { Composition, Folder } from 'remotion';
import { SceneWithSound, Timeline, cutFrames } from './components/Timeline';
import { video } from './config/brand';
import { cuts, reveal, type Cut } from './config/timeline';
import { scenes, type SceneId } from './scenes';
import { RacketSheet } from './scenes/dev/RacketSheet';
import { Hype, hypeFrames } from './hype/Hype';

// Only the weights the scenes use; loading every variant slows each render.
loadDisplay('normal', { weights: ['700', '800'], subsets: ['latin'] });
loadSans('normal', { weights: ['400', '600', '700'], subsets: ['latin'] });

const CutComp: React.FC<{ cut: Cut }> = ({ cut }) => <Timeline cut={cut} />;

export const RemotionRoot: React.FC = () => (
  <>
    {/* One composition per cut in config/timeline.ts: Reveal, RevealSong, Demo */}
    {Object.entries(cuts).map(([id, cut]) => (
      <Composition key={id} id={id} component={CutComp} defaultProps={{ cut }} durationInFrames={cutFrames(cut)} {...video} />
    ))}
    {/* 30 s X hype clip cut to "Keep It Movin'" (src/hype/Hype.tsx, copy in config/hype.ts) */}
    <Composition id="Hype" component={Hype} durationInFrames={hypeFrames} {...video} />
    {/* Each scene on its own, for quick iteration in the studio. */}
    <Folder name="Scenes">
      {(Object.keys(scenes) as SceneId[]).map((id) => {
        const seconds = reveal.find((e) => 'scene' in e && e.scene === id)?.seconds ?? 6;
        return <Composition key={id} id={`scene-${id}`} component={SceneWithSound} defaultProps={{ id }} durationInFrames={Math.round(seconds * video.fps)} {...video} />;
      })}
    </Folder>
    <Folder name="Dev">
      <Composition id="racket-sheet" component={RacketSheet} durationInFrames={4} {...video} />
    </Folder>
  </>
);

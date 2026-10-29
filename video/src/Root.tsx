import { loadFont as loadDisplay } from '@remotion/google-fonts/BricolageGrotesque';
import { loadFont as loadSans } from '@remotion/google-fonts/DMSans';
import React from 'react';
import { Composition, Folder } from 'remotion';
import { Timeline, timelineFrames } from './components/Timeline';
import { video } from './config/brand';
import { demo, reveal, type Entry } from './config/timeline';
import { scenes, type SceneId } from './scenes';

// Only the weights the scenes use; loading every variant slows each render.
loadDisplay('normal', { weights: ['700', '800'], subsets: ['latin'] });
loadSans('normal', { weights: ['400', '600', '700'], subsets: ['latin'] });

const TimelineComp: React.FC<{ entries: Entry[] }> = ({ entries }) => <Timeline entries={entries} />;

export const RemotionRoot: React.FC = () => (
  <>
    <Composition id="Reveal" component={TimelineComp} defaultProps={{ entries: reveal }} durationInFrames={timelineFrames(reveal)} {...video} />
    <Composition id="Demo" component={TimelineComp} defaultProps={{ entries: demo }} durationInFrames={timelineFrames(demo)} {...video} />
    {/* Each scene on its own, for quick iteration in the studio. */}
    <Folder name="Scenes">
      {(Object.keys(scenes) as SceneId[]).map((id) => {
        const seconds = reveal.find((e) => 'scene' in e && e.scene === id)?.seconds ?? 6;
        return <Composition key={id} id={`scene-${id}`} component={scenes[id]} durationInFrames={Math.round(seconds * video.fps)} {...video} />;
      })}
    </Folder>
  </>
);

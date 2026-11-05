import { loadFont as loadDisplay } from '@remotion/google-fonts/BricolageGrotesque';
import { loadFont as loadSans } from '@remotion/google-fonts/DMSans';
import React from 'react';
import { Composition, Folder } from 'remotion';
import { SceneWithSound, Timeline, cutFrames } from './components/Timeline';
import { video } from './config/brand';
import { OverlayLayer } from './components/Overlays';
import { cuts, demo, reveal, type Cut } from './config/timeline';
import { scenes, type SceneId } from './scenes';
import { RacketSheet, VIEWS } from './scenes/dev/RacketSheet';
import { Hype, hypeFrames } from './hype/Hype';
import { RobotHype, robotHypeFrames } from './hype/RobotHype';
import { BuildLog, buildLogFrames } from './hype/BuildLog';
import { EverySwing, everySwingFrames } from './hype/EverySwing';
import { Possessed, possessedFrames } from './hype/Possessed';
import { Viral, viralFrames } from './hype/Viral';
import { SwingFilm, type FilmScript } from './swingfilm/SwingFilm';
import { FILM } from './swingfilm/look';
import swingFilm from './config/swingFilm.json';

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
    <Composition id="Viral" component={Viral} durationInFrames={viralFrames} {...video} />
    <Composition id="Hype" component={Hype} durationInFrames={hypeFrames} {...video} />
    {/* ~27 s X clip: robot-arm session footage + CGI, cut to "Ten" (src/hype/RobotHype.tsx, copy in config/robotHype.ts) */}
    <Composition id="RobotHype" component={RobotHype} durationInFrames={robotHypeFrames} {...video} />
    {/* ~26 s X clip: the build as a six-step how-to, bench + robot + court footage + CGI, on "Comin Wit It" */}
    <Composition id="BuildLog" component={BuildLog} durationInFrames={buildLogFrames} {...video} />
    {/* ~29 s X clip: on court under a HUD, a CGI swing, the app, "Be better." on "Not My First Rodeo" */}
    <Composition id="EverySwing" component={EverySwing} durationInFrames={everySwingFrames} {...video} />
    {/* ~27 s Halloween X clip: "this racket is possessed... by an AI", on "Whoop" */}
    <Composition id="Possessed" component={Possessed} durationInFrames={possessedFrames} {...video} />
    {/* 8 s swing film: Muse Spark's recommended change on the player's own swing (docs/SWING_FILM.md) */}
    <Composition id="SwingFilm" component={SwingFilm} defaultProps={{ script: swingFilm as FilmScript }} durationInFrames={FILM.frames} {...video} />
    {/* Each scene on its own, for quick iteration in the studio. */}
    <Folder name="Scenes">
      {(Object.keys(scenes) as SceneId[]).map((id) => {
        const seconds = [...demo, ...reveal].find((e) => 'scene' in e && e.scene === id)?.seconds ?? 6;
        return <Composition key={id} id={`scene-${id}`} component={SceneWithSound} defaultProps={{ id }} durationInFrames={Math.round(seconds * video.fps)} {...video} />;
      })}
    </Folder>
    {/* Each entry's overlays on transparent, for an outside editor: scripts/render-clips.mjs */}
    <Folder name="Overlays">
      {demo.filter((e) => e.overlays).map((e) => {
        const id = 'scene' in e ? e.scene : e.footage;
        return <Composition key={id} id={`overlay-${id}`} component={OverlayLayer} defaultProps={{ overlays: e.overlays! }} durationInFrames={Math.round(e.seconds * video.fps)} {...video} />;
      })}
    </Folder>
    <Folder name="Dev">
      <Composition id="racket-sheet" component={RacketSheet} durationInFrames={VIEWS.length} {...video} />
    </Folder>
  </>
);

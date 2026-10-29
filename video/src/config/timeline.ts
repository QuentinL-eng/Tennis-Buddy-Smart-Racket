// The order and length of every beat. Edit these lists to re-cut the videos.
//
// An entry is either:
//   { scene: '<id>', seconds }                  CGI scene from src/scenes
//   { footage: '<id>', seconds, file?, ... }    real footage slot
//
// Footage: drop the clip in public/footage/ and set `file`. Until then a
// placeholder card shows the shot notes, so the cut is watchable today.
// `from` trims the start of the clip (seconds). `caption` is burned in at the bottom.

import type { SceneId } from '../scenes';

export type SceneEntry = { scene: SceneId; seconds: number };
export type FootageEntry = {
  footage: string;
  seconds: number;
  file?: string;
  from?: number;
  muted?: boolean;
  caption?: string;
  shot: string; // what to film, shown on the placeholder
};
export type Entry = SceneEntry | FootageEntry;

// Crossfade between beats, in seconds. Set to 0 for hard cuts.
export const transitionSeconds = 0.4;

// Optional: turn on once ShotSimulator returns launch angle/flight.
export const features = { showBallFlight: false };

// ~60 s CGI-only reveal: the X/LinkedIn post and the opening of the demo.
export const reveal: Entry[] = [
  { scene: 'hook', seconds: 3.5 },
  { scene: 'racketReveal', seconds: 6 },
  { scene: 'insideHandle', seconds: 9 },
  { scene: 'impact', seconds: 6.5 },
  { scene: 'robotLab', seconds: 8 },
  { scene: 'devices', seconds: 7 },
  { scene: 'score', seconds: 5.5 },
  { scene: 'whatIf', seconds: 11 },
  { scene: 'together', seconds: 5.5 },
  { scene: 'endcard', seconds: 5 },
];

// The 3:00 hackathon submission. CGI beats intercut with real footage.
export const demo: Entry[] = [
  { footage: 'club-rally', seconds: 5, caption: 'Tuesday night at the club.',
    shot: 'Wide, low angle behind the baseline. A fast rally, golden light if possible. No talking.' },
  { scene: 'hook', seconds: 3.5 },
  { scene: 'racketReveal', seconds: 5.5 },
  { footage: 'intro-to-camera', seconds: 12, muted: false,
    caption: 'I built a smart racket and the app around it during the hackathon.',
    shot: 'You to camera on court, racket in hand. One sentence on the problem, one on what you built this week.' },
  { scene: 'insideHandle', seconds: 9 },
  { footage: 'build-montage', seconds: 8, caption: 'Custom board, printed insert, firmware.',
    shot: 'Macro cuts, 1 s each: soldering, insert in hand, closing the handle, flashing firmware, Onshape CAD.' },
  { scene: 'robotLab', seconds: 7 },
  { footage: 'robot-arm', seconds: 7, caption: 'Robot arm test rig for labelled swings.',
    shot: 'The Epson C8 swinging the racket. If it is not running yet, record the Epson simulator and the TennisRobot sim run.' },
  { scene: 'impact', seconds: 6 },
  { footage: 'live-session', seconds: 12, caption: 'Every shot lands on your phone, watch and glasses.',
    shot: 'Split: player hitting forehands / phone Live screen updating. Real shots, real numbers.' },
  { scene: 'devices', seconds: 6 },
  { footage: 'glasses-pov', seconds: 7, caption: 'Meta Ray-Ban Display: stats and score in view.',
    shot: 'Through-the-lens POV or over-shoulder of the HUD while rallying.' },
  { scene: 'score', seconds: 5 },
  { footage: 'match-scoring', seconds: 9, caption: 'Two taps on the handle: point to you.',
    shot: 'Close-up of thumb tapping the handle between points, cut to the score updating on the watch.' },
  { scene: 'whatIf', seconds: 10 },
  { footage: 'muse-screen-recording', seconds: 18, caption: 'Muse Spark runs the what-if on your own shots, then plans a drill.',
    shot: 'Screen recording (iPhone): ask a what-if, the simulate_change result, then "Plan my next drill".' },
  { footage: 'drill-on-court', seconds: 9, caption: 'The drill runs on the watch and counts itself.',
    shot: 'Player doing the drill, watch close-up counting down "to go", ending on "Drill complete!".' },
  { scene: 'together', seconds: 5 },
  { footage: 'testimonials', seconds: 19, muted: false, caption: 'First test at the club.',
    shot: '3-4 players, 5 s each, best line only. Ask "What did it tell you that you did not know?"' },
  { footage: 'built-this-week', seconds: 9, caption: 'Built during the hackathon: insert, firmware, app, Muse tools, robot rig.',
    shot: 'Screen capture: git log / repo tree scrolling, highlighted new folders. Required by the rules.' },
  { scene: 'endcard', seconds: 5 },
];

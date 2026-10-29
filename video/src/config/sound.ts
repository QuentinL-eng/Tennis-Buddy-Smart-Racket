// Music and sound effects. Files live in public/audio/ (credits: public/audio/CREDITS.md).
import type { SceneId } from '../scenes';

export type Music = { src: string; /** seconds into the file where the video starts */ from?: number; volume?: number };

/** Default music bed for the Reveal and Demo cuts (the song cut sets its own). */
export const music: Music = { src: 'audio/keep-it-movin.mp3', from: 0.386, volume: 0.55 };

export const sound = {
  /** Music level while a footage slot with `muted: false` plays (people talking). */
  musicUnderTalk: 0.12,
  /** Fade the music out over the last N seconds. */
  musicFadeOut: 3,
};

/**
 * Each effect: file, `hit` = seconds into the file where its key moment is (the
 * transient, the peak of a riser), optional `trim` [start, end] seconds to use.
 * Cues place the hit exactly on their frame.
 */
export const effects = {
  impact: { src: 'audio/sfx/impact.mp3', hit: 0.05, trim: [0, 0.9] },
  whoosh: { src: 'audio/sfx/whoosh.mp3', hit: 0.36 },
  riser: { src: 'audio/sfx/riser.mp3', hit: 3.42, trim: [0.6, 3.6] },
  boom: { src: 'audio/sfx/boom.mp3', hit: 0.45, trim: [0, 4] },
  tap: { src: 'audio/sfx/tap.mp3', hit: 0.92, trim: [0.9, 1.15] },
  blip: { src: 'audio/sfx/blip.mp3', hit: 0.06, trim: [0, 0.6] },
  ping: { src: 'audio/sfx/ping.mp3', hit: 0.08 },
  servo: { src: 'audio/sfx/servo.mp3', hit: 0.42, trim: [0.4, 2.1] },
  chime: { src: 'audio/sfx/chime.mp3', hit: 0.03 },
  swipe: { src: 'audio/sfx/swipe.mp3', hit: 0.05 },
} satisfies Record<string, { src: string; hit: number; trim?: number[] }>;

export type Effect = keyof typeof effects;
/** `at` = frame within the scene where the effect's hit lands (or before the scene's end, with fromEnd). */
export type Cue = { sfx: Effect; at: number; volume?: number; fromEnd?: boolean };

// Each scene's sound cues, timed to that scene's animation (frames at 30 fps).
export const cues: Record<SceneId, Cue[]> = {
  hook: [{ sfx: 'riser', at: 0, fromEnd: true, volume: 0.7 }], // peaks on the cut into the reveal
  racketReveal: [{ sfx: 'whoosh', at: 10, volume: 0.6 }, { sfx: 'whoosh', at: 55, volume: 0.4 }, { sfx: 'boom', at: 100 }],
  insideHandle: [{ sfx: 'whoosh', at: 50, volume: 0.6 }, ...[105, 141, 177, 213].map((at) => ({ sfx: 'blip' as const, at, volume: 0.4 }))],
  impact: [{ sfx: 'whoosh', at: 45, volume: 0.4 }, { sfx: 'impact', at: 60 }, { sfx: 'blip', at: 90, volume: 0.4 }],
  robotLab: [{ sfx: 'servo', at: 40, volume: 0.5 }, { sfx: 'impact', at: 76, volume: 0.8 }, { sfx: 'servo', at: 135, volume: 0.5 }, { sfx: 'impact', at: 171, volume: 0.8 }],
  devices: [38, 50, 62].map((at) => ({ sfx: 'ping' as const, at, volume: 0.5 })),
  score: [36, 44, 100, 108].map((at) => ({ sfx: 'tap' as const, at })),
  whatIf: [
    { sfx: 'blip', at: 20, volume: 0.4 }, { sfx: 'swipe', at: 55, volume: 0.6 }, { sfx: 'blip', at: 90, volume: 0.4 },
    { sfx: 'tap', at: 200 }, { sfx: 'chime', at: 214, volume: 0.6 },
  ],
  together: [{ sfx: 'blip', at: 26, volume: 0.4 }, { sfx: 'blip', at: 34, volume: 0.4 }],
  endcard: [{ sfx: 'boom', at: 4, volume: 0.8 }, { sfx: 'chime', at: 24, volume: 0.5 }],
};

// The 30-second X hype clip: every word, number and beat position lives here.
// Timing is in BEATS (95 BPM → one beat = 0.632 s). 48 beats = 12 bars ≈ 30.3 s.
import type { Cue } from './sound.ts';

export const hype = {
  // "Keep It Movin'" from bar 9 (where it lifts) to the end of bar 20.
  song: { src: 'audio/keep-it-movin.mp3', bpm: 95, firstDownbeat: 0.386, startBar: 9, volume: 0.9 },
  beats: 48,

  // Sections: [start beat, end beat]
  intro: { at: [0, 8], words: ['EVERY SHOT.', 'EVERY SWING.', 'EVERY POINT.'] }, // ball bounces on each beat
  racket: { at: [8, 16], line: 'TENNIS. BUT SMART.' }, // four 3D angles, one per 2 beats
  stats: {
    at: [16, 24], // one stat per 2 beats (sample numbers: swap in real ones)
    items: [
      { value: 68, unit: 'MPH', label: 'ball speed' },
      { value: 1840, unit: 'RPM', label: 'topspin' },
      { value: 74, unit: 'MPH', label: 'swing speed' },
      { text: 'SWEET SPOT', label: 'every contact point, located' },
    ],
  },
  features: {
    at: [24, 32],
    items: [
      { title: 'KEEPS SCORE', sub: 'tap the handle', visual: 'score' },
      { title: 'ON YOUR WATCH', sub: 'every shot, live', visual: 'watch' },
      { title: 'ON YOUR GLASSES', sub: 'Meta Ray-Ban Display', visual: 'glasses' },
      { title: 'BEAT YOUR FRIENDS', sub: 'compare every session', visual: 'friends' },
    ] as const,
  },
  whatIf: { at: [32, 40], question: ['WHAT IF', 'YOU SWUNG', '5% FASTER?'], before: 61, after: 67, unit: 'MPH', by: 'Predicted by Muse Spark' },
  finale: { at: [40, 48], name: 'TENNIS BUDDEE', line: 'Your racket just got smart.', by: 'Built with Muse Spark', cta: 'Coming soon' },
};

/** Sound effects on beats (`at` here is a beat number, converted to frames in Hype.tsx). */
export const hypeCues: (Omit<Cue, 'at'> & { beat: number })[] = [
  { sfx: 'whoosh', beat: 8, volume: 0.5 },
  ...[16, 18, 20].map((beat) => ({ sfx: 'impact' as const, beat, volume: 0.9 })),
  { sfx: 'chime', beat: 22, volume: 0.4 },
  { sfx: 'tap', beat: 24.5 }, { sfx: 'tap', beat: 25 },
  ...[26, 28, 30].map((beat) => ({ sfx: 'blip' as const, beat, volume: 0.4 })),
  { sfx: 'swipe', beat: 32, volume: 0.5 },
  { sfx: 'impact', beat: 36, volume: 0.9 },
  { sfx: 'boom', beat: 40, volume: 0.8 },
];

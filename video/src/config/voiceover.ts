// Every spoken line in the Demo, and its burned-in caption. Rewrite a line here and the caption follows.
//
// - `at`: the entry in timeline.ts it starts on (a scene id or footage id), so a line moves with its shot.
// - `lead`: seconds after that entry starts. Default 0.3.
// - Record a line: save it as public/audio/vo/<id>.wav (or .mp3, .m4a). It plays on its own and the music ducks.
// - `seconds`: how long the line runs, for captions and ducking. Default: from the word count.
//   `npm run check` warns when a line would run into the next one.
//
// Say "smart racket" and "predicts". The hackathon's anti-project list bans the other words (see ../../README.md).

export type VoLine = { id: string; at: string; lead?: number; seconds?: number; captionOnly?: boolean; text: string };

/** Comfortable reading pace, words per second. */
export const WORDS_PER_SECOND = 2.6;
export const voSeconds = (l: VoLine) => l.seconds ?? l.text.split(/\s+/).length / WORDS_PER_SECOND;

export const voiceover: VoLine[] = [
  { id: 'open', at: 'cold-open', lead: 0.6, seconds: 3.9, text: 'There are hundreds of hits per match, but which ones are good, and where can you improve?' },
  { id: 'reveal', at: 'racketReveal', lead: 1.2, seconds: 2.7, text: 'This is Tennis Buddee, a smart racket that feels every shot.' },
  // On camera and in the interviews the sound is in the clip: these lines are captions only.
  { id: 'talk', at: 'talk-intro', lead: 0.2, seconds: 11.7, captionOnly: true, text: 'I\'m Quentin Lynch, and I built Tennis Buddee, the smartest racket that you will ever use. Tennis Buddee can hear and feel every shot you take, while Meta\'s AI works in the background to improve your game.' },
  { id: 'hardware', at: 'insideHandle', seconds: 12.2, text: 'A sensor insert replaces the foam in the handle: a thousand samples a second, up to 320 g, and a microphone that hears where the ball hit the strings, not just when. It computes every single shot itself on the racket.' },
  // The on-racket model is ridge regression (firmware/src/sweetspot.cpp). Don't call it a neural net until one ships.
  { id: 'models', at: 'twoModels', seconds: 7.6, text: 'On the racket, my own machine learning model runs on the ESP32. In the app, Meta\'s open Muse Spark is served by Baseten to the user.' },
  { id: 'evidence', at: 'evidence', seconds: 7.4, text: 'The firmware matches Python on every clip, distance error stays under two centimeters, and Muse passes a strict test 88 percent of the time.' },
  { id: 'everywhere', at: 'devices', seconds: 7.1, text: 'Every shot lands on your phone, your Apple Watch, and Meta Ray-Ban Display, through the Meta Wearables toolkit, in a UI that you can read at a glance.' },
  { id: 'agent', at: 'museAgent', seconds: 10.2, text: 'Muse Spark isn\'t a chat box here. It\'s an agent with ten tools, over your shots and the live racket. Every number it reports has to come from a tool.' },
  { id: 'whatif', at: 'whatIf', seconds: 7.5, text: 'Ask Muse what if, and it runs a physics simulation on your average stroke, and predicts what the change does to the speed and the spin.' },
  { id: 'drill', at: 'muse-screen-recording', lead: 12.3, seconds: 2.9, text: 'Then it plans a drill, and your wearable device tracks it.' },
  { id: 'sam', at: 'samTrack', seconds: 7.9, text: 'SAM 3.1 tracks the racket through the real video, frame by frame, making sure that our machine learning models that we deliver to you are as accurate as possible.' },
  { id: 'film', at: 'swingFilm', seconds: 5.5, text: 'And Muse directs this swing film from the simulator\'s numbers, so it can\'t invent a swing.' },
  { id: 't1', at: 'testimonial-1', lead: 0.1, seconds: 9.4, captionOnly: true, text: 'The racket\'s super awesome. It helps my play a lot better. You know where my weaknesses are. It\'s super cheap. It costs about the same as one hour of lessons, but I can give you countless hours of feedback.' },
  { id: 't2', at: 'testimonial-2', lead: 0.1, seconds: 5, captionOnly: true, text: 'I love the Tennis Buddee. I take it with me everywhere. Tennis Buddee\'s got me ten times better.' },
  { id: 'end', at: 'endcard', lead: 0.6, seconds: 2.9, text: 'Try our online simulator, and you can feel like a tennis pro.' },
];

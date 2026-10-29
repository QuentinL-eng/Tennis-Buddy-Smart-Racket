# Tennis Buddee: reveal + demo video

Remotion project. Everything is real-time CGI rendered from the real CAD and app
UI, plus slots for real footage. No AI-generated video.

| Composition | Length | Use |
|---|---|---|
| `Reveal` | ~60 s | CGI only, crossfades |
| `RevealSong` | 1:08 | CGI only, hard cuts on the beat of "Keep It Movin'". The X post |
| `Demo` | 2:57 | Hackathon submission (limit 3:00). CGI + footage slots |
| `Scenes/scene-*` | each beat | Iterate on one scene at a time |

## Run

`RevealSong` and the hype cut need `public/audio/keep-it-movin.mp3`. It is licensed to the project owner and kept out of
this public repo (see `public/audio/CREDITS.md`), so copy it in locally before rendering them.

```bash
npm install
npm run studio          # live preview at http://localhost:3000
npm run render:reveal   # -> out/reveal.mp4
npm run render:song     # -> out/reveal-song.mp4
npm run render:demo     # -> out/demo.mp4
npm run timeline -- RevealSong   # timecodes (and bars) of any cut
npm run frames          # key frames of every scene -> out/review/
```

## Where to edit

You should almost never need to open a scene file.

| To change | Edit |
|---|---|
| Any on-screen text or number | `src/config/copy.ts` |
| Scene order, length, crossfade | `src/config/timeline.ts` (`reveal`, `demo`) |
| Add your filmed clips | drop in `public/footage/`, set `file:` on the slot in `src/config/timeline.ts` |
| Colours, fonts, resolution | `src/config/brand.ts` |
| Music, effect files, per-scene sound cues | `src/config/sound.ts` (credits in `public/audio/CREDITS.md`) |
| Cut to a new song | run `scripts/analyze-song.mjs` on it for BPM + first downbeat, then copy the `revealSong` pattern in `src/config/timeline.ts` (scene lengths in bars, `skip` to land key moments on beats) |
| Ball-flight arc in the what-if scene | `features.showBallFlight` in `src/config/timeline.ts` (only once ShotSimulator models flight) |

### Footage slots

```ts
{ footage: 'club-rally', seconds: 5, file: 'club-rally.mp4', from: 12.5, caption: '…', shot: '…' }
```

- `file`: name of the clip in `public/footage/`. Leave it out and the slot shows a placeholder with the shot notes.
- `from`: start the clip this many seconds in (trim).
- `muted: false`: keep the clip's audio (testimonials, talking to camera).
- `caption`: burned-in subtitle. Most viewers watch muted.

The `Demo` length is computed from the list. Keep the total under 3:00, which the studio timeline shows.

### CAD

The handle and robot arm come straight from Onshape STEP exports in `cad/`:

```bash
node scripts/step-to-json.mjs handle cad/handle.step
node scripts/step-to-json.mjs robot  cad/robot-arm.step
```

Part groups (what moves and gets labelled) are the regex rules at the top of
`scripts/step-to-json.mjs`. The app icon and court photo are copied in by
`npm run assets`, which runs before studio/render.

### The racket

`src/components/Racket.tsx` builds a generic, unbranded racket procedurally from real
dimensions (the `D` table at the top: head size, beam width/depth, throat arm path,
16x19 strings). The frame is a rounded tube swept along its centreline, like a moulded
carbon frame. Change colours/finish in the materials block there. To check the shape
after editing, render the model sheet (0 face-on, 1 side, 2 hero, 3 throat close-up):

```bash
npx remotion still racket-sheet out/review/sheet.png --frame=0
```

 The opening shot's camera moves
are the `SHOT` keyframes at the top of `src/scenes/RacketReveal.tsx`. Hero scenes pass
`hero` to `Stage3D` for 2x supersampling, bloom, filmic tone mapping and a vignette
(slower to render, so the other 3D scenes leave it off).

**Known gap:** the robot STEP has no `arm_1` (J1→J2 shoulder) link. `RobotLab.tsx`
draws a stand-in (a column on the J1 turret plus the J2 hub) until a re-export includes
it; it switches to the real part automatically then. J1/J2 positions are the constants
at the top of `RobotLab.tsx`, measured from the base turret and the arm_2 boss.

## Scene files

`src/scenes/*.tsx`, one per beat, registered in `src/scenes/index.ts`. 3D scenes use
`components/Stage3D.tsx` (shared lights/camera) and `lib/models.ts` (model loading).
Animation is driven by frame number only (no `Math.random`, no timers), so renders are deterministic.

## Copy rules

- Don't call it a coach or an analyzer: "Sports analyzers or coaches" is on the hackathon's anti-project list.
- Mirror real app strings (`copy.ts` notes the source file of each).

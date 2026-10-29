# Shoot plan: real footage for the 3:00 demo

The CGI shows *how it works*. The footage has to prove *it's real*: real players,
real shots, real numbers on real screens. Judges score Demo at 25% ("is the demo
video genuinely cool to watch?") and Impact at 30% ("could this actually become
something people use?"). The footage carries both.

## The 3:00 cut at a glance

Total **2:56**: 62 s of CGI (already built) and 123 s of real footage (13 clips).
Timecodes are where each beat starts in the final cut (`npm run timeline` prints them).
**Bold** rows are what you film.

| Time | | Beat | Length | On screen | Sound |
|---|---|---|---|---|---|
| 0:00 | **REAL** | **`club-rally`** | **5 s** | **Fast rally under the lights, wide and low behind the baseline** | **Court sound + music** |
| 0:04 | CGI | hook | 3.5 s | "Four hundred shots tonight. Which ones were good?" | Riser |
| 0:07 | CGI | racketReveal | 5.5 s | Macro glide along the frame → "Tennis Buddee" | Whoosh, boom |
| 0:12 | **REAL** | **`intro-to-camera`** | **12 s** | **You on court, racket in hand (script below)** | **Your voice, music ducks** |
| 0:24 | CGI | insideHandle | 9 s | Exploded view of your handle CAD, parts labelled | Whoosh, blips |
| 0:33 | **REAL** | **`build-montage`** | **8 s** | **1 s cuts: soldering, insert in hand, closing handle, flashing firmware, Onshape** | Music |
| 0:40 | CGI | robotLab | 7 s | C8 arm swinging the racket into balls | Servo, impacts |
| 0:47 | **REAL** | **`robot-arm`** | **7 s** | **The real arm, or the Epson RC+ simulator + TennisRobot sim run** | Music + servo sound |
| 0:53 | CGI | impact | 6 s | Ball hits strings, three sensor traces spike, shot card | Impact |
| 0:59 | **REAL** | **`live-session`** | **12 s** | **Player hitting forehands + the phone Live screen updating** | **Court sound + music** |
| 1:11 | CGI | devices | 6 s | Shot fans out to phone, watch, glasses | Pings |
| 1:16 | **REAL** | **`glasses-pov`** | **7 s** | **Through-the-lens HUD or over-the-shoulder** | Music |
| 1:23 | CGI | score | 5 s | "Score by tapping the handle" | Taps |
| 1:27 | **REAL** | **`match-scoring`** | **9 s** | **Thumb double-tapping the handle between points → watch score changes** | **Court sound** |
| 1:36 | CGI | whatIf | 10 s | Muse Spark `simulate_change` before/after → drill | Blips, chime |
| 1:45 | **REAL** | **`muse-screen-recording`** | **20 s** | **iPhone screen recording of the real what-if + "Plan my next drill"** | Music (or voiceover) |
| 2:05 | **REAL** | **`drill-on-court`** | **9 s** | **Doing the drill; watch counting "to go" → "Drill complete!"** | Court sound + music |
| 2:14 | CGI | together | 5 s | Play together, two players' stats | Blips |
| 2:18 | **REAL** | **`testimonials`** | **25 s** | **4–5 players, ~5 s each, best line only** | **Their voices, music ducks** |
| 2:43 | **REAL** | **`built-this-week`** | **9 s** | **Screen capture: git log / repo tree, new folders highlighted** | Music |
| 2:51 | CGI | endcard | 5 s | Logo, "Find the sweet spot." | Boom, chime, music out |

**Story arc:** the problem (0:00) → what I built (0:12–0:53) → it works on court
(0:59–1:36) → Muse Spark makes it smart (1:36–2:14) → people want it (2:14–2:43) →
proof it was built this week (2:43).

## Tonight at the club (in shooting order)

Shoot in this order so the light, battery and players' patience go furthest.

1. **`club-rally` (5 s in cut, film 2 min).** Before anyone's tired. Phone low on the
   fence behind the baseline, 4K 30. Also grab 240 fps slow-mo of the ball hitting the
   strings: the best spare shots for the X post.
2. **`live-session` (12 s, film 3 min).** One player hits forehands while the phone
   sits propped on the net post *in frame*, Live screen visible. If you have a second
   phone, also screen-record the Live screen so it can go side by side. Real numbers,
   real shots.
3. **`match-scoring` (9 s, film 5 takes).** Tight on the hand: thumb double-taps the
   handle after a point, then cut to the watch face updating. Make sure the watch is
   readable (brightness up, no glare).
4. **`drill-on-court` (9 s, film the whole drill).** Start a drill from the app (screen
   record that bit, step 6 needs it), then film the player doing it, with watch
   close-ups as the count drops and "Drill complete!" at the end.
5. **`glasses-pov` (7 s).** If the Ray-Ban Display HUD can be filmed through the lens,
   do 30 s of rallying. If not, skip it: the CGI devices scene covers it, and its 7 s
   go to testimonials.
6. **`muse-screen-recording` (20 s, record at the end or at home).** From tonight's real
   session: ask a what-if (e.g. "What if I hit 2 cm closer to the sweet spot and swing
   5% faster?"), let the `simulate_change` result show, then tap "Plan my next drill".
   Scroll slowly; the edit can speed it up.
7. **`testimonials` (25 s, 4–5 people).** Last, after they've used it. Quiet corner, mic
   close, racket in hand, court behind. Questions below.
8. **`intro-to-camera` (12 s).** You, on court, after everyone's gone. Script below.
   Do 5 takes.

## Later at a desk

- **`build-montage` (8 s):** macro clips of soldering, the insert, closing the handle,
  flashing firmware, and the Onshape assembly rotating. 1–2 s each.
- **`robot-arm` (7 s):** the real C8 swinging if you can; otherwise screen-record the
  Epson RC+ simulator running `racket_moves` and a TennisRobot sim run.
- **`built-this-week` (9 s, required by the rules):** screen capture of the public repo:
  scroll the git log and highlight what's new this week (firmware tap pipeline, Muse
  tools, ShotSimulator, Play together, robot rig, this video).

## Scripts and questions

**Intro (≈12 s, say it naturally):**
> "Every tennis player hits hundreds of shots a night and has no idea which ones were good.
> So this week I built a racket that feels every shot: a sensor insert in the handle,
> an app on phone, watch and glasses, and Muse Spark predicting what changing your swing will do."

**Testimonial questions (one at a time, use the best 5 s of each):**
1. "What did it tell you about your game that you didn't know?"
2. "Would you play with a friend on this, comparing sessions?"
3. "How did scoring by tapping the handle feel mid-match?"
4. "Would you use this?"

Note each person's name and level (e.g. "Sam, 3.5 club player") for captions, and get
consent on camera ("OK to use this in a public video?").

**Optional voiceover** for `muse-screen-recording` (record later, quiet room):
> "Muse Spark calls a simulator on my own shot data, predicts what the change will do
> to speed and spin, then builds a drill and sends it to my watch."

## Gear

- Phone on a gimbal or tripod. **4K 30 fps**; **120/240 fps** for impacts.
- Lav or phone-mounted mic for talking shots. Court audio is echoey.
- Second phone with **screen recording on**; watch paired; Ray-Ban Display if available.
- Everything charged. Tape and a marker for a quick calibration shot.

## Say this, not that

The hackathon lists **"Sports analyzers or coaches"** as an anti-project. Never use those
words on camera or in captions.

| Say | Don't say |
|---|---|
| smart racket, a racket that feels every shot | coach, AI coach, analyzer |
| Muse Spark **predicts** what a change will do | Muse tells you how to play |
| drills that track themselves | lessons, training plan |
| Strava for tennis / Play together | |

> Fix before filming the phone: the app still shows "Muse coach", "Ask coach about…"
> and "built-in coach". Rename them or those screens will contradict the video.

## Numbers to capture (they replace sample data in `src/config/copy.ts`)

- [ ] A good forehand: ball speed, spin, swing speed, sweet spot yes/no (`impact.*`)
- [ ] The what-if you asked Muse and its before/after (`whatIf.*`)
- [ ] The drill Muse planned and its target count (`whatIf.drill*`)
- [ ] Two players' session totals: shots, top ball speed, sweet spot % (`together.players`)

## After filming

1. Copy clips to `video/public/footage/`, named after the slot ids (e.g. `club-rally.mp4`).
2. In `src/config/timeline.ts`, set `file:` on each slot (and `from:` to trim the start).
3. Paste real numbers into `src/config/copy.ts`.
4. `npm run timeline` to check the length, `npm run studio` to watch, `npm run render:demo`.

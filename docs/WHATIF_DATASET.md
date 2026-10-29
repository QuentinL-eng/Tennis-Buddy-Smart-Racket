# "What if" coaching dataset for Muse Spark

Synthetic conversations that teach Muse to test a technique change instead of only describing a session. Muse
reads the digest, proposes a change ("close the face 3°, swing 5% slower"), calls `simulate_change`, and reports
the estimated result. Every tool result in the dataset is what the app would return, because the physics and tool
code are mirrored from Swift (`ml/coach_sim.py`, checked against `ShotSimulator.swift` output in the tests).

```bash
python3 ml/whatif_synth.py priors                     # real recordings -> ml/whatif_priors.json (needs the local data)
python3 ml/whatif_synth.py generate                   # -> data/whatif/ (400 players, seed 7, ~8 s)
python -m unittest discover -s ml -p test_whatif_synth.py
```

`ml/whatif_priors.json` is in git (summary numbers only, 8 KB), so `generate` works without the raw recordings.

## What the real data contributes

| Source | Quality | Used for |
|---|---|---|
| `data/phone/` TennisCamera sessions, Oct 28 (45 camera-confirmed hits, ~25% packet loss) | good | Racket speed at contact (median 120 km/h) and its shot-to-shot spread (CV 0.14) |
| `data/sessions/*/positions.csv`, 274 reviewed contacts | good | Shape of the contact cloud; the ridge model's 1.83 cm error for mic-only hits |
| `data/club-2026-10-28/` raw-stream CSVs (17% of the stream arrived) | bad | Rally cadence, per-recording BLE throughput, the gyro clipping in 8 of 11 recordings, 27 real swings (median 75 km/h) |

The club data can't measure strokes, but it does describe the conditions a coach has to cope with. Each synthetic
session gets club-like or phone-like link conditions. With a club-like link, a shot that comes before the previous
448-sample window has finished sending becomes a mic-only hit (21% of club-like shots, against 7% on a phone-like
link). With the gyro range bug, swings above 144 km/h are saturated. In 4% of sessions the motion stream never
comes up at all. In each case Muse has to say it can't simulate, rather than invent a baseline.

**Assumed, not measured:** swing path and face angle per stroke (no recording has orientation yet), the shot
mixes, and the injected technique flaws. The lab contacts were thrown across the face on purpose (median 4.8 cm
off), so on-court contact uses that shape scaled by 0.55–1.0. The result is 46% of motion shots in the sweet spot.

## Generated files (`data/whatif/`, git-ignored)

- `conversations_{train,val,test}.jsonl`: 2,164 examples split by player (80/10/10), in OpenAI chat format with
  `tools` (the same schemas as `CoachTools.schemas`). The first four messages are exactly what `MuseCoach` sends:
  system prompt, question prompt, the injected `get_session_digest` call, and its result. `metadata` holds the
  ground truth: the injected flaw, whether the chosen change addresses it (`flaw_found`, 78%), link conditions
  and units.
- `whatif_table.csv`: 80,920 simulated changes (baseline, deltas, before/after, whether each passes the
  guardrail and reaches the target, and which one was chosen). Use it for evals or to train a ranker.
- `shots.csv`, `sessions.csv`, `players.jsonl`: the synthetic shots, session conditions, and player truth.
- `manifest.json`: counts, seed, and a hash of the priors.

## Example kinds

| Kind | Count | What Muse learns |
|---|---:|---|
| `objective` | 1,242 | A goal (more spin, more pace, cleaner contact, slice→topspin). It tests the best single change on two levers in parallel, then a combination if needed, and picks the **smallest change that reaches the target**. The pick is guided by what the digest shows (an open face points to closing the face; a flat path to swinging more low-to-high). |
| `player_whatif` | 489 | The player proposes the change (e.g. "open the face 3° and swing 5% slower"). Muse runs exactly that and says whether it's worth it. |
| `player_whatif_extreme` | 93 | The request is beyond the tool's limits. Muse reports the capped change and suggests a smaller step. |
| `unmodeled` | 174 | Questions about depth or net clearance. Muse reports speed and spin and says flight isn't modeled. |
| `contact_spread` | 72 | The average contact is already centered. Muse explains that the issue is scatter, which the simulator can't model. |
| `no_motion`, `*_error` | 94 | Mic-only or saturated data. Muse says it can't simulate, with no made-up numbers. |

Every final answer is under 80 words and calls the result an estimate, and the tests check that every number in it
appears in a tool result.

## Caveats

- ShotSimulator is a sensitivity model. The ball speeds it gives are high for the racket speeds (median forehand:
  95 km/h racket, 143 km/h ball). The dataset teaches Muse to use the tool honestly; it doesn't make the tool right.
  Recalibrate `acorCenter` from TennisCamera ball tracks and regenerate.
- Face and path changes move spin identically in the model. Which one Muse picks comes from the digest heuristic
  (`diagnosis()` in `whatif_synth.py`), not from the physics.
- Answers are templated, so their wording is repetitive. To vary the wording, paraphrase the final turns with a
  model, keeping every number.
- Once impact-mode club sessions exist, re-run `priors` with their windows added and regenerate.

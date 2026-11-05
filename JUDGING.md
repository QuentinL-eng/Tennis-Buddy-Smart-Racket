# Judging guide: Tennis Buddee

**What this is.** A smart tennis racket: a sensor insert in the handle (ESP32-C3, IMU, mic) computes
every shot on the racket and shows it live on iPhone, Mac, Apple Watch, and Meta Ray-Ban Display.
Meta's open Muse Spark (`meta-models/muse-spark-open-1026`, served by Baseten) works as a tool-calling agent over the player's own shots and the
live racket: it runs a physics simulator to **predict** what a swing change would do, then plans a
drill the Watch and glasses track. This is a hardware + software instrument, not a generic advice
chatbot: every number Muse reports must come from a tool result.

- **Try the [live browser emulator](https://tennisbuddy.net/emulator)** · Website: <https://tennisbuddy.net> · Machine index: [`llms.txt`](llms.txt) ·
  Machine metadata: [`hackathon.json`](hackathon.json)

## Rubric evidence map

### Impact (30%)

- Problem, users, and what changes: [`README.md`](README.md) ("Impact").
- Real-world validation: an 86-minute club session that changed the design
  ([`docs/CLUB_2026-10-28.md`](docs/CLUB_2026-10-28.md)).
- Product signals: Sign in with Apple/Google, iCloud sync, over-the-air
  firmware updates, 3D-printed insert from off-the-shelf parts ([`docs/WIRING.md`](docs/WIRING.md)).

### Use of Meta AI tooling (25%)

| Meta technology | Evidence |
|---|---|
| Open Muse Spark `meta-models/muse-spark-open-1026` on Baseten, native function calling, 10 tools | [`apple/Shared/Coach/CoachTools.swift`](apple/Shared/Coach/CoachTools.swift) (tool schemas), [`apple/Shared/Coach/MuseClient.swift`](apple/Shared/Coach/MuseClient.swift) (client + bounded loop: 5 requests, 8 tool calls, 45 s timeout) |
| Server proxy holds the key (app never ships one) | [`backend/supabase/functions/muse/index.ts`](backend/supabase/functions/muse/index.ts) (`POST https://inference.baseten.co/v1/chat/completions`) |
| `simulate_change`: Muse tests swing changes on the player's own average stroke | [`apple/Shared/Coach/WhatIf.swift`](apple/Shared/Coach/WhatIf.swift), [`ml/coach_sim.py`](ml/coach_sim.py) (Python mirror) |
| Muse directs the 3D swing film from validated simulations | [`apple/Shared/Coach/SwingFilm.swift`](apple/Shared/Coach/SwingFilm.swift), [`docs/SWING_FILM.md`](docs/SWING_FILM.md) |
| Meta Wearables Device Access Toolkit (`MWDATCore`, `MWDATDisplay`), Ray-Ban Display HUD | [`apple/iOS/Glasses/GlassesController.swift`](apple/iOS/Glasses/GlassesController.swift) |
| 2,263-conversation tool-use dataset (tool results match the app exactly) | [`ml/whatif_synth.py`](ml/whatif_synth.py), [`docs/WHATIF_DATASET.md`](docs/WHATIF_DATASET.md) |
| Head-to-head agent eval vs the Meta API and open Muse Spark | [`tools/agent_eval.py`](tools/agent_eval.py) (`--preset meta` / `--preset baseten`) |
| Meta SAM 3.1 video + image APIs | Racket tracks + contact pre-fill behind the reviewed contacts; tracks convert to emulator sessions (9 matches, 2,265 hits; stroke types are F3Tennis dataset labels for the Ostrava final and F3Tennis model predictions, flagged as predicted, for the other 8) | [`tools/sam_f3set_video.py`](tools/sam_f3set_video.py), [`tools/sam_track_to_session.py`](tools/sam_track_to_session.py) |

Quick automated checks: `meta-models/muse-spark-open-1026` in `apple/Shared/Coach/MuseClient.swift:27` and
`backend/supabase/functions/muse/index.ts` (which calls `POST https://inference.baseten.co/v1/chat/completions`);
`import MWDATCore` / `import MWDATDisplay` in `apple/iOS/Glasses/`; `sam-3.1` across
`tools/sam_*.py` and `ml/stroke_system/`.

### Technical depth and execution (20%)

- Architecture diagram + data-driven decisions: [`README.md`](README.md) ("Technical depth").
- Firmware computes each shot on the racket (C++ port of the Swift `ShotAnalyzer`): 80-byte summary
  first (`static_assert` in [`firmware/include/protocol.h`](firmware/include/protocol.h)), then the
  448-sample window (384 pre + 64 post) with acks, resends, and a flash backlog (6 RAM slots,
  117-window `spiffs` log, [`firmware/src/backlog.h`](firmware/src/backlog.h)).
- Sweet-spot audio model: ridge on 156 features, 67.2% accuracy vs 60.6% baseline, 1.83 cm mean
  error, 274 clips, grouped 5-fold ([`ml/runs/SUMMARY-20261028.md`](ml/runs/SUMMARY-20261028.md));
  C++/Python parity on all 296 clips (`python3 ml/test_parity.py` → `PASS`).
- Test matrix below. Weak results are reported, not hidden (see the run summary).

### Demo (25%)

- [Watch the demo video](https://youtu.be/B_Mw23IpRUQ): source in [`video/`](video/),
  plan in [`video/SHOOT_PLAN.md`](video/SHOOT_PLAN.md), every on-screen number in
  [`video/src/config/copy.ts`](video/src/config/copy.ts).
- Live backup plan: flash backlog + replay + built-in engine fallback
  ([`README.md`](README.md) "Holds up live").
- Two-minute try: [open the browser emulator](https://tennisbuddy.net/emulator).

## 5-minute verification

```bash
git log --format=%ad --date=short | sort | uniq -c   # project history
python3 ml/test_parity.py                            # C++ and Python agree on 296 clips
python3 -m unittest discover -s ml -p test_whatif_synth.py  # simulator mirror, 11 tests
python3 -m unittest discover -s tools -p "test_*.py" # 55 tests
npm test --prefix backend/supabase                   # migration + social logic in PGlite
grep -rn "muse-spark-open\|inference.baseten.co" apple/Shared/Coach backend/supabase/functions/muse
grep -rln "MWDATCore\|MWDATDisplay" apple/iOS/Glasses
```

## Full test matrix

| Suite | Command | Expected |
|---|---|---|
| Swift (106 methods: 62 RacketKit + 44 app) | `swift test --package-path apple/RacketKit` + `xcodebuild … TennisBuddy-macOS … test` | pass (2 replay utilities skip unless `REPLAY_DIRS` is set) |
| ML parity (296 clips) | `python3 ml/test_parity.py` | `PASS`, max distance error 7.22e-07 cm |
| What-if simulator | `python3 -m unittest discover -s ml -p test_whatif_synth.py` | 14 tests, OK |
| Full `ml` discovery | `python3 -m unittest discover -s ml` | 46 pass; 1 research-only module needs the local kymatio checkout under `firmware/.pio/` (git-ignored, not the supported path in `ml/README.md`) |
| Tools | `python3 -m unittest discover -s tools` | 55 tests, OK |
| Robot rig | `.venv/bin/python -m pytest TennisRobot/tests/` | 51 cases; needs `pytest` + loopback sockets |
| Backend | `npm test --prefix backend/supabase` | pass (embedded PGlite, no cloud needed) |
| Firmware host test | `firmware/tools/backlog_test/` | flash backlog vs fake flash under ASan/UBSan |
| Firmware build | `cd firmware && pio run` | needs the PlatformIO ESP32-C3 toolchain |

## Provenance

- Started during the Meta Global AI Developer Hackathon and updated afterwards.
- MIT licensed ([`LICENSE`](LICENSE)); forked idea from
  [AahanPrajapati/Smart-Tennis-Racket](https://github.com/AahanPrajapati/Smart-Tennis-Racket) (MIT).
- Privacy: shots stay on-device/iCloud; only what Muse fetches goes to Baseten via our proxy
  ([`docs/PRIVACY.md`](docs/PRIVACY.md)).

## What to skip

Large local-only captures and generated output a clone does not need for evaluation:
`data/external/`, `data/Tennis Camera/`, `data/room-2026-10-29/runs*/`, `*.tbrec` raw captures,
`TennisRobot/TennisBuddyDayOne_20261029/`, `marketing/*.mp4`, `video/out/`, `apple/.build/`,
`firmware/.pio/`, `backend/supabase/node_modules/`.

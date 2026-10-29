# Tennis Buddy apps (iPhone · Mac · Apple Watch)

One SwiftUI codebase for iPhone and Mac (`Shared/`), a Watch companion (`Watch/`), and the `RacketKit` Swift
package that does all the racket math (decoding, orientation, shot detection, physics, simulator, recorder).

## Run it

1. Open `apple/TennisBuddy.xcodeproj` in Xcode.
2. Pick a scheme and run:
   - **TennisBuddy-macOS** → My Mac
   - **TennisBuddy-iOS** → your iPhone (the Watch app installs with it; open it from the Watch's app list)
   Signing uses team `3KJ46YFZM9` with automatic signing. If Xcode complains, pick your team under Signing & Capabilities.

The project file is generated from `project.yml`. After adding or removing files run `xcodegen` in `apple/`
(`brew install xcodegen`).

## Using it without the racket

The app starts on the **Simulator** data source: a virtual racket that swings and hits every few seconds, so every
screen works without hardware. Switch to the real racket from the connection menu on the Live tab or in the Racket tab.

## Muse coach

Muse runs through the `muse` Supabase edge function (`backend/supabase/functions/muse`), which holds the Meta API key
as a server secret; the app never contains or asks for a key. Online coaching needs a signed-in account
(Racket → Account) and can be turned off with **Use Muse online** in Insights → Coach.
Muse sends questions and requested shot/session statistics to Meta. Health data and session notes are excluded.
Any Muse error, or being signed out, uses the deterministic built-in coach, and the UI shows the engine that answered.
Deploy once: `supabase secrets set META_API_KEY=... --project-ref birutnqxduzwldvymeun` then
`supabase functions deploy muse --project-ref birutnqxduzwldvymeun`.
No local language model is downloaded or loaded.

The function calls `POST https://api.meta.ai/v1/chat/completions`, Bearer authentication and `muse-spark-1.3` (Standard mode).
Native function calling is confirmed in [Meta's tool calling docs](https://dev.meta.ai/docs/tool-calling).
[Published limits](https://dev.meta.ai/docs/pricing-rate-limits) are 3,000 RPM / 4,000,000 TPM for this model as of October 27, 2026;
HTTP 429 immediately falls back, without automatic retries. Each request times out after 45 seconds.
The agent makes at most five requests and runs at most eight tool calls per response. The final request omits tools.

Tools: `query_shots`, `compare_sessions`, `get_session_digest`, `get_live_state`, and `simulate_change`.
The digest includes a session UUID/date catalog; selectors also accept `current`, `latest` and `previous`.
Only `query_shots` accepts `all`. Date filters use inclusive ISO 8601 timestamps. Tools return explicit units;
missing motion metrics are null. All stored/live access and tool dispatch run on the main actor.

`ShotSimulator` is a pure speed/spin sensitivity model using the analyzer's restitution and brush equations,
with a 2D face/path approximation. It clamps swing speed to 0–200 km/h, path to ±80°, face to ±60°,
contact x/y to ±12/14 cm and incoming speed to 0–200 km/h. The tool also caps proposed deltas.
It uses the player's average usable motion shot, excluding mic-only and gyro-saturated shots.
Incoming speed is assumed (serve 0, volley 54, groundstroke 43.2 km/h).
Outputs are **estimated**, and no launch angle, flight, net clearance or landing depth is claimed.

Validation:

```sh
swift test --package-path apple/RacketKit
xcodebuild -project apple/TennisBuddy.xcodeproj -scheme TennisBuddy-macOS -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test
```

The coach tests mock HTTP and model responses; an end-to-end API check requires your own key in the app.

## Layout

| Path | What |
|---|---|
| `RacketKit/` | Protocol decode, `RacketBLE`, `MahonyFilter`, `RacketEngine` (shot detection), `ShotAnalyzer` (physics), `SimulatedRacket`, recorder/replay. `swift test` runs a simulator round-trip test. |
| `Shared/Model` | `AppModel` (sources, sessions, settings), SwiftData records |
| `Shared/Views` | Live, History, Insights, Racket, Calibration, 3D racket (SceneKit), string bed |
| `Shared/Coach` | Muse HTTP client, Keychain key storage, tool dispatcher, bounded agent loop, prompts and template fallback |
| `iOS/WatchBridge.swift` | iPhone ↔ Watch messages |
| `Watch/` | Watch app: last shot + haptics, point logging, session start/stop with a Tennis workout (heart rate → Health) |

## Consumer features

- **Racket → Racket skins:** main and secondary colour pickers, four presets, original textured racket,
  persistent colours, and a preview that updates the Live 3D racket too. Strings retain their own material.
- **Session names:** edit during a recording on Live, or use Rename session in a History session.
  Empty recordings are retained so tennis workouts and score-only sessions are not discarded.
- **Watch workouts:** tennis HealthKit sessions collect heart rate and active energy, request workout/energy
  sharing permissions, serialize start/stop transitions, reset metrics between workouts, and surface errors.
  Final calories are queued back to the iPhone against the specific session UUID. Actual ring credit needs
  a physical Watch and Health permissions; it is determined by HealthKit, not a fixed calorie formula.
  See [Apple's workout guidance](https://developer.apple.com/documentation/healthkit/running-workout-sessions).
- **Accounts, friends, shared scores and racket summaries:** integration prepared for Supabase; see
  [setup and validation](../backend/supabase/README.md). Together supports direct friend invitations after
  a one-time accepted friend request, plus optional session codes. Google login, native Apple login, and the hosted database are configured. Native Apple sign-in uses
  the system sheet; the signed iPhone/Watch build and Apple provisioning entitlement were verified.
  A real device login still needs testing. See the setup guide for the Mac signing limitation. Watch shared scoring uses the paired iPhone.
- **Insights:** existing UI retained pending the user's Claude design direction.
- **Muse Spark:** already integrated; no local Llama model is loaded. Existing mock HTTP/fallback tests remain.

The project generator excludes synchronizer conflict copies and the legacy Score/TapCalibration screens
that were not connected to the current AppModel. RacketKit also excludes backup copies. The current BLE
implementation now retains both tap/wide-gyro support and the firmware-update implementation used by
AppModel; legacy OTA control and notify-only tap characteristics sharing UUID 0006 are distinguished by
characteristic write properties. These physical hardware paths still need a racket smoke test.

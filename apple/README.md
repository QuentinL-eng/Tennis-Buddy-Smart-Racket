# Tennis Buddy apps (iPhone · Mac · Apple Watch)

One SwiftUI codebase for iPhone and Mac (`Shared/`), a Watch companion (`Watch/`), and the `RacketKit` Swift
package that does all the racket math (decoding, orientation, shot detection, physics, simulator, recorder).

## Run it

1. Open `apple/TennisBuddy.xcodeproj` in Xcode.
2. First open only: Xcode asks to **Trust & Enable** the `MLXHuggingFace` macro (part of the Gemma integration). Click it.
   If a build fails with "missing Metal Toolchain", run `xcodebuild -downloadComponent MetalToolchain` once.
3. Pick a scheme and run:
   - **TennisBuddy-macOS** → My Mac
   - **TennisBuddy-iOS** → your iPhone (the Watch app installs with it; open it from the Watch's app list)
   Signing uses team `B8QLYC5T9U` with automatic signing. If Xcode complains, pick your team under Signing & Capabilities.

The project file is generated from `project.yml`. After adding or removing files run `xcodegen` in `apple/`
(`brew install xcodegen`).

## Using it without the racket

The app starts on the **Simulator** data source: a virtual racket that swings and hits every few seconds, so every
screen works without hardware. Switch to the real racket from the connection menu on the Live tab or in the Racket tab.

## Gemma 4 E2B coach

Insights tab → **Load Gemma**. The first load downloads the 4-bit model (`mlx-community/gemma-4-e2b-it-4bit`) from
Hugging Face; after that it runs fully offline. Until it's loaded, a built-in template coach answers, so the
feature never breaks a demo. **Load it on the demo iPhone and Mac before the demo** over good Wi-Fi.

Command-line check on the Mac: `"Tennis Buddy.app/Contents/MacOS/Tennis Buddy" --coach-selftest` loads Gemma,
coaches a sample session, prints the result and quits.

## Layout

| Path | What |
|---|---|
| `RacketKit/` | Protocol decode, `RacketBLE`, `MahonyFilter`, `RacketEngine` (shot detection), `ShotAnalyzer` (physics), `SimulatedRacket`, recorder/replay. `swift test` runs a simulator round-trip test. |
| `Shared/Model` | `AppModel` (sources, sessions, settings), SwiftData records |
| `Shared/Views` | Live, History, Insights, Racket, Calibration, 3D racket (SceneKit), string bed |
| `Shared/Coach` | Coach prompts, template coach, Gemma (MLX Swift) |
| `iOS/WatchBridge.swift` | iPhone ↔ Watch messages |
| `Watch/` | Watch app: last shot + haptics, point logging, session start/stop with a Tennis workout (heart rate → Health) |

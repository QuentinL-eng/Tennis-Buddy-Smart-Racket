# TestFlight

App Store Connect app: **Tennis Buddy Trainer** (bundle ID `com.kellamadams.tennisbuddy`).

**Public beta link:** https://testflight.apple.com/join/137F7kvd (works once Beta App Review approves the build;
build 1.0 (1) submitted 2:30 PM, Oct 17). Internal group: "Team & Friends" (automatic distribution). External group: "Public Beta".
Upload a new build: `tools/testflight.sh` (archives the iPhone + Watch app and uploads; build numbers are automatic).

## Test information (App Store Connect → TestFlight → Test Information)

- **Beta App Description:** Tennis Buddy turns a sensor-equipped tennis racket into a coach: swing speed, ball speed,
  spin, sweet-spot hits and an on-device AI coach (Llama 3.2). No racket? The app starts in Simulator mode so you can
  try every screen. The Apple Watch app taps your wrist for each shot and runs a tennis workout.
- **What to Test:** Open the Live tab and press Start Session; the simulated racket hits a shot every few seconds.
  End the session, then check History and Insights. Tap "Load Llama" in Insights (one-time ~1.8 GB download on Wi-Fi)
  and try "Coach me" and "Plan my next drill". On Apple Watch, start a session from the watch.
- **Feedback Email:** your email
- **Privacy Policy URL:** https://github.com/KellamA/Smart-Tennis-Racket/blob/main/docs/PRIVACY.md
- **Beta App Review notes:** The app connects to a custom Bluetooth sensor in a tennis racket (hackathon project).
  Without the sensor it runs in Simulator mode by default, so all features can be reviewed without hardware.

## Getting it to friends

- **Today, no review:** App Store Connect → Users and Access → add each friend (any role, e.g. Customer Support,
  with access to this app). After they accept, add them to an **Internal Testing** group in TestFlight.
- **Public link:** TestFlight → External Testing → create a group → add the build → Submit for Review → enable the
  public link. The first build's review usually takes a few hours.

Testers install the **TestFlight** app from the App Store, then accept the invite or open the link.

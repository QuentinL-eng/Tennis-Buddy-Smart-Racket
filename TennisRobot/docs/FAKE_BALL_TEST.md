# Fake iPhone ball test

Run from `TennisRobot`:

```powershell
python tools/demo_iphone_ball.py
```

This starts a temporary loopback-only fake iPhone server and runs the normal
PC receiver, trajectory estimator, planner and mock arm. It always selects a
mock arm, even if the regular configuration is later changed. It does not
connect to Epson or change RC+ settings. Each run saves observations, fits,
intercepts, three-pose plans, outcomes and a summary in `runs`.

## Data basis

The observation/status packet layout matches the local iOS Swift encoder:
40 bytes, little endian, capture timestamp, sequence, pixel centre, pixel radius,
confidence and frame dimensions. The test uses 1920x1080 at a nominal 240 fps.
The configured feed starts at (0, 6.5, 1.15) m with nominal velocity
(0, -9.5, 2.9) m/s. The existing model adds gravity, aerodynamic drag, launch
variation, pixel/radius noise and occasional false detections. Spin and wind
are zero in this configuration. Camera calibration, noise and latency are test
assumptions, not measurements from an iPhone recording. Windows thread pacing
is approximate, so this does not measure phone transport performance.

Current iOS sources also emit kind 2 (camera-frame state) and kind 3 (intercept)
packets. The PC previously rejected these. It now accepts and skips them so
metres cannot enter the pixel estimator. This demo emits observation/status
packets; regression tests inject both extra packet types. The PC continues to
calculate its own intercept from pixel observations.

## Result: 26 October 2026

Recording: `runs/run-20261026-094759-73724.jsonl`.
Summary: `runs/run-20261026-094759-73724.summary.json`.

- Three requested balls, three completed mock strikes, no pipeline fault.
- 555 packets received; 538 observations; zero sequence gaps; 19 trajectory fits.
- All three outcomes are UNVERIFIED. The network path does not pass ground truth
  to the outcome evaluator. Mock timing/error values are simulated values.
- The recorder's `frames` counter counts receiver reads, not captured images.

## Epson boundary

This test validates the PC software path only. The Python planner still uses its
placeholder base transform and racket mount, including a 520 mm impact offset.
The RC+ setup has an estimated 450 mm offset along flange +Y. Do not send the
saved plans to RC+: these frames and mounts have not been reconciled. The full
RC+ path remains unverified and the virtual socket remains in Simulated mode.
A mock completion does not prove reachability, collision clearance or a ball hit.

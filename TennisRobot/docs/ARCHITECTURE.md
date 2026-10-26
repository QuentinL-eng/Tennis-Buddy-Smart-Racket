# Architecture

The system answers three questions on every camera frame:

1. **Where is the ball, and where will it be?** A monocular flight fit.
2. **Where must the racket be, and when?** A strike-plane intercept and a timed
   straight sweep of the designated string-bed point.
3. **Is it safe and legal to start that motion?** Envelope, fit quality, lead
   time and arm state.

The fourth question — **how does the arm actually move?** — is delegated to the
Epson controller. The Linux side sends a short motion request and does not stream
servo targets.

## Design constraints

- **One camera.** Depth is not directly measured; apparent ball radius and the
  flight model provide it. This is the dominant accuracy limit.
- **The UNO Q is not a real-time controller.** Debian scheduling, Python and
  network jitter are not deterministic. The RC700-E keeps motion and safety.
- **Fail closed for new motion.** If a fit, plan, deadline, envelope or heartbeat
  fails, no new motion starts. An in-progress controller motion is not
  interruptible by a socket message in the reference server; the E-stop is the
  reliable stop.
- **The controlled point is on the strings, not the flange.** The racket mount
  and impact offset are part of the kinematic chain.

## Coordinate frames

All planning is in **world** coordinates. The Epson base frame is used only at
the arm boundary.

| Frame | Origin | Axes | Used by |
|---|---|---|---|
| `world` | Robot base on the floor | +X to the robot's right, +Y forward towards the court (the incoming ball), +Z up | Detection, prediction, planning |
| `camera` | Camera optical centre | +X image right, +Y image down, +Z optical axis forward | `PinholeCamera`, config `camera.pose` |
| `arm base` | Epson base origin | Epson base convention, +Z up | `arm.base_pose`, envelope, wire protocol |
| `flange` | Epson tool flange | Epson tool +Z out of the flange | `StrikePlan.flange_*` |
| `racket` | Butt cap | +Z up the shaft, +Y out of the strings, +X across the strings | `Racket`, `racket.mount_pose`, `impact_point_m` |

The default `arm.base_pose = [0, 0, 0, 0, 0, 90]` puts the arm base at the world
origin with base +X facing world +Y, i.e. towards the incoming ball. Poses in TOML
are `[x, y, z, roll, pitch, yaw]` in metres and degrees, with
`R = Rz(yaw) · Ry(pitch) · Rx(roll)`. **Verify that Euler convention on the real
controller** before trusting a converted pose (see
[`CALIBRATION.md`](CALIBRATION.md)).

## Pipeline

```
source.read() ──► observation gate ──► buffer
                                         │ every N frames
                                         ▼
                                  FlightEstimator.fit()
                                         │
                                  SafetyMonitor.check_fit()
                                         ▼
                              predict_intercept(strike plane)
                                         │
                               check_intercept(ball speed)
                                         ▼
                                    SwingPlanner.plan()
                                         │
                                check_plan(envelope, time)
                                         ▼
                                EpsonArm.strike(plan)
                                         ▼
                                  committed → cooldown
```

The state machine is deliberately small:

```
monitor ────────────────────────────── (no strike authority)
armed ── plan accepted + sent ──► committed ── strike_done ──► cooldown ──► armed
armed ── fit/plan rejected ─────► armed
any   ── arm fault / 3 consecutive misses / no DONE ──► fault (stop)
```

- Fitting runs every `run.fit_every_n_frames` frames. At 240 fps and the default
  12 frames, that is 20 Hz.
- One strike is sent per flight. After `strike_done`, the observation buffer and
  the gate are cleared so the same ball cannot trigger a second swing.
- A long gap in observations (>0.4 s) clears the buffer; the estimator never fits
  across two flights.
- `monitor` mode still fits and predicts, but never plans or sends a strike. It is
  the bring-up mode for a real camera or a read-only controller.

## Flight estimation

`src/tennisrobot/estimator.py` implements a small batch Gauss-Newton fit.

**Measurement.** Each detection is `(u, v, radius, t)`. For a sphere of radius
`R`, the pinhole model gives an approximate camera-frame depth

```
z ≈ fx · R / radius_px
```

and the pixel back-projects to a 3D point at that depth. The apparent radius is
therefore the only depth cue; centre pixels alone give a ray.

**Initial guess.** A straight line through the reconstructed 3D points gives
position and velocity at the first observation.

**Fit.** The state `(p0, v0)` at the reference time is integrated with the flight
model and projected at every observation time. Residuals are the image-centre
error and the projected-radius error, each normalised by a pixel sigma. A
Levenberg-Marquardt damping loop handles bad initial steps. After the solve, gross
outliers (more than `max(6 px, 3 × median)`) are dropped and the fit is repeated
once.

**Model.** Gravity, quadratic drag and an optional Magnus term at constant
configured spin (`src/tennisrobot/physics.py`):

```
a = g − (½ ρ Cd A / m) |v_rel| v_rel + (½ ρ A Cl / m) |v_rel|² (ω̂ × v̂_rel)
```

Spin is **not estimated**; a single camera cannot observe it. The configured spin
is a modelling assumption and a source of systematic error for a spinning ball.

**Speed.** The residual integrates one short grid over the window and uses cubic
Hermite interpolation at observation times. With a 40 ms grid, a 48-observation
fit takes roughly 12 ms on the development laptop and about 140 ms on the UNO Q
(measured). The default 240 fps cadence is therefore a laptop/simulation target,
not yet a board capability. The reported state is re-centred at the **newest**
observation, so prediction does not extrapolate backwards to the start of the
window.

**Output.** `FitResult` contains the state, pixel RMS, radius RMS, observation
count and iteration count. `SafetyMonitor` refuses a fit whose RMS exceeds
`max_fit_rms_px`. The simulator also records the true ball, so a run separates:

- **perception error** — predicted intercept vs. truth at the intercept,
- **execution error** — actual racket point vs. the fitted ball,
- **total error** — actual racket point vs. the true ball.

The default simulation's median numbers are in the status block of the README.

## Intercept

`FlightEstimator.predict_intercept` scans forward from `now` in 10 ms steps,
finds the first sign change of the signed distance to the strike plane while the
ball is approaching, and bisects to a few microseconds. The plane is defined by
`planner.strike_plane_point_m` and `planner.strike_plane_normal`; it is the place
the racket can reach, not necessarily the net.

The ball speed at the intercept is checked against
`safety.min_ball_speed_m_s` / `max_ball_speed_m_s`. There is no bounce model: if
the ball bounces before the plane, the predicted flight is wrong and the strike
should not be trusted.

## Racket and swing

Given the intercept point `p`, a face normal `n` and a shaft hint `s`:

```
+Y = normalize(n)
+Z = normalize(s − (s·+Y)·+Y)
+X = +Y × +Z
R  = [ +X  +Y  +Z ]
q  = p − R · p_impact_local
T_world_racket  = [R | q]
T_world_flange  = T_world_racket · inverse(T_flange_racket)
```

`T_flange_racket` is `racket.mount_pose`. The flange orientation is the same for
the whole sweep because only the impact point translates:

```
p_pre    = p − d_pre  · n
p_strike = p
p_post   = p + d_post · n
```

The face is square to the horizontal incoming velocity and the racket drives
through the ball (`face_normal` and `swing_direction` are the same). There is no
rebound, aim or spin model; the plan only guarantees contact at the chosen point.

### Timing

The controller can accelerate before contact and must still stop after it. With
TCP acceleration `a`, pre-distance `d_pre` and post-distance `d_post`:

```
v_eff      = min(v_config, sqrt(2·a·d_pre), sqrt(2·a·d_post))
accel_time = v_eff / a
accel_dist = v_eff² / (2·a)
lead       = accel_time + max(0, d_pre − accel_dist) / v_eff
deadline   = max(min_lead, lead + command_latency + decision_margin)
```

A plan is accepted only when `deadline ≤ intercept_time − now ≤ max_lead`.

- The lower bound is the arm's physical deadline.
- The upper bound forces the strike to use a fresh prediction. Committing at 0.4 s
  rather than 0.8 s cuts the extrapolation error substantially.
- At the default values, `v_eff = 2.19 m/s` (limited by the 0.20 m post runway),
  `lead ≈ 201 ms`, `deadline ≈ 280 ms`, and the allowed window is 280–400 ms.

The wire protocol sends the controller a lead in milliseconds relative to
command receipt, minus half the measured round-trip time. The controller schedules
its own pre-swing wait. See [`PROTOCOL.md`](PROTOCOL.md).

## Arm boundary

`src/tennisrobot/arm.py` defines the contract:

- `connect()`, `close()`, `service(now)`, `strike(plan, now)`, `abort(reason)`,
  `status`, `busy`.
- `MockArm` schedules a strike at the planned time with configurable timing
  jitter and position noise. It reports an actual impact point so the simulator
  can separate execution error from perception error.
- `EpsonArm` is a non-blocking TCP client for the SPEL+ server. It sends three
  poses in the Epson base frame, a speed in mm/s and a lead in ms, then waits for
  `ACK` / `DONE`. It maintains a heartbeat and fails the run on silence.
- `EpsonArm` does **not** stream joint or Cartesian targets. The RC700-E executes
  the sweep using its own motion planner.

The controller-side reference is [`epson/strike_server.prg`](../epson/strike_server.prg).
It is a skeleton, not validated SPEL+, and it is single-task: while it is inside
`Move`, it is not reading the socket. A queued `ABORT` is therefore only seen
between motions. Use the controller's safety circuit and E-stop for a real stop.

## Safety gates

`src/tennisrobot/safety.py` checks:

- fit RMS and observation count,
- ball speed at the intercept,
- impact point and all three flange positions inside conservative base-frame boxes,
- swing speed within the arm limit,
- strike time in the future.

The pipeline adds:

- the observed lead window,
- one strike per ball,
- a strike-confirmation timeout (no `DONE` → fault → best-effort `ABORT`),
- a consecutive-miss limit,
- operator authority (`--arm`; monitor mode is the default).

The envelope is a **box in the arm base frame**, not the controller's true
workspace and not the racket's full swept volume. The arm and racket can collide
with something even when the box check passes. See [`SAFETY.md`](SAFETY.md).

## Configuration, units and recording

- SI units everywhere except pose rotations (degrees).
- Unknown config keys are rejected; a typo in a safety limit fails at startup.
- The config snapshot is written into every recording.
- Every accepted observation, fit, intercept, plan, rejection, arm event and
  outcome is recorded as JSONL by `src/tennisrobot/recorder.py`.
- `replay` re-fits the recorded observations. It does not command an arm.

## Extension points

| Need | Where to change |
|---|---|
| Stereo or a second camera | Add a source that returns 3D observations; replace the radius-depth initial guess in `estimator.py` |
| Known ball-machine launch point | Add a fixed-position prior to the estimator's initial guess and residuals |
| Better detector | Keep `detect(frame, t) -> list[BallObservation]`; replace `ColorBlobDetector` |
| Spin or rebound model | Extend `physics.py` and the fit state; add aim/orientation selection to `planner.py` |
| Full racket swept-volume safety | Add the racket's corner points and a swept-volume check in `safety.py`; validate in the cell |
| Arm kinematics | Add a reachability backend that asks the controller or a calibrated kinematic model |
| MCU role (status LEDs, e-stop readback) | Add a Bridge/MCU path; never move the safety-rated stop into it |

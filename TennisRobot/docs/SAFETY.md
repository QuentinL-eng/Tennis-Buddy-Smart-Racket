# Safety

This framework is a research prototype. **The software is not a safety-rated
system.** It can decide not to start a motion and it can ask the controller to
abort, but it cannot guarantee that a moving robot stops. Only the RC700-E's
safety circuit, a hardwired E-stop, guarding and a restricted work envelope can
do that.

If you are not prepared to run a 6-axis industrial arm and a ball machine with
the same rigour as any other hazardous machine, stop here. A tennis racket at
2 m/s carries far more energy than a ball, and the arm does not know where a
person is.

## Controls that must exist before power

| Control | Requirement |
|---|---|
| **Emergency stop** | Hardwired to the RC700-E safety input, within reach of every operator. Test it before every session. Do not route it through the UNO Q, Python or the network. |
| **Guarding** | A physical barrier or light curtain around the full reach of the arm **plus the racket**, including the backswing and the ball machine's feed path. |
| **Restricted space** | Mechanical limits or controller limits that keep the racket out of the net, walls, camera, ball machine and people. |
| **Speed and payload limits** | Start at a small fraction of the C8's capability. Check the payload and inertia with the racket and mount; a 3 kg nominal / 8 kg maximum payload does not mean a long racket at speed is safe. |
| **Two-person rule** | One operator at the E-stop, one at the ball machine/PC. Nobody else inside the barrier. |
| **Eye protection** | For everyone in the area; balls and racket fragments do not negotiate. |
| **Ball machine** | Clamped, guarded, aimed away from people, triggered remotely. A jammed machine is cleared only after it is powered down. |

The Epson C8-B901S is listed at 901 mm reach, 3 kg nominal / 8 kg maximum
payload and ±0.03 mm repeatability. Those are robot specifications, not a
statement that a racket on the end is safe at any speed. Verify the exact model,
payload curve and safety manual for your arm and controller.

## What the software does

**Monitor mode** (`run --monitor`) connects to the controller read-only: it sends
heartbeats but never a strike. Use it to check the camera, tracking and link.

**Armed mode** (`run --arm`) may send a strike only when all of these hold:

- the operator explicitly enabled `--arm`;
- the fit has enough observations and low pixel residual;
- the predicted ball crosses the strike plane inside the configured ball-speed
  range;
- the impact point and all three flange poses are inside the base-frame boxes;
- the strike time is far enough in the future for the arm's deadline and close
  enough to use a fresh prediction;
- the arm reports ready and the heartbeat has not been lost;
- no strike has already been sent for this ball.

The pipeline faults and stops issuing new strikes after:

- an arm error or lost heartbeat;
- a strike that is not confirmed within 2 s;
- three consecutive missed strikes;
- a camera that stops delivering frames while armed (a 1 s source timeout).

None of these actions can stop a motion already executing on the controller. The
single-task SPEL+ reference cannot read the socket while it is inside `Move`; the
`ABORT` message is queued at best. **The E-stop is the stop.**

### Watchdog limitations

- `EpsonArm` sends a `PING` every 250 ms and faults after ~1 s of silence. The
  reference SPEL+ program does **not** enforce its own watchdog; add one on the
  controller, or keep the socket task separate from the motion task, before
  relying on the link.
- `CameraSource.healthy` catches a camera that returns failures. It cannot catch
  a driver call that blocks forever; if that matters, run capture in a separate
  process with its own watchdog and hardware trigger.
- A dropped frame, a late frame or a timestamp error is not detected as such. A
  bias in `camera.latency_s` becomes a timing miss.

## Envelope: the boxes are not the whole robot

`arm.impact_box_*` and `arm.flange_box_*` are **conservative placeholder boxes**
in the Epson base frame. The pipeline checks:

- the **impact point** at the strike time;
- the **flange position** at the pre-swing, strike and post-swing poses.

It does **not** check:

- the rest of the racket (the head, frame and tip sweep outside the flange box);
- the arm links or the racket against the net, camera, ball machine or a person;
- the controller's true joint limits, singularities or reachable orientation.

Before arming:

1. Measure the envelope in the cell at low speed, with the real racket mounted.
2. Set the boxes so the racket's full swept volume stays clear of everything.
3. Confirm the controller rejects unreachable poses; do not rely on a Cartesian
   box as a reachability model.
4. Add the racket's corner points and a swept-volume check if the simple boxes
   are not conservative enough for your layout.

## Arming procedure

Use this order every session.

1. **Cell check.** Guard closed, no loose balls, camera and lighting secure,
   ball machine clamped and empty of jammed balls.
2. **E-stop test.** Power the controller, press the E-stop, confirm drives drop,
   reset and confirm the arm stays still.
3. **Controller server.** Start the SPEL+ program; confirm it accepts a `PING`
   from the UNO Q (`tools/fake_arm.py` first if the controller is not connected).
4. **Monitor.** `python -m tennisrobot run --config config/uno_q.toml --monitor`.
   Confirm heartbeats, frames, fits and no `FAULT`.
5. **Mock arm, real camera.** `python -m tennisrobot run --config config/camera_only.toml --arm`
   with the ball machine at its **lowest** speed. This sends no robot commands.
   Tune the detector and watch the predicted intercepts.
6. **Slow real strikes.** Ball machine at the lowest speed, foam or soft ball if
   available, one operator on the E-stop. Start with a reduced
   `planner.swing_speed_m_s`. Keep the cell clear.
7. **Increase gradually.** Only after repeated clean strikes and a review of the
   recording. Never "just try a fast one" to see what happens.

## Stops

- **Emergency:** press the E-stop. Do not wait for the terminal, the network or
  the controller to finish.
- **Normal:** release the ball-machine trigger, let the current motion finish,
  stop the Python process, then disable the controller.
- `Ctrl+C` stops the pipeline from sending new strikes. It does not stop an
  in-progress controller motion.
- Closing the laptop, unplugging the camera or dropping Wi-Fi does not stop an
  in-progress motion.

## Failure modes

| Failure | What the framework does | What you must do |
|---|---|---|
| Camera unplugged | Source timeout → fault, no new strike | E-stop if the arm is moving |
| Ball detection lost | No fit / no intercept → no strike | Check lighting and thresholds |
| Fit residual high | Refuses to plan | Do not raise the RMS limit to "make it work"; fix the detection |
| Ball outside envelope | Refuses to plan | Widen the envelope only after a physical check |
| Too late / too early | Refuses to plan | Check the ball feed, latency and fit cadence |
| Network lost | Heartbeat fault, no new strike | E-stop if the arm is moving |
| Controller reports `ERR` | Fault, best-effort `ABORT` | E-stop, read the controller log |
| Three misses | Fault | Stop, inspect the recording; do not simply reset |
| UNO Q reboot | No new motion | E-stop if the arm is moving |
| Wrong calibration | Systematic misses | Recalibrate; do not compensate with a larger tolerance |
| Racket hits the net/person | Software cannot prevent it | Guarding and restricted space must |

## Network and remote access

The protocol has **no authentication or encryption**. Keep the UNO Q and RC700-E
on an isolated control network. Do not expose port 12000 to the site LAN or the
internet, and do not port-forward it. A hostile packet that looks like a strike
command is a motion command.

## Pre-flight checklist

- [ ] E-stop tested this session
- [ ] Guarding in place and interlock working
- [ ] Envelope measured with the real racket
- [ ] Calibration values recorded and unchanged
- [ ] Controller speed/accel limits reduced for the first run
- [ ] Ball machine clamped and aimed safely
- [ ] Monitor mode passed with no fault
- [ ] Mock-arm run passed with the real camera
- [ ] Two operators briefed; E-stop within reach
- [ ] No one inside the barrier
- [ ] Stop procedure understood by everyone

Print this list. Do not run an armed session from memory.

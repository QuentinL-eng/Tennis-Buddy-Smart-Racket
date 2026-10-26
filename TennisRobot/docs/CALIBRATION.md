# Calibration

Nothing in this framework is safe or accurate until the values below are
measured. The shipped configuration contains **placeholders**. Do the work in
order, at low speed, with the E-stop in reach.

## What has to be measured

| Quantity | Config key | Effect if wrong |
|---|---|---|
| Camera intrinsics and lens distortion | `camera.fx/fy/cx/cy`, `camera.distortion` | Pixel rays are wrong; depth and intercept shift |
| Camera pose in world | `camera.pose` (or `look_at`) | Every world point is rotated/translated; the racket misses systematically |
| Exposure-to-arrival delay | `camera.latency_s` | Ball state is treated as newer than it is; the racket arrives late |
| Arm base pose in world | `arm.base_pose` | The commanded pose is in the wrong frame |
| Flange → racket butt mount | `racket.mount_pose` | The racket body misses even if the flange is right |
| Designated contact point | `racket.impact_point_m` | The strings meet the ball at the wrong place |
| Epson Euler convention | geometry conversion | The wrist is rotated wrongly |
| Safe envelope | `arm.impact_box_*`, `arm.flange_box_*` | The software may allow a collision |

Keep a copy of every measured value and the date. Recalibrate after moving the
camera, changing the lens/focus, remounting the racket or moving the arm base.

## 1. Define the world frame

The world frame is the **robot base on the floor**:

- origin: the point on the floor under the Epson base centre;
- **+X** to the robot's right (when facing the court);
- **+Y** forward, towards the incoming ball;
- **+Z** up.

The default `arm.base_pose = [0, 0, 0, 0, 0, 90]` makes the Epson base +X point
along world +Y. If the arm is rotated on its pedestal, measure the rotation and
change `arm.base_pose`; do not change the world definition per component.

Mark the origin and the +X/+Y directions on the floor. The camera mount and the
ball machine are measured in this frame.

## 2. Camera intrinsics

Print a chessboard on a rigid, flat board. The square size in metres is required;
measure it, do not trust the printer.

```bash
python tools/calibrate.py intrinsics --images "calib/*.jpg" \
    --cols 9 --rows 6 --square 0.025 --out calib/intrinsics.json
```

Use 15–30 images at the final focus and zoom, covering the corners of the image
and several tilt angles. Do not change focus afterwards. The tool prints the
reprojection RMS and a TOML snippet:

```toml
[camera]
fx = ...
fy = ...
cx = ...
cy = ...
distortion = [k1, k2, p1, p2]
```

A good RMS is well under 1 px for a 1280×720 camera. If it is large, the board
moved, the images are blurred, or the wrong inner-corner count was used.

Use the **same resolution** in `config/uno_q.toml` as in the calibration images.
Changing resolution scales the intrinsics; changing the lens invalidates them.

## 3. Camera pose in world

Put 6–12 markers at known world coordinates that are **not all on one plane**
(e.g. four on the floor, two on a vertical post at different heights). Record
their pixels in the image.

`calib/world_points.json`:

```json
{
  "world": [[0.0, 3.0, 0.0], [2.0, 3.0, 0.0], [2.0, 0.0, 0.0], [0.0, 0.0, 0.0],
            [0.0, 1.5, 0.5], [0.0, 1.5, 1.0]],
  "pixels": [[.., ..], [.., ..], [.., ..], [.., ..], [.., ..], [.., ..]]
}
```

```bash
python tools/calibrate.py pose --intrinsics calib/intrinsics.json \
    --points calib/world_points.json
```

Paste the output:

```toml
[camera]
pose = [x, y, z, roll, pitch, yaw]
```

`pose` takes precedence over `look_at` when both are present. The `look_at`
default is a simulation convenience; leave it in the file if you like, but the
solved pose is what will be used. Verify that projecting the known world points
through `PinholeCamera` lands on the recorded pixels; a systematic offset means a
frame or sign error.

Mount the camera rigidly. A camera that moves by a millimetre changes the
intercept by a millimetre or more. Avoid a mount that flexes when the arm moves.

## 4. Capture latency

`UvcCamera` timestamps a frame when `read()` returns it. The exposure happened
earlier: sensor readout, USB transfer and driver buffering all add delay. At
9 m/s, **10 ms is 9 cm**, so this is not a rounding error.

Measure it before trusting the timing:

- flash an LED at a known instant and record the frame in which it appears; or
- drop a ball past two known heights with a photogate, compare the camera's
  arrival times with the free-fall solution; or
- use a camera that exposes a hardware timestamp and compare it with the shared
  high-resolution clock (`tennisrobot.clock.now`). Do not use
  `time.monotonic()` on Windows; it has roughly 15.6 ms granularity there.

Set `camera.latency_s` to the measured delay; `CameraSource` subtracts it from
each observation timestamp. A negative or unmeasured value should be left at 0
and treated as a known bias in the error budget.

The camera's **exposure** also matters: a long exposure blurs the ball and biases
the centroid backwards along its path. Use manual exposure and short pulses. See
[`FEASIBILITY.md`](FEASIBILITY.md).

## 5. Arm base pose

Measure the Epson base origin and the direction of base +X in world. Set
`arm.base_pose = [x, y, z, roll, pitch, yaw]` so that this pose maps base
coordinates to world coordinates. The default assumes base +X = world +Y.

Validate independently in RC+ at slow speed:

1. Command the tool to a point at base (500, 0, 500) mm.
2. Measure that point in world with a tape/plumb line.
3. Transform the measured world point into base with `arm.base_pose`; it should
   match the commanded point within a few millimetres.

Do not compensate a base-pose error by nudging the camera or the strike plane.
Every downstream calculation will inherit the mistake.

## 6. Racket mount and impact point

The racket frame is:

- origin at the **butt cap**;
- **+Z** up the shaft towards the tip;
- **+Y** out of the string bed (the face normal);
- **+X** across the strings.

`racket.mount_pose` is the rigid transform **flange → butt**. The identity means
the butt is at the flange origin and the shaft points along the flange +Z; a real
clamp almost certainly differs.

Measure:

1. **Translation** from the flange origin to the butt cap, in the flange frame
   (metres).
2. **Rotation** of the shaft relative to flange +Z, and the direction of the face
   normal. Use CAD if the mount is designed, or a pointer and a protractor on the
   real assembly.
3. **Impact point:** the intended contact point measured from the butt, in the
   racket frame. The default `[0, 0, 0.52]` is the 520 mm string-bed centre from
   the Tennis Buddy racket. Verify it on the physical racket; if the chosen point
   is off-centre, record the lateral offset in `impact_point_m[0]`.

The face normal must point out of the **same side** of the strings that the
planner assumes. If the racket is flipped in its mount, rotate `mount_pose` by
180° about the shaft, or the planner will present the frame instead of the
strings.

### Verification without a ball

Put a small target (a tee, a pointer or a ball on a stand) at a chosen world
point. Compute the flange pose with a short script:

```python
import numpy as np
from tennisrobot.config import load_config
from tennisrobot.racket import Racket

cfg = load_config("config/uno_q.toml")
racket = Racket(cfg.racket)
flange = racket.flange_for_impact(
    np.array([0.0, 0.58, 0.9]),
    np.array([0.0, 1.0, 0.0]),
    np.array([0.0, 0.0, 1.0]),
)
print(flange.pose6())
print((cfg.arm.base_transform().inverse() @ flange).pose6())
```

Command that pose **in RC+ at slow speed**, not through this framework, and check
that the marked string-bed point touches the target. Repeat at five intercepts
across the envelope. This validates the mount, impact point, base pose and Euler
conversion together.

## 7. Epson Euler convention

The Python side converts a rotation matrix to `[roll, pitch, yaw]` with
`R = Rz(yaw) · Ry(pitch) · Rx(roll)` (`geometry.matrix_to_euler_zyx`). Epson's
`U, V, W` convention may be different for your controller/RC+ version.

Test it with a pose that isolates one axis:

1. Command a flange pose with roll = 20°, everything else 0.
2. Observe the rotation axis on the real tool.
3. Repeat for pitch and yaw.

If the axes or order differ, change `matrix_to_euler_zyx` / `euler_zyx_to_matrix`
(or add a conversion in `arm.py`) and update the tests. Do this **before** the
end-to-end impact test.

## 8. End-to-end check

1. Place a ball on a tee at the nominal strike point.
2. Run monitor mode: `python -m tennisrobot run --config config/uno_q.toml --monitor`.
3. Check that the detector reports the ball and the fit is stable. The reported
   intercept should be the tee's position (the ball is stationary, so the
   estimator's balloon will not fit; use the detector overlay or a recorded
   frame instead).
4. At slow speed in RC+, command the computed flange pose and confirm contact at
   the marked point.
5. Only then bring in the ball machine.

## 9. Record the calibration

Write down, at minimum:

```
date:
camera serial / lens / focus:
image resolution:
intrinsics: fx fy cx cy k1 k2 p1 p2, RMS
camera pose: x y z roll pitch yaw, reprojection check
latency_s:
arm base pose:
racket mount pose:
impact point:
Euler convention verified: yes/no
envelope boxes: impact / flange
```

Keep it with the robot. A calibration that is not recorded will be lost the first
time someone bumps the camera.

## Safety

All calibration motion is slow, attended and inside a guarded cell. The E-stop
must be functional before the first powered move. See [`SAFETY.md`](SAFETY.md).

# Smart racket robot test plan — incomplete

## Assumptions and information to measure

- SWEETSPOT_OFFSET_M = 0.50 m is the user's initial estimate from the sensor along racket +x. Measure it on each racket. The older TennisRobot project assumes 0.52 m from the butt cap, which is not necessarily the sensor position.
- The flange-to-sensor translation and rotation, racket dimensions, ball position, ball mount, table and arm clearances, and full swept-volume envelope are unknown. No numeric safe envelope can be inferred from the arm's catalog reach. Record these measurements before creating points.
- World +z is up and +x points toward the net; define +y to form a right-handed frame. Racket +x points to the tip, +y across the face, +z normal to the face; confirm the physical positive sides. The prior TennisRobot project uses different racket axes; do not reuse its transforms without conversion.
- Face angle, swing path angle, handedness, tap side, and their sign conventions are not yet defined. All unmeasured manifest values are null, not zero.
- A 1 kHz IMU records gyro and low/high-g acceleration; check which racket and mount were used for every run. Confirm correct sensor orientation and calibration.
- The controller model, logging options, timestamp resolution, achievable actual-position sampling rate, and sync-event time source must be checked. No 100 Hz capability is claimed.
- The 0.661 lb prior figure is not enough to establish payload safety. Measure total mounted mass, center of mass relative to flange, and moments of inertia about the wrist axes, including mount and racket.

## Status

This is a test inventory, not a runnable robot program. No paths, tool definitions, collision-free envelope, controller logging, contact timings, or simulator results have been verified here. Do not run the older `TennisRobot/epson/racket_moves.prg` on the physical arm: its comments identify an unreachable home and a collision indication at a contact point. The present manifest lists 42 proposed tests. Each null requires a measured or engineered value; a null must never be read as zero.

### Existing simulator inspection (2026-10-28)

The open RC+ 7.5.4A project `RacketSim_20261025` is connected to the **Simulator** virtual controller, in Dry Run, and identifies robot 1 as C8-A901S. Its 3D layout includes `CAD_1 (Mounted Device)`, visibly the racket assembly. The CAD object property display showed position X=24, Y=60, Z=773 mm and rotation X=180, Y=0, Z=-90 degrees at the inspected pose, with unit millimetres and scale 1.000. These are displayed CAD placement properties, not an established flange-to-IMU transform or a sweet-spot tool definition. The screenshot shows no ball fixture; the layout tree also contains `SPlane_1` and table objects. The prior points are not validated safe trajectories. Physical mounting, sensor position and cell geometry still require confirmation.

Earlier simulator work in `TennisRobot/docs/SIM_FINDINGS.md` describes the racket as mounted on J6, approximately along flange +Y, and a provisional Tool 1 at (0, 450, 0) mm in flange coordinates, with its displayed origin near the string-bed centre. This is a useful starting estimate for the simulated sweet spot, not a measured sensor transform. The earlier saved simulator object data shows CAD collision-pair checks disabled; verify the current simulator collision settings before treating the absence of a red indication as clearance evidence. The earlier report also documents a red arm collision at an alternative P2 branch.

## Verified catalog values

Epson's C8L C8-A901 data sheet lists wrist maximum joint speeds J4 450 deg/s, J5 450 deg/s, and J6 720 deg/s. It lists a 901 mm P-point reach, 981 mm flange reach, maximum payload 8 kg, and allowable moments of inertia J4/J5 0.47 kg m² and J6 0.15 kg m². These are machine ratings, not path-speed predictions or safe operating limits. Joint speeds combine through configuration-dependent kinematics. A commanded percentage is not a measured peak; record achieved speeds from the trajectory. The 8 rad/s classification boundary is 458.4 deg/s.

Sources: https://files.support.epson.com/far/docs/epson_c8_6-axis_robots.pdf and https://download.epson-europe.com/robotics/Manuals/Software/EPSON%20RC%2B%207.0_SPEL%2B_r9.pdf .

## Setup and sequence to implement

1. Confirm the RC+ status is Virtual Controller before simulation; never connect this computer to the real controller for this task. Copy the simulator project before editing it, subject to the earlier project-copy instruction. Check the arm, racket attachment and obstacles in all views.
2. Measure the transform T_flange_sensor, with translation in metres and a right-handed rotation. Set T_sensor_sweetspot to a translation of (0.50, 0, 0) m with the same orientation, subject to measurement. Then T_flange_sweetspot = T_flange_sensor × T_sensor_sweetspot. Enter the two TLSet definitions using the installed version's tool convention; convert translation to mm. Verify each tool visually using known poses. A tool TCP does not itself provide collision detection for the racket.
3. Establish a cell-specific bounding region and exclusion volumes for the complete robot, racket, mount, ball fixture and stopping motion. Test full trajectories and robot configurations, not just endpoints. Record the region and clearance margins before describing it as reachable or safe. Check singularities and joint range. Validate payload, COM and inertia in the controller.
4. Default proposed joint settings: Power Low, Speed 20, Accel 20, 20. Linear speed and acceleration require separately named values in the controller's actual units. A dry run must use no ball and lower, separately checked settings; software settings do not replace the cell safety system. Step up only after measured data and clearance review.
5. For each repetition: begin recording, hold 1 s, command a short racket-x twitch and record its command event timestamp, hold 1 s, start the path with a second timestamp, run the path, pause, return to a verified home. Verify that the twitch produces a distinct gyro feature; no numeric amplitude or joint is defined until mount geometry is known. The actual IMU event and command time differ by actuator and clock latency.
6. First run static and no-contact paths; then, separately, qualify the ball fixture and contact paths. All five volley offsets need measured values in cm. Contact timing is relative to path start; record actual contact independently if possible. Tap tests need a separate safe fixture and a verified method; the arm cannot tap its own rigidly attached handle without another contact surface.

## Logging contract

One CSV per repetition named `<path_id>_rep<NN>_<racket>.csv` with racket as E35E or E912. Recommended columns: `time_s,j1_rad,j2_rad,j3_rad,j4_rad,j5_rad,j6_rad,tcp_x_m,tcp_y_m,tcp_z_m,qw,qx,qy,qz`. The position and orientation are the actual sweet-spot TCP in the stated world frame; quaternion is unit length, w first. Establish whether controller readings are encoder-derived actual positions or command positions before labeling them actual. Record sampling timestamps, dropped samples, units, tool and world-frame definitions, transform, controller version, source and timestamp latency in a sidecar JSON. Save `sync_command_time_s` and `path_start_command_time_s` against the same trajectory timebase, with their precision and trigger mechanism. Retain raw data and do not interpolate missing readings without labeling them. Measure the actual cadence and gaps; do not assume nominal polling reaches 100 Hz.

Run `python robot/check_trajectory.py <csv-file>` to check the column order, finite values, unit quaternions, monotonic timestamps and sampling gaps, and estimate TCP and angular speeds from adjacent samples. Unwrap joint angles first; peaks depend on sample rate, gaps and noise. This checks an existing export; it does not acquire data or prove that the samples are actual positions. A mean rate of 100 Hz does not rule out gaps.

## Simulator work remaining

Build one function per path and a repetition runner once points and frames are established. Test the full sequence in the virtual controller, including sync, slow dry runs, clearances and timing. Verify that each actual-data source and event timestamp work before exporting logs. Simulator output is not proof that the physical workcell is safe or that a controller has the same logging capability.

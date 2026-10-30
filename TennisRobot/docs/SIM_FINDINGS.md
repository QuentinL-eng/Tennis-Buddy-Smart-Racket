# Epson RC+ simulator findings

Updated: 2026-10-26. Work is incomplete; no real robot was connected.

## Project and build

The active native copy is the RacketSim project in Epson RC+ 7.0. The baseline is sim-work/baseline/SimulationTest, with SHA256.json. Original Main.prg, Test1.prg, racket_moves.prg and robot point files were checked against the baseline and remained unchanged. Only the copied project's racket_moves.prg was edited. The repo version matches that copy.

The final source compiled without errors on RC+ 7.5.4A R1. Function names are unique in the copied project. main remains empty. No automatic Motor On was added. All motion tests used Power Low and Speed 20. Virtual motors were enabled manually and turned off after testing. No system/controller configuration, license, password, communication profile or joint limit was changed.

## Attachment and TCP

CAD_1 is a Mounted Device on Robot 1, Joint 6. Existing offsets remain X24, Y-520, Z871 mm; rotations 180,0,-90. The inspected STEP was the latest found in Downloads; another mount export was not supplied.

Small jogs of J6 (+1.050 deg), J4 (+1 deg) and J5 (+1 deg) showed the racket following the wrist rigidly. These jogs showed no red collision indication. The joints were returned before target tests.

The existing geometry places the racket axis along flange +Y, transverse to flange Z. Tool 1 was changed in Robot Manager from (0,0,450,0,0,0) to (0,450,0,0,0,0). Its displayed origin is near the string-face centre. The 450 mm length remains approximate; no exact CAD centre measurement was obtained. This corrects the TCP to the existing mount; it does not realign the CAD along flange Z.

Historical teaching tool cannot be determined from robot1.pts. All target tests explicitly use Tool 0, consistent with the protocol's flange-pose convention. No saved point was converted or overwritten.

## Reach and collision results

Original points: P0=(-550,-400,500,90,0,0), P2=(-550,0,500,90,0,0), P1=(-550,700,500,90,0,0).

- Original P0 is unreachable with Tool 0 in all eight hand/elbow/wrist branches tested. PAgl(P0,5)=-142.702 deg. Go P0 and Go P0 LJM 3 both produced error 4001, Joint 5 motion limit. LJM 3 did not solve it.
- Original P2 with its stored flags fails TargetOK. P2 /B passes TargetOK and completed at exactly (-550,0,500,90,0,0), Righty/Below/NoFlip. C8 upper-arm/elbow geometry turned red during this test. The exact collision pair was not identified. This branch is now disabled in racket_check_contact, and the arc test remains disabled.
- Original P1 passes TargetOK with Tool 0. It was not moved to, and its path/collisions remain unverified.
- Replacing V and W with -90 deg, while retaining U90 and all XYZ values, makes all three points pass TargetOK. Separate racket_alt_home/contact/post functions preserve the saved points.
- racket_alt_home completed at P0 XYZ with alternative V/W=-90. The red collision display inherited from the previous test persisted; Reset Collision cleared it at the stationary alternative home pose. No red geometry remained after reset. This does not prove the path from the previous colliding pose was clear.
- Alternative contact and post functions compiled but have not been run.

racket_home now prints BLOCKED for the unreachable original P0 instead of attempting it. The original sweep and linear/Pass variants are guarded by TargetOK. No complete swing has been validated.

## Payload

User supplied mass 0.661 lb = 0.299825 kg. Applied Weight 0.300 on the Virtual Controller; command readback confirmed 0.300, 0.000. User supplied COM (-300, 0, 0) mm relative to the racket head centre. Assuming negative model X points toward the handle, the approximate 450 mm head offset implies COM about flange (0, 150, 0) mm with the current mounting. Axis mapping and distances remain provisional. Existing inertia is 0.0300 kg*m^2 and eccentricity 0 mm; these remain unchanged and unverified. Need inertia values, units, reference point and confirmation of the COM direction before applying them. A TCP length is not an inertia or eccentricity measurement. The Weight length field is SCARA-only and disabled for C8.

## Speeds and Pass

No contact speed was measured. No speed increase above 20 was attempted. Arc and Y-sweep cannot yet be compared. Pass approaches its waypoints; it does not guarantee passage through the contact point. TCPSpeed reports CP tool speed and returns zero for PTP Go/Pass, so it cannot directly measure the proposed joint arc. A validated tool-centre trace versus simulator time, or an appropriate monitor, is still required.

## Socket server

Read-only inspection of System Configuration > Controller > TCP/IP showed logical port 201 in Simulated mode, TCP port 2000, CRLF termination, timeout 0. Settings were left unchanged. The user guide describes dummy communication files for Simulated ports and a Real mode for actual sockets. Enabling Real mode or executing SetNet would change prohibited controller settings. No TCP PING/PONG was performed. strike_server.prg remains an uncompiled reference skeleton and was not added to the project.

Manual-checked future syntax: OpenNet #201 As Server; WaitNet #201, 5; Input #201 with 22 numeric fields; Print #201 with one concatenated string and no trailing comma; Trim$(Str$(seq)); Wait uses seconds. SetNet requires host/address as well as TCP port. Its configuration write was not executed. The skeleton's Function main duplicates main; Speed 150 is invalid percentage, Move needs SpeedS, and XY is the coordinate constructor. These are pending fixes, not completed work.

## Errors and recovery

- Initial backup encountered locked SimulationTest.dat. A complete persistent-file baseline was made after closing the source project.
- Earlier original program referenced undefined P10 and produced error 7007.
- Home tests produced error 4001, Joint 5 motion limit.
- Restart left motors off; a test produced error 4031. Motors were then enabled manually in the Virtual Controller.
- RC+ reported protected-memory exceptions after the first runtime error. A normal restart restored the editor/debugger. Pasting CRLF source with paste preserved the multiline editor display.
- The screenshot toolbar's camera icon opens Add Camera. That dialog was cancelled; no camera was added. Screenshot is the monitor icon.
- A local PDF text extraction hit a console Unicode encoding error; UTF-8 extraction succeeded.

## Manual checks and limits

Reference: installed English e_SPEL+Ref75_r8.pdf and e_EPSONRC+UsersGuide75_r9.pdf. Commands reviewed include Robot, Power, Speed/Accel, SpeedS/AccelS, Tool/TLSet, Go/LJM, TargetOK/PAgl, Wait, Move CP, Pass, Agl/JA, Weight/Inertia, Print and network commands above. Executable motion source also passed the RC+ compiler. Disabled arc commands have not been validated in motion.

Simulator timing is approximate. It does not validate real torque, overload, mount stiffness, impact load, cable routing, vibration, actual contact speed, braking, controller/network timing or collision clearance at hardware accuracy. Re-measure TCP, mass/COM/inertia, swept volume, speeds/accelerations, contact timing, stop distance and socket/watchdog behaviour on the real cell before operation.

## Evidence and next work

Screenshots in sim-work: racket_attached_jog.bmp, P2_collision_tool1.bmp, P0_alternative.bmp. Epson saved PNG bytes under .bmp names; delivery copies have .png suffixes.

Next: obtain measured mass properties; test alternative contact/post poses and the entire path at Speed 20 after clearing collision history; identify any collision pair; then validate swings and measurement before speed increases. Socket configuration needs a separately authorised exception before an actual localhost TCP test. Ball tracking and planner work were not started.

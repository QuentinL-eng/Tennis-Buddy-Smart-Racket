# Epson RC700-E integration

[`strike_server.prg`](strike_server.prg) is a **reference skeleton** for the
controller side. It has not been compiled or run on an RC700-E. Every SPEL+
command in it must be checked against the language reference for your RC+
version before it is allowed to move a real arm.

The architecture decision is deliberate: **motion stays on the controller**. The
UNO Q sends three flange poses, a speed and a lead time; the controller's own
motion planner executes the sweep. The Linux side never streams Cartesian or
joint targets at servo rate.

## Why not use the Epson Remote Control service?

It is another valid route, but its port, authentication and `$Login`/`$Execute`
syntax vary by RC+ version and could not be verified for this controller. A small
OpenNet socket server in SPEL+ keeps the protocol and the timing contract under
our control. If you prefer Remote Control, implement `ArmBackend` in
`src/tennisrobot/arm.py` and keep the same high-level contract.

## What the reference does

1. Opens a server socket on logical port `#201`.
2. Reads a fixed 22-field comma-separated line into `op, seq` and 20 numeric
   fields.
3. Handles `PING` (reply `PONG`), `ABORT` (reply `ACK`) and `STRIKE`.
4. For a strike, checks a hard-coded base-frame envelope and speed/lead ranges.
5. Moves to the pre-swing pose at a slow speed.
6. Waits for `lead_ms − approach_ms`.
7. Moves through the strike pose to the post pose at the commanded speed.
8. Replies `ACK` before the motion and `DONE` after it.

## What you must change

- **`SetNet` / `OpenNet`**: argument order, logical port and TCP port.
- **`Input` / `Print`**: comma-separated numeric input and line output; verify
  `Str$` concatenation and the line terminator.
- **`Wait`**: seconds or milliseconds for your version.
- **`Speed`**: mm/s; verify it is the linear tool speed you expect.
- **`U, V, W`**: the Euler convention. The Python side uses
  `R = Rz(yaw)·Ry(pitch)·Rx(roll)`. Validate with a single-axis pose.
- **`approach_ms`**: measured, not guessed. Start much slower than you think.
- **Envelope**: replace with the real cell's restricted volume, including the
  racket head and the ball machine. The reference checks only the flange poses.
- **Motor state**: do not add an automatic motor-on. Drive enabling is an
  operator action.
- **Watchdog**: the reference does not implement one. Add a controller-side
  timeout or a hardware interlock.

## Timing

The socket protocol specifies a lead relative to command receipt. The reference
approximates the swing by waiting before the final `Move`. This is not a
calibrated trajectory: acceleration, blending and controller motion planning all
affect when the racket actually crosses the strike pose.

Measure it:

- Put a marker on the racket and film at 240+ fps.
- Command a slow strike with a known lead.
- Measure the time from `ACK` to the marker crossing the intended pose.
- Adjust `approach_ms`; keep the speed constant.

For repeatable timing, trigger the swing from a hardware input or a controller
timer rather than a socket wait. If you need a mid-motion abort, move the socket
handling into a separate SPEL+ task and add an interlock; do not assume the
single-task reference can stop inside `Move`.

## Testing order

1. `python tools/fake_arm.py --port 12000` — test the Linux client and protocol.
2. RC+ simulator, if your licence provides it — compile and exercise the server
   without a real arm.
3. Real controller, drives disabled or arm in a safe pose — `PING`/`PONG` only.
4. Real controller, monitor mode from the UNO Q — heartbeats and RTT.
5. First slow `STRIKE` with a clear cell and the E-stop held by a second person.
6. Only then a ball.

## Protocol details

See [`../docs/PROTOCOL.md`](../docs/PROTOCOL.md) for field indices, replies, the
timing contract, heartbeat behaviour, error codes and the security warning.

## Safety

The socket `ABORT` is not an emergency stop and the reference server cannot read
it during a `Move`. The RC700-E safety circuit, a hardwired E-stop, guarding and
a restricted envelope are mandatory. Read [`../docs/SAFETY.md`](../docs/SAFETY.md).

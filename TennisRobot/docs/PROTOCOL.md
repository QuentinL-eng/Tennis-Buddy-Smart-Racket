# Arm protocol

The UNO Q talks to a socket server running in SPEL+ on the RC700-E. Motion stays
on the controller. The protocol is ASCII, newline-delimited, fixed-width and
deliberately boring: one command in flight, one small response.

This is **not** the Epson Remote Control service. Epson's remote-control
interface uses different commands and its exact syntax/port varies by RC+
version. This framework defines its own server so the timing contract, heartbeat
and error handling are explicit. The reference server is
[`epson/strike_server.prg`](../epson/strike_server.prg) and is **unverified
SPEL+**; see the validation checklist below.

## Transport

| Property | Value |
|---|---|
| TCP port | `12000` (configurable; `arm.port`) |
| Encoding | ASCII |
| Framing | one command per line, LF terminated |
| Fields | comma-separated |
| Field count | exactly 22 for every command |
| Sequence | positive integer, incrementing per connection |
| Concurrency | one outstanding strike per arm |

A fixed field count matters because SPEL+ reads the whole line with one `Input`
statement. `PING` and `ABORT` therefore carry twenty zero fields instead of
shortening the line.

## Command fields

| Index | Field | Unit | Meaning |
|---:|---|---|---|
| 0 | opcode | — | 1 = strike, 2 = abort, 3 = ping |
| 1 | sequence | — | incrementing command id |
| 2–7 | pre pose `x,y,z,u,v,w` | mm, deg | pre-swing flange pose |
| 8–13 | strike pose | mm, deg | flange pose when the racket point meets the ball |
| 14–19 | post pose | mm, deg | follow-through flange pose |
| 20 | speed | mm/s | racket (flange) speed through the strike |
| 21 | lead | ms | time from command receipt to the intended strike |

Poses are in the **Epson base frame**, already converted by the Linux side. The
`u, v, w` rotations follow the controller's convention; verify it
([`CALIBRATION.md`](CALIBRATION.md)). The client sends **flange** poses, not the
racket point: the racket point is solved on the Linux side using the measured
mount.

Example strike (values shortened for readability, but a real line has all 22
fields):

```
1,17,340.0,-100.0,380.0,0.000,0.000,0.000,580.0,-100.0,380.0,...,2190.0,352
```

`PING`/`ABORT`:

```
3,18,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
2,19,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
```

## Replies

| Reply | Meaning |
|---|---|
| `ACK,<seq>` | command accepted; for a strike, motion is being scheduled |
| `DONE,<seq>` | the strike motion finished |
| `ERR,<seq>,<code>` | command rejected or failed; the pipeline faults |
| `PONG,<seq>` | heartbeat reply |

The client ignores unknown reply types (forward compatibility) and matches
replies to the pending sequence. A strike is considered complete only on `DONE`.
No `DONE` within `arm.response_timeout_s` faults the run.

Reference error codes (documentation only; the client shows the raw line):

| Code | Meaning |
|---:|---|
| 1 | malformed command (wrong field count; used by the test double) |
| 3 | unknown opcode |
| 11–17 | pose outside the controller-side envelope |
| 21 | speed outside the controller-side range |
| 22 | lead outside the controller-side range |

## Timing contract

There is **no shared clock**. The client sends a relative lead:

1. The planner computes the intended strike time on the shared high-resolution
   clock (`tennisrobot.clock.now`, i.e. `time.perf_counter()`).
2. The client subtracts half the measured round-trip time:
   `lead = strike_time − now − rtt/2`.
3. The controller receives the command at some later instant and must start its
   swing so the racket crosses the strike pose `lead` milliseconds after receipt.
4. The controller returns `ACK` immediately and `DONE` when the motion finishes.

The half-RTT correction assumes a symmetric path. The client maintains an EWMA
(`0.8 old + 0.2 new`) of `PONG` latency. On a quiet, wired network this is tens of
milliseconds; on Wi-Fi it is unpredictable. Use wired Ethernet.

**The controller's own timing is the hard part.** The reference SPEL+ program
moves to the pre-swing pose, waits for `lead_ms − approach_ms`, then sweeps. It
cannot know its true acceleration profile. Measure `approach_ms` externally at
low speed and keep the speed constant, or trigger the swing from a hardware input
for repeatable timing. Do not assume the reference's timing is accurate.

## Heartbeat and failure

- The client sends `PING` every `arm.heartbeat_s` (default 250 ms) whenever it
  has not otherwise transmitted.
- The client faults after `max(1 s, 4 × heartbeat)` of silence.
- The reference server does **not** implement a controller-side watchdog. Add one
  (or a hardware interlock) before relying on the link: a dead UNO Q must not
  leave the controller waiting to move.
- The reference server is single-task. While it is inside `Move`, it is not
  reading the socket; `ABORT` and `PING` are seen only between motions. A
  separate communication task on the controller would be needed for a real
  mid-motion abort. **The E-stop remains the reliable stop.**
- Closing the socket does not stop the controller.

## Validation checklist for the SPEL+ server

Do not skip this because the program "looks right". The file is a skeleton and
has never been compiled on a real RC700-E.

- [ ] Confirm the controller model, RC+ version and SPEL+ language reference.
- [ ] Verify `SetNet` / `OpenNet` argument order and the logical port number.
- [ ] Verify that `Input #201, ...` parses comma-separated numeric fields into
      the variables in order.
- [ ] Verify `Print #201, "ACK," + Str$(seq)` emits one line with no extra
      separators, tabs or quoting.
- [ ] Verify `Wait` units (seconds vs milliseconds) for your version.
- [ ] Verify `Speed` units and whether `Move`/`Go` use joint or linear motion.
- [ ] Verify the `U, V, W` rotation convention against [`CALIBRATION.md`](CALIBRATION.md).
- [ ] Confirm the controller rejects unreachable/unsafe poses before motion.
- [ ] Confirm motor-on state is controlled by the operator, not by this program.
- [ ] Add a controller-side heartbeat timeout or hardware interlock.
- [ ] Test with the arm in a safe, slow, empty cell before a ball is involved.

## Testing without a controller

The test double implements the protocol and prints strikes:

```bash
python tools/fake_arm.py --port 12000 --delay 0.05 --verbose
```

In another terminal, check a heartbeat:

```bash
python - <<'PY'
import socket
s = socket.create_connection(("127.0.0.1", 12000))
s.sendall(b"3,1," + b",".join([b"0"] * 20) + b"\n")
print(s.recv(200))
s.close()
PY
```

Then point `config/uno_q.toml` at the test double's host/port and run monitor
mode. This exercises connection, heartbeat, RTT estimation and (if you arm it
with a simulated camera) the full strike request. The test double does not move
anything and is not a safety device.

`tests/test_arm.py` covers the same handshake and strike path automatically.

## Security

The protocol has no authentication, integrity or encryption. Anyone who can reach
the port can request motion. Keep it on an isolated control network, restrict
access at the switch/firewall, and never expose it to the internet.

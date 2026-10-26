#!/usr/bin/env python3
"""Test receiver for the TennisCamera observation stream.

Standard library only. Reads fixed 40-byte packets and prints what the stream is
doing: observation rate, packet interval spread, sequence gaps, the latest
detection and the app's once-per-second status packets.

Two transports, because ``iproxy`` already owns the host port:

    # USB-C through iproxy (the normal case). iproxy listens on 5000 and
    # forwards to the phone's port 5000, so this end connects to it.
    iproxy 5000 5000 &
    python3 tools/iproxy_receiver.py --connect

    # Anything that reaches this host directly: listen for the app.
    python3 tools/iproxy_receiver.py --listen --port 5000

``--listen`` is the default. Only one process can bind a port, which is why the
``--connect`` form exists; the tunnel is the server side.

Then launch TennisCamera on the phone and press Start. The receiver accepts one
client at a time and reconnects if the tunnel drops.

This is a test harness, not the robot. It never commands motion.
"""

from __future__ import annotations

import argparse
import collections
import json
import socket
import struct
import sys
import time
from typing import Deque, Optional

PACKET = struct.Struct("<I B B H I Q f f f f H H")
PACKET_SIZE = PACKET.size
MAGIC = 0x424F5254
VERSION = 1
HEADER_SIZE = 40

KIND_OBSERVATION = 0
KIND_STATUS = 1
# Phone-side 3D tracker. Kinds 2 and 3 reuse the same 40-byte layout: x, y, z in
# the camera frame (metres) and one extra scalar (fit RMS, or time to the plane).
# A receiver that only knows kinds 0 and 1 can ignore them.
KIND_STATE = 2
KIND_INTERCEPT = 3

THERMAL = {0: "nominal", 1: "fair", 2: "serious", 3: "critical"}

WINDOW_NS = 1_000_000_000
MAX_INTERVALS = 512


class Summary:
    """Rolling measurements for one connection."""

    def __init__(self) -> None:
        self.packets = 0
        self.observations = 0
        self.statuses = 0
        self.states = 0
        self.crossings = 0
        self.parse_errors = 0
        self.seq_gaps = 0
        self.max_gap = 0
        self.seq_resets = 0
        self._expected_seq: Optional[int] = None
        self._last_obs_ns: Optional[int] = None
        self._arrivals: Deque[int] = collections.deque()
        self._intervals_ms: Deque[float] = collections.deque(maxlen=MAX_INTERVALS)
        self._offsets_ms: Deque[float] = collections.deque(maxlen=MAX_INTERVALS)
        self._state_history: Deque[tuple] = collections.deque(maxlen=8)
        self.latest: Optional[dict] = None
        self.latest_status: Optional[dict] = None
        self.latest_state: Optional[dict] = None
        self.latest_crossing: Optional[dict] = None
        self.frame_size: Optional[tuple[int, int]] = None

    # -- ingestion ---------------------------------------------------------

    def add(self, fields: dict, arrival_ns: int) -> None:
        seq = fields["sequence"]
        if self._expected_seq is not None:
            if seq < self._expected_seq:
                self.seq_resets += 1
            elif seq > self._expected_seq:
                gap = seq - self._expected_seq
                self.seq_gaps += gap
                self.max_gap = max(self.max_gap, gap)
        self._expected_seq = seq + 1

        self.packets += 1
        offset_ms = (arrival_ns - fields["t_capture_ns"]) / 1e6
        self._offsets_ms.append(offset_ms)
        self.frame_size = (fields["width"], fields["height"])

        if fields["kind"] == KIND_OBSERVATION:
            self.observations += 1
            self._arrivals.append(arrival_ns)
            if self._last_obs_ns is not None:
                self._intervals_ms.append((arrival_ns - self._last_obs_ns) / 1e6)
            self._last_obs_ns = arrival_ns
            self.latest = fields
        elif fields["kind"] == KIND_STATUS:
            self.statuses += 1
            self.latest_status = fields
        elif fields["kind"] == KIND_STATE:
            self.states += 1
            self.latest_state = fields
            self._state_history.append(
                (fields["t_capture_ns"], (fields["u"], fields["v"], fields["radius"]))
            )
        else:
            self.crossings += 1
            self.latest_crossing = fields

    # -- measurement -------------------------------------------------------

    def observation_rate(self, now_ns: int) -> float:
        while self._arrivals and now_ns - self._arrivals[0] > WINDOW_NS:
            self._arrivals.popleft()
        return float(len(self._arrivals))

    def interval_stats(self) -> tuple[float, float]:
        return percentile(self._intervals_ms, 0.5), percentile(self._intervals_ms, 0.95)

    def offset_stats(self) -> tuple[float, float, float]:
        if not self._offsets_ms:
            return 0.0, 0.0, 0.0
        return (
            min(self._offsets_ms),
            percentile(self._offsets_ms, 0.5),
            percentile(self._offsets_ms, 0.95),
        )

    def status_line(self, now_ns: int) -> str:
        med, p95 = self.interval_stats()
        latest = self.latest
        if latest is not None:
            point = (
                f"u={latest['u']:.1f} v={latest['v']:.1f} "
                f"r={latest['radius']:.1f} c={latest['confidence']:.2f}"
            )
        else:
            point = "no detection yet"
        size = f"{self.frame_size[0]}x{self.frame_size[1]}" if self.frame_size else "size ?"
        flight = ""
        state = self.latest_state
        if state is not None:
            speed = self._speed_m_s()
            flight = (
                f"  |  3D {state['u']:5.2f} {state['v']:5.2f} {state['radius']:5.2f} m  "
                f"rms {state['confidence']:.2f} px"
            )
            if speed is not None:
                flight += f"  {speed:5.2f} m/s"
        crossing = self.latest_crossing
        if crossing is not None:
            flight += (
                f"  -> {crossing['u']:5.2f} {crossing['v']:5.2f} m "
                f"in {crossing['confidence'] * 1000:4.0f} ms"
            )
        return (
            f"obs {self.observation_rate(now_ns):6.1f}/s  "
            f"dt med {med:5.2f} p95 {p95:5.2f} ms  "
            f"gaps {self.seq_gaps}  {point}  {size}{flight}"
        )

    def _speed_m_s(self) -> Optional[float]:
        """Speed from two consecutive state packets.

        The packet carries position and RMS only, so speed is a difference over
        the capture-time delta rather than a field of its own.
        """
        if not self._state_history or len(self._state_history) < 2:
            return None
        (t0, p0), (t1, p1) = self._state_history[-2], self._state_history[-1]
        dt = (t1 - t0) / 1e9
        if dt <= 0:
            return None
        dx = p1[0] - p0[0]
        dy = p1[1] - p0[1]
        dz = p1[2] - p0[2]
        return (dx * dx + dy * dy + dz * dz) ** 0.5 / dt

    def report(self) -> str:
        med, p95 = self.interval_stats()
        omin, omed, op95 = self.offset_stats()
        lines = [
            "",
            "--- summary ---",
            f"packets {self.packets} "
            f"(observations {self.observations}, status {self.statuses}, "
            f"3D states {self.states}, intercepts {self.crossings}), "
            f"parse errors {self.parse_errors}",
            f"sequence gaps {self.seq_gaps} (largest {self.max_gap}), "
            f"sequence resets {self.seq_resets}",
            f"observation interval median {med:.3f} ms, p95 {p95:.3f} ms",
            "arrival_ns - t_capture_ns (clock-offset contaminated, not latency): "
            f"min {omin:.1f} ms, median {omed:.1f} ms, p95 {op95:.1f} ms, "
            f"spread {op95 - omin:.1f} ms",
        ]
        if self.latest_status is not None:
            s = self.latest_status
            lines.append(
                "last status: "
                f"capture {s['u']:.1f} fps, detector {s['v']:.2f} ms, "
                f"dropped {int(s['radius'])}, thermal {thermal_name(s['confidence'])}, "
                f"{s['width']}x{s['height']}"
            )
        return "\n".join(lines)


def percentile(values, fraction: float) -> float:
    """Nearest-rank percentile; 0.0 when there is nothing to measure."""
    if not values:
        return 0.0
    ordered = sorted(values)
    index = int(round(fraction * (len(ordered) - 1)))
    return float(ordered[max(0, min(len(ordered) - 1, index))])


def thermal_name(value: float) -> str:
    index = int(round(value))
    return THERMAL.get(index, f"unknown({value:.0f})")


def decode(raw: bytes) -> Optional[dict]:
    """Validate and unpack one 40-byte record."""
    if len(raw) != PACKET_SIZE:
        return None
    (magic, version, kind, header_size, sequence, t_capture_ns,
     u, v, radius, confidence, width, height) = PACKET.unpack(raw)
    if magic != MAGIC or version != VERSION or header_size != HEADER_SIZE:
        return None
    if kind not in (KIND_OBSERVATION, KIND_STATUS, KIND_STATE, KIND_INTERCEPT):
        return None
    return {
        "kind": kind,
        "sequence": sequence,
        "t_capture_ns": t_capture_ns,
        "u": u,
        "v": v,
        "radius": radius,
        "confidence": confidence,
        "width": width,
        "height": height,
    }


def recv_exact(conn: socket.socket, size: int) -> Optional[bytes]:
    """Read exactly ``size`` bytes, or None on a clean end of stream."""
    buffer = bytearray()
    while len(buffer) < size:
        chunk = conn.recv(size - len(buffer))
        if not chunk:
            return None
        buffer.extend(chunk)
    return bytes(buffer)


def serve(conn: socket.socket, args, jsonl) -> Summary:
    summary = Summary()
    conn.settimeout(0.25)
    last_print = time.time()

    try:
        while True:
            try:
                raw = recv_exact(conn, PACKET_SIZE)
            except socket.timeout:
                raw = b""
            now = time.time_ns()

            if raw is None:
                print("\nclient disconnected; waiting for a new connection")
                break

            if raw:
                fields = decode(raw)
                if fields is None:
                    summary.parse_errors += 1
                    print(f"bad packet: {raw.hex()}")
                else:
                    summary.add(fields, now)
                    if jsonl is not None:
                        record = dict(fields)
                        record["arrival_ns"] = now
                        jsonl.write(json.dumps(record) + "\n")
                    if fields["kind"] == KIND_STATUS:
                        s = fields
                        print(
                            f"status: capture {s['u']:6.1f} fps  "
                            f"detector {s['v']:.2f} ms  "
                            f"dropped {int(s['radius'])}  "
                            f"thermal {thermal_name(s['confidence'])}  "
                            f"{s['width']}x{s['height']}"
                        )

            if time.time() - last_print >= 1.0:
                last_print = time.time()
                print(summary.status_line(now))
    finally:
        try:
            conn.close()
        except OSError:
            pass
    return summary


def self_test() -> int:
    """Exercise the parser and the statistics without a socket."""
    payload = PACKET.pack(MAGIC, VERSION, KIND_OBSERVATION, HEADER_SIZE,
                          1234, 1_600_000_000_123_456_789,
                          640.5, 360.25, 12.5, 0.875, 1920, 1080)
    fields = decode(payload)
    assert fields is not None, "valid packet rejected"
    assert fields["u"] == 640.5 and fields["width"] == 1920

    bad_magic = PACKET.pack(0xDEADBEEF, VERSION, 0, HEADER_SIZE, 1, 0, 0, 0, 0, 0, 1, 1)
    assert decode(bad_magic) is None, "bad magic accepted"
    assert decode(payload[:-1]) is None, "short packet accepted"

    summary = Summary()
    base = decode(payload)
    for i in range(240):
        summary.add(
            {**base, "sequence": 1234 + i, "t_capture_ns": base["t_capture_ns"] + i * 4_166_667},
            1_600_000_000_000_000_000 + i * 4_166_667,
        )
    stats = summary.interval_stats()
    assert summary.seq_gaps == 0, summary.seq_gaps
    assert 4.0 < stats[0] < 4.3, stats
    assert summary.observation_rate(1_600_000_000_000_000_000 + 240 * 4_166_667) > 200

    # Phone-side 3D packets reuse the layout; a receiver that only knows kinds 0
    # and 1 must not treat them as corrupt.
    state_one = decode(PACKET.pack(MAGIC, VERSION, KIND_STATE, HEADER_SIZE,
                                   1, 1_000_000_000, 0.10, -0.20, 2.500, 0.80, 1920, 1080))
    crossing = decode(PACKET.pack(MAGIC, VERSION, KIND_INTERCEPT, HEADER_SIZE,
                                 2, 1_000_000_000, 0.15, 0.05, 1.0, 0.19, 1920, 1080))
    assert state_one is not None and crossing is not None, "3D packet rejected"
    tracker = Summary()
    tracker.add(state_one, 0)
    tracker.add(crossing, 0)
    assert tracker.states == 1 and tracker.crossings == 1, (tracker.states, tracker.crossings)
    assert abs(tracker.latest_crossing["confidence"] - 0.19) < 1e-6

    tracker.add(decode(PACKET.pack(MAGIC, VERSION, KIND_STATE, HEADER_SIZE,
                                   3, 1_001_000_000, 0.10, -0.20, 2.498, 0.8, 1920, 1080)), 0)
    speed = tracker._speed_m_s()
    assert speed is not None and abs(speed - 2.0) < 0.05, speed
    assert "3D" in tracker.status_line(0), tracker.status_line(0)

    print("self-test OK")
    return 0


def parse_args(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--listen", dest="connect", action="store_false",
                      help="listen for the app (default)")
    mode.add_argument("--connect", dest="connect", action="store_true",
                      help="connect to an iproxy tunnel on --host:--port")
    parser.set_defaults(connect=False)
    parser.add_argument("--host", default="127.0.0.1", help="address (default 127.0.0.1)")
    parser.add_argument("--port", type=int, default=5000, help="port (default 5000)")
    parser.add_argument("--jsonl", default=None, help="append every packet to this JSONL file")
    parser.add_argument("--self-test", action="store_true", help="check the parser and exit")
    return parser.parse_args(argv)


def run_session(conn, args, jsonl, total: Summary, label: str) -> None:
    print(f"client connected ({label})")
    summary = serve(conn, args, jsonl)
    total.packets += summary.packets
    total.observations += summary.observations
    total.statuses += summary.statuses
    total.parse_errors += summary.parse_errors
    total.seq_gaps += summary.seq_gaps
    print(summary.report())


def main(argv=None) -> int:
    args = parse_args(argv)
    if args.self_test:
        return self_test()

    jsonl = open(args.jsonl, "a", encoding="utf-8") if args.jsonl else None
    total = Summary()
    listener = None

    if not args.connect:
        listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind((args.host, args.port))
        listener.listen(1)
        print(f"listening on {args.host}:{args.port}; start the app, Ctrl-C to stop")
    else:
        print(f"connecting to the iproxy tunnel on {args.host}:{args.port}, Ctrl-C to stop")
    if jsonl:
        print(f"writing packets to {args.jsonl}")

    try:
        while True:
            if args.connect:
                try:
                    conn = socket.create_connection((args.host, args.port), timeout=2.0)
                except OSError as exc:
                    print(f"  {args.host}:{args.port} not ready ({exc}); retrying")
                    time.sleep(1.0)
                    continue
                run_session(conn, args, jsonl, total, f"tunnel {args.host}:{args.port}")
                time.sleep(0.5)
            else:
                conn, address = listener.accept()
                run_session(conn, args, jsonl, total, f"{address[0]}:{address[1]}")
    except KeyboardInterrupt:
        print("\nstopped")
        print(f"totals: packets {total.packets}, observations {total.observations}, "
              f"parse errors {total.parse_errors}, sequence gaps {total.seq_gaps}")
    finally:
        if listener is not None:
            listener.close()
        if jsonl:
            jsonl.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())

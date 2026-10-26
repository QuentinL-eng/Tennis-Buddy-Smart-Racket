"""Arm adapters.

Two backends share one small contract:

* ``MockArm`` schedules the strike at the planned time with configurable jitter
  and position noise.  It is how the pipeline is tested without a robot.
* ``EpsonArm`` talks to a socket server running in SPEL+ on the RC700-E.  Motion
  stays on the controller; the Linux side sends three poses, a speed and a lead
  time, and never streams servo targets.

Time base: all times are seconds on the caller's monotonic clock.  The controller
receives a lead time relative to receipt, so it does not need a synchronised
clock.  Half the measured round-trip time is subtracted from the lead to account
for the network.  This is only as good as the network jitter; validate it with
the echo test in ``docs/PROTOCOL.md``.
"""

from __future__ import annotations

import socket

import numpy as np

from . import clock
from .config import ArmSpec
from .types import ArmEvent, StrikePlan

OP_STRIKE = 1
OP_ABORT = 2
OP_PING = 3


class ArmError(RuntimeError):
    """The arm refused a command or the link failed."""


class MockArm:
    def __init__(self, spec: ArmSpec, read_only: bool = False, seed: int = 4242):
        self.spec = spec
        self.read_only = read_only
        self.status = "ready"
        self.strikes = 0
        self.aborts = 0
        self._sequence = 0
        self._pending: list[tuple[float, int, StrikePlan]] = []
        self._rng = np.random.default_rng(seed)

    @property
    def busy(self) -> bool:
        return bool(self._pending)

    def connect(self) -> None:
        self.status = "ready"

    def close(self) -> None:
        self._pending.clear()
        self.status = "disconnected"

    def strike(self, plan: StrikePlan, now_s: float) -> int:
        if self.read_only:
            raise ArmError("arm is in read-only mode")
        if self.status != "ready":
            raise ArmError(f"arm is not ready (status={self.status})")
        self._sequence += 1
        jitter = float(self._rng.normal(0.0, self.spec.timing_jitter_s))
        self._pending.append((plan.strike_time_s + jitter, self._sequence, plan))
        self.status = "moving"
        self.strikes += 1
        return self._sequence

    def service(self, now_s: float) -> list[ArmEvent]:
        events: list[ArmEvent] = []
        keep: list[tuple[float, int, StrikePlan]] = []
        for actual_time, sequence, plan in self._pending:
            if now_s < actual_time:
                keep.append((actual_time, sequence, plan))
                continue
            timing_error = actual_time - plan.strike_time_s
            impact = (
                plan.impact_point_m
                + plan.swing_direction * plan.swing_speed_m_s * timing_error
                + self._rng.normal(0.0, self.spec.position_noise_m, size=3)
            )
            events.append(
                ArmEvent(
                    kind="strike_done",
                    sequence=sequence,
                    time_s=now_s,
                    actual_impact_m=impact,
                    actual_strike_time_s=actual_time,
                    detail="simulated",
                )
            )
        self._pending = keep
        if not self._pending and self.status == "moving":
            self.status = "ready"
        return events

    def abort(self, reason: str) -> None:
        self._pending.clear()
        self.aborts += 1
        self.status = "ready"


class EpsonArm:
    def __init__(self, spec: ArmSpec, read_only: bool = False):
        self.spec = spec
        self.read_only = read_only
        self.status = "disconnected"
        self.rtt_s = 0.0
        self.last_tx_s = 0.0
        self.last_rx_s = 0.0
        self._sock: socket.socket | None = None
        self._buffer = b""
        self._sequence = 0
        self._pending: dict[int, tuple[StrikePlan, float]] = {}
        self._pings: dict[int, float] = {}

    @property
    def busy(self) -> bool:
        return bool(self._pending)

    def connect(self) -> None:
        if self._sock is not None:
            return
        sock = socket.create_connection((self.spec.host, self.spec.port), timeout=3.0)
        sock.setblocking(False)
        self._sock = sock
        self._buffer = b""
        self.status = "ready"
        now = clock.now()
        self.last_rx_s = now
        self._send_ping(now)

    def close(self) -> None:
        if self._sock is not None:
            try:
                self._sock.close()
            finally:
                self._sock = None
        self._pending.clear()
        self._pings.clear()
        self.status = "disconnected"

    def strike(self, plan: StrikePlan, now_s: float) -> int:
        if self.read_only:
            raise ArmError("arm is in read-only mode")
        if self._sock is None or self.status != "ready":
            raise ArmError(f"arm is not ready (status={self.status})")

        lead = plan.strike_time_s - now_s - self.rtt_s / 2.0
        if lead <= 0.005:
            raise ArmError(f"lead is too short ({lead * 1000:.0f} ms)")

        base_from_world = self.spec.base_transform().inverse()
        poses = [
            (base_from_world @ pose).pose6()
            for pose in (plan.flange_pre, plan.flange_strike, plan.flange_post)
        ]
        fields: list[str] = []
        for pose in poses:
            fields.extend(f"{value:.2f}" for value in pose[:3])  # mm
            fields.extend(f"{value:.3f}" for value in pose[3:])  # degrees

        self._sequence += 1
        sequence = self._sequence
        line = self._encode(
            OP_STRIKE,
            sequence,
            [*fields, f"{plan.swing_speed_m_s * 1000.0:.1f}", f"{lead * 1000.0:.0f}"],
        )
        self.status = "moving"
        self._pending[sequence] = (plan, now_s + self.spec.response_timeout_s)
        try:
            self._send(line, now_s)
        except OSError as exc:
            self.status = "fault"
            self._pending.pop(sequence, None)
            raise ArmError(f"failed to send strike: {exc}") from exc
        return sequence

    def service(self, now_s: float) -> list[ArmEvent]:
        events: list[ArmEvent] = []
        if self._sock is None:
            return events

        while True:
            try:
                chunk = self._sock.recv(4096)
            except BlockingIOError:
                break
            except OSError as exc:
                events.append(self._fault(f"receive failed: {exc}", now_s))
                break
            if not chunk:
                events.append(self._fault("controller closed the connection", now_s))
                break
            self._buffer += chunk
            self.last_rx_s = now_s
            if len(self._buffer) > 65536:
                events.append(self._fault("response buffer overflow", now_s))
                break

        while b"\n" in self._buffer:
            raw, self._buffer = self._buffer.split(b"\n", 1)
            line = raw.decode("ascii", errors="replace").strip().strip("\r")
            if line:
                event = self._handle_line(line, now_s)
                if event is not None:
                    events.append(event)

        for sequence, sent in list(self._pings.items()):
            if now_s - sent > 5.0:
                self._pings.pop(sequence, None)

        if now_s - self.last_tx_s >= self.spec.heartbeat_s:
            self._send_ping(now_s)

        silent_limit = max(1.0, 4.0 * self.spec.heartbeat_s)
        if self.status != "fault" and now_s - self.last_rx_s > silent_limit:
            events.append(self._fault("no response from controller (heartbeat lost)", now_s))

        for sequence, (_plan, deadline) in list(self._pending.items()):
            if now_s > deadline:
                self._pending.pop(sequence, None)
                events.append(
                    ArmEvent("error", sequence, now_s, detail="controller response timed out")
                )
                self.status = "fault"
        return events

    def abort(self, reason: str) -> None:
        if self._sock is None or self.read_only:
            return
        self._sequence += 1
        try:
            self._send(self._encode(OP_ABORT, self._sequence), clock.now())
        except OSError:
            self.status = "fault"
        self._pending.clear()
        if self.status != "fault":
            self.status = "ready"

    # ----------------------------------------------------------------- private
    def _next_ping_sequence(self) -> int:
        self._sequence += 1
        return self._sequence

    def _send_ping(self, now_s: float) -> None:
        if self._sock is None:
            return
        sequence = self._next_ping_sequence()
        self._pings[sequence] = now_s
        try:
            self._send(self._encode(OP_PING, sequence), now_s)
        except OSError:
            self.status = "fault"

    @staticmethod
    def _encode(opcode: int, sequence: int, values: list[str] | None = None) -> str:
        """Fixed-width command: opcode, sequence, then exactly 20 fields.

        SPEL+ reads every command with one ``Input`` statement, so PING and
        ABORT carry zero-filled pose fields instead of a variable-length line.
        """
        payload = values if values is not None else ["0"] * 20
        if len(payload) != 20:
            raise ValueError(f"arm command needs 20 payload fields, got {len(payload)}")
        return ",".join([str(opcode), str(sequence), *payload])

    def _send(self, line: str, now_s: float) -> None:
        if self._sock is None:
            raise OSError("not connected")
        self._sock.sendall((line + "\n").encode("ascii"))
        self.last_tx_s = now_s

    def _fault(self, message: str, now_s: float) -> ArmEvent:
        self.status = "fault"
        return ArmEvent("error", 0, now_s, detail=message)

    def _handle_line(self, line: str, now_s: float) -> ArmEvent | None:
        parts = [part.strip() for part in line.split(",")]
        kind = parts[0].upper()
        if kind == "PONG" and len(parts) >= 2:
            try:
                sequence = int(parts[1])
            except ValueError:
                return None
            sent = self._pings.pop(sequence, None)
            if sent is not None:
                sample = max(0.0, now_s - sent)
                self.rtt_s = sample if self.rtt_s == 0.0 else 0.8 * self.rtt_s + 0.2 * sample
            return None
        if kind == "ACK":
            return None
        if kind == "DONE" and len(parts) >= 2:
            try:
                sequence = int(parts[1])
            except ValueError:
                return None
            entry = self._pending.pop(sequence, None)
            if self.status == "moving" and not self._pending:
                self.status = "ready"
            if entry is None:
                return None
            plan, _deadline = entry
            return ArmEvent(
                kind="strike_done",
                sequence=sequence,
                time_s=now_s,
                actual_strike_time_s=plan.strike_time_s,
                detail="controller-reported",
            )
        if kind == "ERR":
            sequence = 0
            if len(parts) >= 2:
                try:
                    sequence = int(parts[1])
                except ValueError:
                    pass
            self._pending.pop(sequence, None)
            self.status = "fault"
            return ArmEvent("error", sequence, now_s, detail=line)
        return None

"""TCP observation source for the iPhone TennisCamera app.

The phone does the 240 fps image capture and 2D detection.  It sends fixed
40-byte observation packets over TCP; the PC maps the phone's capture clock to
its own monotonic clock and feeds the existing estimator, planner and arm code.

This module is transport only.  It has no camera, detector or OpenCV
dependency.  The phone's clock is not the PC's clock, so the source estimates
the offset from the minimum observed ``arrival - capture`` delay.  A fixed
delay can be compensated; jitter cannot, which is why the capture timestamp is
carried in every packet instead of being replaced by the arrival time.
"""

from __future__ import annotations

import socket
import struct
import time
from dataclasses import dataclass
from typing import Callable

from . import clock as _clock
from .config import Config
from .types import BallObservation

MAGIC = 0x424F5254  # bytes "TROB" on the wire (little-endian)
VERSION = 1
HEADER = struct.Struct("<I B B H I Q f f f f H H")
PACKET_SIZE = HEADER.size
KIND_OBSERVATION = 0
KIND_STATUS = 1
KIND_STATE = 2
KIND_INTERCEPT = 3


class RemoteProtocolError(RuntimeError):
    """Raised when the iPhone observation stream is malformed."""


@dataclass(frozen=True)
class RemotePacket:
    kind: int
    sequence: int
    t_capture_ns: int
    u: float
    v: float
    radius: float
    confidence: float
    width: int
    height: int


def decode_packet(data: bytes) -> RemotePacket:
    """Decode and validate exactly one 40-byte packet."""
    if len(data) != PACKET_SIZE:
        raise RemoteProtocolError(f"packet is {len(data)} bytes, expected {PACKET_SIZE}")
    magic, version, kind, header_size, sequence, capture_ns, u, v, radius, confidence, width, height = HEADER.unpack(data)
    if magic != MAGIC:
        raise RemoteProtocolError(f"bad packet magic 0x{magic:08x}")
    if version != VERSION:
        raise RemoteProtocolError(f"unsupported packet version {version}")
    if header_size != PACKET_SIZE:
        raise RemoteProtocolError(f"packet header_size is {header_size}, expected {PACKET_SIZE}")
    if kind not in (KIND_OBSERVATION, KIND_STATUS, KIND_STATE, KIND_INTERCEPT):
        raise RemoteProtocolError(f"unknown packet kind {kind}")
    return RemotePacket(
        kind=kind,
        sequence=sequence,
        t_capture_ns=capture_ns,
        u=float(u),
        v=float(v),
        radius=float(radius),
        confidence=float(confidence),
        width=width,
        height=height,
    )


def encode_packet(
    kind: int,
    sequence: int,
    t_capture_ns: int,
    u: float,
    v: float,
    radius: float,
    confidence: float,
    width: int,
    height: int,
) -> bytes:
    """Encode one packet; used by the fake iPhone and tests."""
    return HEADER.pack(
        MAGIC,
        VERSION,
        int(kind),
        PACKET_SIZE,
        int(sequence),
        int(t_capture_ns),
        float(u),
        float(v),
        float(radius),
        float(confidence),
        int(width),
        int(height),
    )


def encode_observation(
    sequence: int,
    t_capture_ns: int,
    u: float,
    v: float,
    radius: float,
    confidence: float,
    width: int,
    height: int,
) -> bytes:
    return encode_packet(KIND_OBSERVATION, sequence, t_capture_ns, u, v, radius, confidence, width, height)


def encode_status(
    sequence: int,
    t_capture_ns: int,
    measured_fps: float,
    detector_ms: float,
    dropped_frames: float,
    thermal_state: float,
    width: int,
    height: int,
) -> bytes:
    return encode_packet(
        KIND_STATUS,
        sequence,
        t_capture_ns,
        measured_fps,
        detector_ms,
        dropped_frames,
        thermal_state,
        width,
        height,
    )


class RemoteObservationSource:
    """A TCP client that turns iPhone packets into ``BallObservation``s."""

    def __init__(
        self,
        config: Config,
        *,
        clock: Callable[[], float] = _clock.now,
        connect_timeout_s: float = 5.0,
        read_timeout_s: float = 0.25,
    ):
        self.camera = config.camera
        self.timeout_s = float(config.safety.source_timeout_s)
        self.clock = clock
        self.read_timeout_s = float(read_timeout_s)
        self._socket: socket.socket | None = None
        self._buffer = bytearray()
        self._offset_ns: int | None = None
        self._last_packet_s = self.clock()
        self._last_status: RemotePacket | None = None
        self._connected = False
        self._frame_size = (int(self.camera.width), int(self.camera.height))
        self.packets_received = 0
        self.observations_received = 0
        self.sequence_gaps = 0
        self._last_sequence: int | None = None
        self._connect(connect_timeout_s)

    # ------------------------------------------------------------------ lifecycle
    def _connect(self, timeout_s: float) -> None:
        """Connect, retrying until the deadline so start order is forgiving."""
        host, port = self.camera.remote_host, int(self.camera.remote_port)
        address = (host, port)
        requested = max(0.0, float(timeout_s))
        deadline = _clock.now() + requested
        while True:
            remaining = deadline - _clock.now()
            attempt_timeout = max(0.05, min(1.0, remaining if remaining > 0 else 0.05))
            try:
                sock = socket.create_connection(address, timeout=attempt_timeout)
            except OSError as exc:
                if _clock.now() >= deadline:
                    raise RuntimeError(
                        f"cannot connect to iPhone observation stream at {host}:{port} "
                        f"within {requested:.1f}s: {exc}. Start the TennisCamera app "
                        f"and iproxy {port} {port} first."
                    ) from exc
                time.sleep(min(0.2, max(0.0, deadline - _clock.now())))
                continue
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            sock.settimeout(self.read_timeout_s)
            self._socket = sock
            self._connected = True
            return

    def close(self) -> None:
        self._connected = False
        if self._socket is not None:
            try:
                self._socket.close()
            finally:
                self._socket = None

    # ------------------------------------------------------------------ source API
    def read(self) -> list[BallObservation]:
        """Return the next observation, or an empty list on a status/timeout.

        The pipeline calls this continuously.  A socket timeout is not an error:
        the phone sends a status packet about once per second, and the safety
        monitor uses ``healthy`` to decide whether the stream has stopped.
        """
        if not self._connected:
            return []
        packet = self._next_packet()
        if packet is None:
            return []

        arrival_s = self.clock()
        self._last_packet_s = arrival_s
        self.packets_received += 1

        if self._last_sequence is not None:
            expected = (self._last_sequence + 1) & 0xFFFFFFFF
            if packet.sequence != expected:
                self.sequence_gaps += 1
        self._last_sequence = packet.sequence

        # A status packet can arrive before the first frame; the app reports
        # 0x0 until the session negotiates a size.  That is not a mismatch.
        if packet.width and packet.height and (packet.width, packet.height) != self._frame_size:
            raise RemoteProtocolError(
                f"iPhone frame is {packet.width}x{packet.height}, "
                f"but camera.width/height is {self._frame_size[0]}x{self._frame_size[1]}"
            )

        if packet.kind == KIND_STATUS:
            self._last_status = packet
            return []

        # iOS 3D telemetry uses metres/seconds, not pixel coordinates.
        # The PC continues to solve its own calibrated intercept.
        if packet.kind in (KIND_STATE, KIND_INTERCEPT):
            return []

        self.observations_received += 1
        return [
            BallObservation(
                time_s=self._map_capture_time(packet, arrival_s) - float(self.camera.latency_s),
                u_px=packet.u,
                v_px=packet.v,
                radius_px=max(0.0, packet.radius),
                confidence=packet.confidence,
            )
        ]

    def _map_capture_time(self, packet: RemotePacket, arrival_s: float) -> float:
        """Map the phone's capture clock onto this PC's monotonic clock.

        ``arrival - capture`` is the phone clock offset plus detector and
        transport latency.  The minimum observed value estimates the constant
        part.  A packet with no capture timestamp falls back to its arrival
        time instead of poisoning the offset with an epoch-sized value.
        """
        if packet.t_capture_ns == 0:
            return arrival_s
        arrival_ns = int(arrival_s * 1_000_000_000)
        delay_ns = arrival_ns - packet.t_capture_ns
        if self._offset_ns is None or delay_ns < self._offset_ns:
            self._offset_ns = delay_ns
        return (packet.t_capture_ns + self._offset_ns) / 1_000_000_000.0

    @property
    def healthy(self) -> bool:
        return self._connected and (self.clock() - self._last_packet_s <= self.timeout_s)

    @property
    def done(self) -> bool:
        return False

    @property
    def last_status(self) -> RemotePacket | None:
        return self._last_status

    @property
    def offset_ns(self) -> int | None:
        return self._offset_ns

    @property
    def connected(self) -> bool:
        return self._connected

    # ------------------------------------------------------------------ packet I/O
    def _next_packet(self) -> RemotePacket | None:
        if self._socket is None:
            return None
        while len(self._buffer) < PACKET_SIZE:
            try:
                chunk = self._socket.recv(PACKET_SIZE - len(self._buffer))
            except socket.timeout:
                return None
            except OSError:
                self._mark_disconnected()
                return None
            if not chunk:
                self._mark_disconnected()
                return None
            self._buffer.extend(chunk)
        data = bytes(self._buffer[:PACKET_SIZE])
        del self._buffer[:PACKET_SIZE]
        return decode_packet(data)

    def _mark_disconnected(self) -> None:
        self._connected = False
        if self._socket is not None:
            try:
                self._socket.close()
            except OSError:
                pass
            self._socket = None

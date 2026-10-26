"""A fake iPhone TennisCamera server for testing the PC side.

The real iPhone app captures 240 fps and sends 40-byte observation packets.
This module produces the same packet stream from the existing ball/camera
simulator, so the PC's ``RemoteObservationSource``, estimator, planner, safety
monitor and mock arm can be exercised before the iOS app is installed.

It is deliberately a test tool: no video is encoded and no hardware is touched.
"""

from __future__ import annotations

import dataclasses
import socket
import threading
import time

from . import clock
from .config import Config
from .remote import encode_observation, encode_status
from .sim import SimulatedSource, VirtualClock


class FakeIphoneServer:
    """TCP server that plays a simulated flight using the phone packet format."""

    def __init__(
        self,
        config: Config,
        *,
        host: str = "127.0.0.1",
        port: int = 0,
        shots: int | None = None,
        warmup_s: float | None = None,
        interval_s: float | None = None,
        duration_s: float = 10.0,
        seed: int | None = None,
        detector_ms: float = 0.8,
        verbose: bool = False,
    ):
        sim = config.sim
        if shots is not None:
            sim = dataclasses.replace(sim, shots=shots)
        if warmup_s is not None:
            sim = dataclasses.replace(sim, warmup_s=warmup_s)
        if interval_s is not None:
            sim = dataclasses.replace(sim, interval_s=interval_s)
        self.config = dataclasses.replace(config, sim=sim)
        self.duration_s = float(duration_s)
        self.detector_ms = float(detector_ms)
        self.verbose = verbose
        self.seed = seed
        self.source = SimulatedSource(self.config, VirtualClock(0.0), seed)
        self.frames_sent = 0
        self.packets_sent = 0

        listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind((host, int(port)))
        listener.listen(1)
        self.host = host
        self.port = int(listener.getsockname()[1])
        self._listener = listener
        self._client: socket.socket | None = None
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None

    # ------------------------------------------------------------------ lifecycle
    def start(self) -> "FakeIphoneServer":
        if self._thread is None:
            self._thread = threading.Thread(target=self.serve, name="fake-iphone", daemon=True)
            self._thread.start()
        return self

    def close(self) -> None:
        self._stop.set()
        for sock in (self._client, self._listener):
            if sock is not None:
                try:
                    sock.close()
                except OSError:
                    pass
        if self._thread is not None:
            self._thread.join(timeout=1.0)
            self._thread = None

    @property
    def running(self) -> bool:
        return self._thread is not None and self._thread.is_alive()

    def serve(self) -> None:
        """Accept one client and stream until the duration expires or close()."""
        try:
            client, peer = self._listener.accept()
        except OSError:
            return
        self._client = client
        client.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        if self.verbose:
            print(f"fake iPhone: client {peer[0]}:{peer[1]} connected")
        fps = float(self.config.camera.fps)
        width = int(self.config.camera.width)
        height = int(self.config.camera.height)
        sequence = 0
        next_status_s = 0.0
        start_ns = clock.now_ns()
        duration_ns = int(round(self.duration_s * 1_000_000_000))
        try:
            while not self._stop.is_set():
                observations = self.source.read()
                sim_time = self.source.clock.now()
                target_ns = start_ns + int(round(sim_time * 1_000_000_000))
                now_ns = clock.now_ns()
                if now_ns < target_ns:
                    time.sleep(min((target_ns - now_ns) / 1_000_000_000.0, 0.05))
                if self._stop.is_set():
                    break

                for observation in observations:
                    capture_ns = start_ns + int(round(observation.time_s * 1_000_000_000))
                    packet = encode_observation(
                        sequence,
                        capture_ns,
                        observation.u_px,
                        observation.v_px,
                        observation.radius_px or 0.0,
                        observation.confidence,
                        width,
                        height,
                    )
                    client.sendall(packet)
                    sequence += 1
                    self.packets_sent += 1

                if sim_time >= next_status_s:
                    capture_ns = target_ns
                    packet = encode_status(
                        sequence,
                        capture_ns,
                        fps,
                        self.detector_ms,
                        0.0,
                        0.0,
                        width,
                        height,
                    )
                    client.sendall(packet)
                    sequence += 1
                    self.packets_sent += 1
                    next_status_s = sim_time + 0.5

                self.frames_sent += 1
                if clock.now_ns() - start_ns >= duration_ns:
                    break
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass
        finally:
            try:
                client.close()
            except OSError:
                pass
            self._client = None
            if self.verbose:
                print(f"fake iPhone: sent {self.frames_sent} frames, {self.packets_sent} packets")

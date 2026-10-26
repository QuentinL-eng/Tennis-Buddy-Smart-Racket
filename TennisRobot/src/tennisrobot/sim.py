"""Deterministic simulated ball feed.

The simulation exists to exercise the real estimator, planner and safety code
without a camera or a robot.  It generates ball flights with the same physics
model, projects them through the configured camera, then corrupts the pixels and
radii with noise and occasional false detections.  Ground truth is kept aside so
a run can separate perception error from execution error.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Protocol

import numpy as np

from . import clock
from .camera import PinholeCamera
from .config import Config
from .physics import BallProperties, FlightModel
from .types import BallObservation, BallState


class Clock(Protocol):
    def now(self) -> float: ...


class RealClock:
    def now(self) -> float:
        return clock.now()


class VirtualClock:
    def __init__(self, start_s: float = 0.0):
        self._now = float(start_s)

    def now(self) -> float:
        return self._now

    def advance(self, dt_s: float) -> float:
        self._now += float(dt_s)
        return self._now


@dataclass
class _Shot:
    launch_time_s: float
    launch_state: BallState
    cached_time_s: float
    cached_state: BallState

    def advance_to(self, time_s: float, flight: FlightModel) -> None:
        if time_s <= self.cached_time_s:
            return
        self.cached_state = flight.propagate_to(self.cached_state, time_s)
        self.cached_time_s = time_s

    def truth_at(self, time_s: float, flight: FlightModel) -> BallState | None:
        if time_s < self.launch_time_s or time_s > self.launch_time_s + 2.5:
            return None
        if time_s >= self.cached_time_s:
            return flight.propagate_to(self.cached_state, time_s)
        # Evaluation can ask for a time slightly before the last frame; replay
        # from launch rather than integrating backwards.
        return flight.propagate_to(self.launch_state, time_s)

    def finished(self) -> bool:
        position = self.cached_state.position_m
        return (
            self.cached_time_s - self.launch_time_s > 2.5
            or position[2] <= 0.02
            or position[1] < -1.0
        )


class SimulatedSource:
    """Ball machine + camera simulator with the same ``read`` contract as a camera."""

    def __init__(self, config: Config, clock: Clock, seed: int | None = None):
        self.config = config
        self.spec = config.sim
        self.clock = clock
        self.camera = PinholeCamera.from_spec(config.camera)
        ball = config.ball
        self.flight = FlightModel(
            BallProperties(
                mass_kg=ball.mass_kg,
                radius_m=ball.radius_m,
                drag_coefficient=ball.drag_coefficient,
                air_density_kg_m3=ball.air_density_kg_m3,
                lift_slope=ball.lift_slope,
            ),
            spin_rad_s=np.asarray(ball.spin_rad_s, dtype=float),
            wind_m_s=np.asarray(ball.wind_m_s, dtype=float),
            max_step_s=0.002,
        )
        self.rng = np.random.default_rng(self.spec.seed if seed is None else seed)
        self._shot: _Shot | None = None
        self._shot_index = 0
        self._next_launch_s = float(self.spec.warmup_s)
        self.observations_generated = 0

    def read(self) -> list[BallObservation]:
        time_s = self.clock.advance(1.0 / self.config.camera.fps)

        if self._shot is None and self._shot_index < self.spec.shots and time_s >= self._next_launch_s - 1e-9:
            self._shot = self._launch(time_s)
            self._shot_index += 1

        if self._shot is None:
            return []

        self._shot.advance_to(time_s, self.flight)
        if self._shot.finished():
            self._shot = None
            self._next_launch_s = time_s + self.spec.interval_s
            return []
        return self._observe(self._shot, time_s)

    def truth_at(self, time_s: float) -> BallState | None:
        if self._shot is None:
            return None
        return self._shot.truth_at(time_s, self.flight)

    @property
    def done(self) -> bool:
        return self._shot_index >= self.spec.shots and self._shot is None

    def close(self) -> None:
        self._shot = None

    # ----------------------------------------------------------------- private
    def _launch(self, time_s: float) -> _Shot:
        position = np.asarray(self.spec.launch_position_m, dtype=float)
        velocity = np.asarray(self.spec.launch_velocity_m_s, dtype=float).copy()
        velocity[0] += float(self.rng.uniform(-self.spec.lateral_jitter_m_s, self.spec.lateral_jitter_m_s))
        velocity[2] += float(self.rng.uniform(-0.15, 0.15))
        factor = float(self.rng.uniform(1.0 - self.spec.speed_jitter_fraction, 1.0 + self.spec.speed_jitter_fraction))
        velocity[1] *= factor
        velocity[2] *= factor
        state = BallState(time_s, position, velocity)
        return _Shot(time_s, state, time_s, state)

    def _observe(self, shot: _Shot, time_s: float) -> list[BallObservation]:
        observations: list[BallObservation] = []
        state = shot.cached_state
        projection = self.camera.project(state.position_m)
        if projection is not None:
            u, v = projection
            if self.camera.in_image(u, v):
                radius = self.camera.pixel_radius(state.position_m, self.config.ball.radius_m)
                if radius >= 1.5:
                    observations.append(
                        BallObservation(
                            time_s=time_s,
                            u_px=u + float(self.rng.normal(0.0, self.spec.noise_px)),
                            v_px=v + float(self.rng.normal(0.0, self.spec.noise_px)),
                            radius_px=max(1.0, radius + float(self.rng.normal(0.0, self.spec.radius_noise_px))),
                            confidence=1.0,
                        )
                    )
        if self.rng.random() < self.spec.outlier_rate:
            observations.append(
                BallObservation(
                    time_s=time_s,
                    u_px=float(self.rng.uniform(0.0, self.camera.width)),
                    v_px=float(self.rng.uniform(0.0, self.camera.height)),
                    radius_px=float(self.rng.uniform(3.0, 25.0)),
                    confidence=0.3,
                )
            )
        self.observations_generated += len(observations)
        return observations

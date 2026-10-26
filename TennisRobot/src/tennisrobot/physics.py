"""Tennis-ball flight model: gravity, quadratic drag and an optional Magnus term.

The model is deliberately small and explicit.  It is used both to generate the
simulated ball and to extrapolate real observations, so a systematic model error
shows up in the simulation as well.  Spin is a configured constant: a single
camera cannot observe spin, and hiding that behind a fitted parameter would make
the uncertainty look smaller than it is.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field

import numpy as np

from .types import BallState

GRAVITY_M_S2 = np.array([0.0, 0.0, -9.80665])


@dataclass(frozen=True)
class BallProperties:
    mass_kg: float = 0.0575
    radius_m: float = 0.0335
    drag_coefficient: float = 0.507
    air_density_kg_m3: float = 1.225
    lift_slope: float = 0.5
    max_lift_coefficient: float = 0.35

    @property
    def area_m2(self) -> float:
        return float(np.pi * self.radius_m**2)


@dataclass(frozen=True)
class FlightModel:
    ball: BallProperties = field(default_factory=BallProperties)
    spin_rad_s: np.ndarray = field(default_factory=lambda: np.zeros(3))
    wind_m_s: np.ndarray = field(default_factory=lambda: np.zeros(3))
    max_step_s: float = 0.004
    _drag_scale: float = field(init=False, repr=False, compare=False, default=0.0)
    _lift_base: float = field(init=False, repr=False, compare=False, default=0.0)
    _spin_rate: float = field(init=False, repr=False, compare=False, default=0.0)
    _spin_axis: np.ndarray = field(
        init=False, repr=False, compare=False, default_factory=lambda: np.zeros(3)
    )

    def __post_init__(self) -> None:
        object.__setattr__(self, "spin_rad_s", np.asarray(self.spin_rad_s, dtype=float).reshape(3))
        object.__setattr__(self, "wind_m_s", np.asarray(self.wind_m_s, dtype=float).reshape(3))

        ball = self.ball
        area = ball.area_m2
        dynamic_scale = 0.5 * ball.air_density_kg_m3 * area / ball.mass_kg
        object.__setattr__(self, "_drag_scale", dynamic_scale * ball.drag_coefficient)
        object.__setattr__(self, "_lift_base", dynamic_scale)

        spin = self.spin_rad_s
        spin_rate = math.sqrt(float(spin @ spin))
        object.__setattr__(self, "_spin_rate", spin_rate)
        if spin_rate > 1e-9:
            object.__setattr__(self, "_spin_axis", spin / spin_rate)

    def acceleration(self, velocity_m_s: np.ndarray) -> np.ndarray:
        ball = self.ball
        relative = np.asarray(velocity_m_s, dtype=float) - self.wind_m_s
        speed_sq = float(relative @ relative)
        if speed_sq < 1e-18:
            return GRAVITY_M_S2.copy()
        speed = math.sqrt(speed_sq)

        acceleration = GRAVITY_M_S2 - self._drag_scale * speed * relative

        if self._spin_rate > 1e-9:
            spin_factor = ball.radius_m * self._spin_rate / speed
            lift_coefficient = ball.lift_slope * spin_factor
            if lift_coefficient > ball.max_lift_coefficient:
                lift_coefficient = ball.max_lift_coefficient
            elif lift_coefficient < -ball.max_lift_coefficient:
                lift_coefficient = -ball.max_lift_coefficient
            lift_scale = self._lift_base * lift_coefficient * speed_sq
            acceleration = acceleration + lift_scale * np.cross(self._spin_axis, relative / speed)
        return acceleration

    def step(self, state: BallState, dt_s: float) -> BallState:
        """One RK4 step of constant spin, translational flight."""
        if dt_s <= 0.0:
            return state
        p0 = state.position_m
        v0 = state.velocity_m_s

        k1_v = self.acceleration(v0)
        k1_p = v0
        k2_v = self.acceleration(v0 + 0.5 * dt_s * k1_v)
        k2_p = v0 + 0.5 * dt_s * k1_v
        k3_v = self.acceleration(v0 + 0.5 * dt_s * k2_v)
        k3_p = v0 + 0.5 * dt_s * k2_v
        k4_v = self.acceleration(v0 + dt_s * k3_v)
        k4_p = v0 + dt_s * k3_v

        position = p0 + (dt_s / 6.0) * (k1_p + 2.0 * k2_p + 2.0 * k3_p + k4_p)
        velocity = v0 + (dt_s / 6.0) * (k1_v + 2.0 * k2_v + 2.0 * k3_v + k4_v)
        return BallState(state.time_s + dt_s, position, velocity)

    def propagate_to(self, state: BallState, end_time_s: float) -> BallState:
        """Integrate to an absolute time (state times are monotonic seconds)."""
        if end_time_s < state.time_s - 1e-9:
            raise ValueError("cannot propagate backwards in time")
        current = state
        while current.time_s < end_time_s - 1e-9:
            dt = min(self.max_step_s, end_time_s - current.time_s)
            current = self.step(current, dt)
        return current

    def state_at(self, state: BallState, time_s: float) -> BallState:
        return self.propagate_to(state, time_s)

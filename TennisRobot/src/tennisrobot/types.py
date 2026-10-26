"""Value types shared by the pipeline, the arm adapters and the recorder."""

from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np

from .geometry import Transform


@dataclass(frozen=True)
class BallObservation:
    """A single ball detection in one camera frame."""

    time_s: float
    u_px: float
    v_px: float
    radius_px: float | None = None
    confidence: float = 1.0


@dataclass(frozen=True)
class BallState:
    time_s: float
    position_m: np.ndarray
    velocity_m_s: np.ndarray

    def __post_init__(self) -> None:
        object.__setattr__(self, "position_m", np.asarray(self.position_m, dtype=float).reshape(3))
        object.__setattr__(self, "velocity_m_s", np.asarray(self.velocity_m_s, dtype=float).reshape(3))


@dataclass(frozen=True)
class FitResult:
    """A fitted flight state and the quality of the fit that produced it."""

    t_ref_s: float
    position_m: np.ndarray
    velocity_m_s: np.ndarray
    rms_px: float
    rms_radius_px: float
    n_observations: int
    iterations: int
    converged: bool

    def state(self) -> BallState:
        return BallState(self.t_ref_s, self.position_m, self.velocity_m_s)


@dataclass(frozen=True)
class Intercept:
    """Where and when the predicted flight crosses the strike plane."""

    time_s: float
    position_m: np.ndarray
    ball_velocity_m_s: np.ndarray


@dataclass(frozen=True)
class StrikePlan:
    """A trajectory for the racket, with the impact point on the intended path.

    ``flange_*`` poses are in world coordinates.  A constant orientation is used
    for the whole segment, so the designated racket point travels along a
    straight line and reaches ``impact_point_m`` exactly at ``strike_time_s``.
    """

    strike_time_s: float
    impact_point_m: np.ndarray
    face_normal: np.ndarray
    swing_direction: np.ndarray
    flange_pre: Transform
    flange_strike: Transform
    flange_post: Transform
    swing_speed_m_s: float
    required_lead_s: float

    def lead_from(self, now_s: float) -> float:
        return self.strike_time_s - now_s


@dataclass(frozen=True)
class PlanRejection:
    reason: str


@dataclass(frozen=True)
class ArmEvent:
    kind: str  # "strike_done" | "error" | "aborted"
    sequence: int
    time_s: float
    actual_impact_m: np.ndarray | None = None
    actual_strike_time_s: float | None = None
    detail: str = ""


@dataclass
class ShotOutcome:
    sequence: int
    hit: bool | None
    planned_time_s: float
    actual_time_s: float | None = None
    timing_error_ms: float | None = None
    execution_error_m: float | None = None
    perception_error_m: float | None = None
    total_error_m: float | None = None
    detail: str = ""


@dataclass
class RunSummary:
    frames: int = 0
    fits: int = 0
    strikes: int = 0
    hits: int = 0
    misses: int = 0
    unverified: int = 0
    rejections: dict[str, int] = field(default_factory=dict)
    outcomes: list[ShotOutcome] = field(default_factory=list)
    fault: str = ""

    def reject(self, reason: str) -> None:
        self.rejections[reason] = self.rejections.get(reason, 0) + 1

    def add(self, outcome: ShotOutcome) -> None:
        self.outcomes.append(outcome)
        self.strikes += 1
        if outcome.hit is True:
            self.hits += 1
        elif outcome.hit is False:
            self.misses += 1
        else:
            self.unverified += 1

    def report(self) -> str:
        lines = [
            f"frames={self.frames}  fits={self.fits}  strikes={self.strikes}  "
            f"hits={self.hits}  misses={self.misses}  unverified={self.unverified}"
        ]
        if self.outcomes:
            timings = [abs(o.timing_error_ms) for o in self.outcomes if o.timing_error_ms is not None]
            totals = [o.total_error_m for o in self.outcomes if o.total_error_m is not None]
            executions = [o.execution_error_m for o in self.outcomes if o.execution_error_m is not None]
            perceptions = [o.perception_error_m for o in self.outcomes if o.perception_error_m is not None]
            if timings:
                lines.append(f"median |timing error|: {np.median(timings):.1f} ms")
            if executions:
                lines.append(f"median execution error: {np.median(executions) * 100:.1f} cm")
            if perceptions:
                lines.append(f"median perception error: {np.median(perceptions) * 100:.1f} cm")
            if totals:
                lines.append(f"median total error: {np.median(totals) * 100:.1f} cm")
        if self.rejections:
            top = sorted(self.rejections.items(), key=lambda item: item[1], reverse=True)
            lines.append("no-strike reasons: " + ", ".join(f"{reason} x{count}" for reason, count in top))
        if self.fault:
            lines.append(f"FAULT: {self.fault}")
        return "\n".join(lines)

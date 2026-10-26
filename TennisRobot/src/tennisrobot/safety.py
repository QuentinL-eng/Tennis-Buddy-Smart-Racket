"""Software safety checks.

These checks decide whether to *start* a motion.  They are not a safety-rated
system and must never replace the controller's safety circuit, a hardwired
emergency stop, guarding or a restricted work envelope.  The arm boxes are a
conservative model of where the impact point and flange may go; the full swept
volume of the racket (including the head before and after contact) changes with
the mount and must be verified in the cell.

Every check returns a human-readable violation or ``None``.  The pipeline counts
violations and refuses to issue a strike on any of them.
"""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np

from .config import ArmSpec, SafetySpec
from .types import FitResult, Intercept, StrikePlan


@dataclass(frozen=True)
class SafetyMonitor:
    settings: SafetySpec
    arm: ArmSpec

    def check_fit(self, fit: FitResult) -> str | None:
        if fit.n_observations < self.settings.min_observations:
            return f"fit has only {fit.n_observations} observations"
        if not np.isfinite(fit.rms_px) or fit.rms_px > self.settings.max_fit_rms_px:
            return f"fit residual {fit.rms_px:.2f} px exceeds {self.settings.max_fit_rms_px:.2f} px"
        return None

    def check_intercept(self, intercept: Intercept) -> str | None:
        speed = float(np.linalg.norm(intercept.ball_velocity_m_s))
        if speed < self.settings.min_ball_speed_m_s:
            return f"ball speed {speed:.1f} m/s is below the configured minimum"
        if speed > self.settings.max_ball_speed_m_s:
            return f"ball speed {speed:.1f} m/s exceeds the configured maximum"
        return None

    def check_plan(self, plan: StrikePlan, now_s: float) -> str | None:
        if plan.strike_time_s <= now_s:
            return "strike time is not in the future"
        if plan.swing_speed_m_s > self.arm.max_tcp_speed_m_s + 1e-9:
            return "swing speed exceeds the arm limit"

        base_from_world = self.arm.base_transform().inverse()
        impact = base_from_world.apply_point(plan.impact_point_m)
        if not _inside(impact, self.arm.impact_box_min, self.arm.impact_box_max):
            return (
                "impact point outside envelope: base "
                f"({impact[0]:.2f}, {impact[1]:.2f}, {impact[2]:.2f}) m"
            )

        for name, pose in (
            ("pre-swing", plan.flange_pre),
            ("strike", plan.flange_strike),
            ("post-swing", plan.flange_post),
        ):
            point = base_from_world.apply_point(pose.translation)
            if not _inside(point, self.arm.flange_box_min, self.arm.flange_box_max):
                return (
                    f"{name} flange outside envelope: base "
                    f"({point[0]:.2f}, {point[1]:.2f}, {point[2]:.2f}) m"
                )
        return None


def _inside(point: np.ndarray, low: list[float], high: list[float]) -> bool:
    low_array = np.asarray(low, dtype=float)
    high_array = np.asarray(high, dtype=float)
    return bool(np.all(point >= low_array) and np.all(point <= high_array))

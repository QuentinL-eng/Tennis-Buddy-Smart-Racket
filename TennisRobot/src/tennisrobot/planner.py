"""Swing planning for the racket's designated impact point.

The plan is intentionally simple and checkable: a straight Cartesian sweep with
a constant racket orientation, timed so the impact point crosses the predicted
intercept exactly at the predicted time.  Speed is limited by the runway on both
sides of the intercept, so the controller can accelerate before contact and
still stop inside the post-swing distance.

The racket is treated as a rigid body with no rebound model.  The face is set
square to the incoming ball's horizontal velocity and the racket drives through
the ball; adding spin or an angled face is a later, separate problem.
"""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np

from .config import ArmSpec, PlannerSpec
from .geometry import unit
from .racket import Racket
from .types import Intercept, PlanRejection, StrikePlan


@dataclass(frozen=True)
class SwingPlanner:
    racket: Racket
    arm: ArmSpec
    settings: PlannerSpec

    def plan(self, intercept: Intercept, now_s: float) -> StrikePlan | PlanRejection:
        available_lead = intercept.time_s - now_s
        if available_lead > self.settings.max_lead_s:
            return PlanRejection(f"too early ({available_lead * 1000:.0f} ms of lead)")

        accel = self.arm.max_accel_m_s2
        speed = min(
            self.settings.swing_speed_m_s,
            float(np.sqrt(2.0 * accel * self.settings.pre_swing_distance_m)),
            float(np.sqrt(2.0 * accel * self.settings.post_swing_distance_m)),
        )
        if speed < self.settings.min_swing_speed_m_s:
            return PlanRejection("swing runway is too short for the minimum speed")

        accel_time = speed / accel
        accel_distance = speed * speed / (2.0 * accel)
        cruise_distance = max(0.0, self.settings.pre_swing_distance_m - accel_distance)
        required_lead = accel_time + cruise_distance / speed
        deadline = max(
            self.settings.min_lead_s,
            required_lead + self.arm.command_latency_s + self.settings.decision_margin_s,
        )
        if available_lead < deadline:
            return PlanRejection(
                f"too late (need {deadline * 1000:.0f} ms, have {available_lead * 1000:.0f} ms)"
            )

        ball_velocity = np.asarray(intercept.ball_velocity_m_s, dtype=float)
        horizontal = ball_velocity.copy()
        horizontal[2] = 0.0
        if self.settings.face_horizontal and float(np.linalg.norm(horizontal)) > 0.5:
            face_source = horizontal
        else:
            face_source = ball_velocity
        try:
            face_normal = -unit(face_source, "incoming ball velocity")
            shaft_hint = unit(self.settings.shaft_hint_world, "shaft hint")
        except ValueError as exc:
            return PlanRejection(str(exc))

        strike_point = np.asarray(intercept.position_m, dtype=float).copy()
        pre_point = strike_point - face_normal * self.settings.pre_swing_distance_m
        post_point = strike_point + face_normal * self.settings.post_swing_distance_m
        try:
            flange_pre = self.racket.flange_for_impact(pre_point, face_normal, shaft_hint)
            flange_strike = self.racket.flange_for_impact(strike_point, face_normal, shaft_hint)
            flange_post = self.racket.flange_for_impact(post_point, face_normal, shaft_hint)
        except ValueError as exc:
            return PlanRejection(f"cannot build racket orientation: {exc}")

        return StrikePlan(
            strike_time_s=float(intercept.time_s),
            impact_point_m=strike_point,
            face_normal=face_normal,
            swing_direction=face_normal.copy(),
            flange_pre=flange_pre,
            flange_strike=flange_strike,
            flange_post=flange_post,
            swing_speed_m_s=float(speed),
            required_lead_s=float(required_lead),
        )

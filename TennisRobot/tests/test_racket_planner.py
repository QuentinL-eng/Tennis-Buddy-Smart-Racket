import dataclasses

import numpy as np

from tennisrobot.planner import SwingPlanner
from tennisrobot.racket import Racket
from tennisrobot.safety import SafetyMonitor
from tennisrobot.types import Intercept, PlanRejection


def _plan(config, *, now: float = 10.0, lead: float = 0.38, position=(0.1, 0.58, 0.9), velocity=(0.2, -9.0, -3.5)):
    intercept = Intercept(now + lead, np.array(position, dtype=float), np.array(velocity, dtype=float))
    planner = SwingPlanner(Racket(config.racket), config.arm, config.planner)
    return planner.plan(intercept, now), planner


def test_racket_impact_point_roundtrip(config):
    racket = Racket(config.racket)
    target = np.array([0.1, 0.58, 0.9])
    face = np.array([0.0, 1.0, 0.0])
    shaft = np.array([0.0, 0.0, 1.0])

    flange = racket.flange_for_impact(target, face, shaft)
    recovered = racket.impact_point_world(flange @ racket.mount)
    assert np.allclose(recovered, target, atol=1e-12)
    assert np.allclose((flange @ racket.mount).rotation[:, 1], face, atol=1e-12)
    assert np.allclose((flange @ racket.mount).rotation[:, 2], shaft, atol=1e-12)


def test_plan_puts_the_racket_point_on_the_ball(config):
    plan, _planner = _plan(config)
    assert not isinstance(plan, PlanRejection)
    racket = Racket(config.racket)
    pre = racket.impact_point_world(plan.flange_pre @ racket.mount)
    strike = racket.impact_point_world(plan.flange_strike @ racket.mount)
    post = racket.impact_point_world(plan.flange_post @ racket.mount)

    assert np.allclose(strike, plan.impact_point_m, atol=1e-12)
    assert np.allclose(pre, plan.impact_point_m - plan.face_normal * config.planner.pre_swing_distance_m, atol=1e-12)
    assert np.allclose(post, plan.impact_point_m + plan.face_normal * config.planner.post_swing_distance_m, atol=1e-12)
    assert np.allclose(plan.face_normal, np.array([-0.2, 9.0, 0.0]) / np.linalg.norm([0.2, 9.0]), atol=1e-6)
    assert 0 < plan.swing_speed_m_s <= config.planner.swing_speed_m_s
    assert plan.required_lead_s > 0


def test_default_plan_passes_the_safety_monitor(config):
    plan, _planner = _plan(config)
    assert not isinstance(plan, PlanRejection)
    monitor = SafetyMonitor(config.safety, config.arm)
    assert monitor.check_plan(plan, 10.0) is None


def test_plan_rejects_a_point_outside_the_envelope(config):
    plan, _planner = _plan(config, position=(2.0, 0.58, 0.9))
    assert not isinstance(plan, PlanRejection)
    monitor = SafetyMonitor(config.safety, config.arm)
    assert "impact point outside envelope" in monitor.check_plan(plan, 10.0)


def test_planner_rejects_too_early_and_too_late(config):
    early, _ = _plan(config, lead=0.9)
    late, _ = _plan(config, lead=0.1)
    assert isinstance(early, PlanRejection)
    assert "too early" in early.reason
    assert isinstance(late, PlanRejection)
    assert "too late" in late.reason


def test_vertical_ball_with_parallel_shaft_hint_is_rejected(config):
    settings = dataclasses.replace(config.planner, face_horizontal=False)
    intercept = Intercept(10.38, np.array([0.0, 0.58, 0.9]), np.array([0.0, 0.0, -5.0]))
    planner = SwingPlanner(Racket(config.racket), config.arm, settings)
    result = planner.plan(intercept, 10.0)
    assert isinstance(result, PlanRejection)
    assert "orientation" in result.reason


def test_safety_monitor_rejects_a_bad_fit(config):
    from tennisrobot.types import FitResult

    monitor = SafetyMonitor(config.safety, config.arm)
    fit = FitResult(0.0, np.zeros(3), np.zeros(3), rms_px=99.0, rms_radius_px=1.0, n_observations=50, iterations=3, converged=True)
    assert monitor.check_fit(fit) is not None

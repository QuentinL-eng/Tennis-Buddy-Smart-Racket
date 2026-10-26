"""Sensor-to-strike pipeline.

State machine::

    monitor ──(no strike authority)───────────────────────────────┐
    armed ──plan+send──► committed ──arm done──► cooldown ──► armed
      │                         │
      └── fit/plan rejected ◄───┘ (no motion)
    any state ──arm fault / repeated miss──► fault (stop)

The pipeline fits every ``run.fit_every_n_frames`` frames, predicts the crossing
of the configured strike plane, plans only when the remaining lead is inside the
allowed window, and sends one strike per ball.  All motion remains on the
controller; this process can stop at any time without leaving a motion queued.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Callable

import numpy as np

from .arm import ArmError, EpsonArm, MockArm
from .camera import PinholeCamera
from .config import Config
from .estimator import FlightEstimator
from .physics import BallProperties, FlightModel
from .planner import SwingPlanner
from .racket import Racket
from .recorder import Recorder
from .remote import RemoteObservationSource
from .safety import SafetyMonitor
from .sim import Clock, RealClock, SimulatedSource, VirtualClock
from .types import (
    ArmEvent,
    BallObservation,
    FitResult,
    Intercept,
    PlanRejection,
    RunSummary,
    ShotOutcome,
    StrikePlan,
)
from .vision import CameraSource, ObservationGate


@dataclass
class _Pending:
    sequence: int
    plan: StrikePlan
    fit: FitResult
    intercept: Intercept


class Pipeline:
    def __init__(
        self,
        config: Config,
        source: Any,
        arm: Any,
        clock: Clock,
        *,
        allow_strike: bool = True,
        truth_fn: Callable[[float], Any] | None = None,
        recorder: Recorder | None = None,
        verbose: bool = True,
    ):
        self.config = config
        self.source = source
        self.arm = arm
        self.clock = clock
        self.allow_strike = allow_strike
        self.truth_fn = truth_fn
        self.recorder = recorder
        self.verbose = verbose

        self.camera = PinholeCamera.from_spec(config.camera)
        ball = config.ball
        self.estimator = FlightEstimator(
            self.camera,
            FlightModel(
                BallProperties(
                    mass_kg=ball.mass_kg,
                    radius_m=ball.radius_m,
                    drag_coefficient=ball.drag_coefficient,
                    air_density_kg_m3=ball.air_density_kg_m3,
                    lift_slope=ball.lift_slope,
                ),
                spin_rad_s=np.asarray(ball.spin_rad_s, dtype=float),
                wind_m_s=np.asarray(ball.wind_m_s, dtype=float),
                max_step_s=0.005,
            ),
            config.estimator,
        )
        self.racket = Racket(config.racket)
        self.planner = SwingPlanner(self.racket, config.arm, config.planner)
        self.safety = SafetyMonitor(config.safety, config.arm)
        self.gate = ObservationGate(config.vision)

        self.summary = RunSummary()
        self.state = "armed" if allow_strike else "monitor"
        self.observations: list[BallObservation] = []
        self.pending: _Pending | None = None
        self.last_fit: FitResult | None = None
        self.last_intercept: Intercept | None = None
        self.last_plan: StrikePlan | None = None
        self.last_observation_time: float | None = None
        self.cooldown_until_s = 0.0
        self._consecutive_misses = 0
        self.start_time_s = clock.now()
        self._last_status_s = self.start_time_s
        self._finished = False

    # ------------------------------------------------------------------ public
    def run(self) -> RunSummary:
        if self._finished:
            return self.summary
        self.start_time_s = self.clock.now()
        self._record("pipeline_start", self.start_time_s, state=self.state)
        try:
            while True:
                observations = self.source.read()
                now = self.clock.now()

                for event in self.arm.service(now):
                    self._handle_arm_event(event, now)
                if self.state == "fault":
                    break

                if self.state in {"armed", "committed"} and not getattr(self.source, "healthy", True):
                    self._fault("camera stopped delivering frames", now)
                    break

                if observations:
                    self._ingest(observations, now)
                self.summary.frames += 1

                if self.summary.frames % self.config.run.fit_every_n_frames == 0:
                    self._attempt(now)
                self._prune(now)

                if self.state == "cooldown" and now >= self.cooldown_until_s:
                    self.state = "armed" if self.allow_strike else "monitor"
                if self.pending is not None and now > self.pending.plan.strike_time_s + 2.0:
                    self._fault("strike was not confirmed by the arm", now)
                    break
                if self.verbose and now - self._last_status_s >= 2.0:
                    self._status(now)
                    self._last_status_s = now
                if self.source.done and not self.arm.busy and self.pending is None:
                    break
                if self.config.run.max_runtime_s > 0 and now - self.start_time_s >= self.config.run.max_runtime_s:
                    break
        except KeyboardInterrupt:
            self._record("interrupted", self.clock.now())
        finally:
            self._finished = True
            if self.recorder is not None:
                self.recorder.close(self.clock.now(), self.summary)
        return self.summary

    def close(self) -> None:
        if self.recorder is not None:
            self.recorder.close(self.clock.now())
        self._finished = True

    # ----------------------------------------------------------------- private
    def _ingest(self, observations: list[BallObservation], now: float) -> None:
        first_time = min(observation.time_s for observation in observations)
        if self.last_observation_time is not None and first_time - self.last_observation_time > 0.4:
            # A long gap is a new ball; never fit across two flights.
            self.observations.clear()
            self.gate.reset()
        for observation in observations:
            if not self.gate.accept(observation):
                continue
            self.observations.append(observation)
            self.last_observation_time = observation.time_s
            self._record(
                "observation",
                now,
                u=observation.u_px,
                v=observation.v_px,
                r=observation.radius_px,
                confidence=observation.confidence,
            )

    def _attempt(self, now: float) -> None:
        if self.state not in {"armed", "monitor"}:
            return
        if len(self.observations) < self.config.estimator.min_observations:
            return
        fit = self.estimator.fit(self.observations)
        if fit is None:
            return
        self.summary.fits += 1
        self.last_fit = fit
        self._record(
            "fit",
            now,
            t_ref=fit.t_ref_s,
            position=fit.position_m,
            velocity=fit.velocity_m_s,
            rms_px=fit.rms_px,
            rms_radius_px=fit.rms_radius_px,
            n=fit.n_observations,
            iterations=fit.iterations,
        )

        violation = self.safety.check_fit(fit)
        if violation is not None:
            self._reject(f"safety fit: {violation}", now)
            return

        horizon = max(1.0, min(1.5, self.config.planner.max_lead_s + 0.65))
        intercept = self.estimator.predict_intercept(
            fit,
            np.asarray(self.config.planner.strike_plane_point_m, dtype=float),
            np.asarray(self.config.planner.strike_plane_normal, dtype=float),
            now,
            horizon,
        )
        if intercept is None:
            return
        self.last_intercept = intercept
        self._record(
            "intercept",
            now,
            time_s=intercept.time_s,
            position=intercept.position_m,
            velocity=intercept.ball_velocity_m_s,
            lead_s=intercept.time_s - now,
        )

        violation = self.safety.check_intercept(intercept)
        if violation is not None:
            self._reject(f"safety intercept: {violation}", now)
            return
        if self.state == "monitor":
            return

        plan = self.planner.plan(intercept, now)
        if isinstance(plan, PlanRejection):
            self._reject(plan.reason, now)
            return
        violation = self.safety.check_plan(plan, now)
        if violation is not None:
            self._reject(f"safety plan: {violation}", now)
            return

        self.last_plan = plan
        self._record(
            "plan",
            now,
            strike_time=plan.strike_time_s,
            impact=plan.impact_point_m,
            face=plan.face_normal,
            swing=plan.swing_direction,
            speed=plan.swing_speed_m_s,
            required_lead=plan.required_lead_s,
            pre=plan.flange_pre,
            strike=plan.flange_strike,
            post=plan.flange_post,
        )
        if not self.allow_strike:
            return
        try:
            sequence = self.arm.strike(plan, now)
        except ArmError as exc:
            self._reject(f"arm refused: {exc}", now)
            if getattr(self.arm, "status", "") == "fault":
                self._fault(str(exc), now)
            return
        self.pending = _Pending(sequence, plan, fit, intercept)
        self.state = "committed"
        self._record("strike_sent", now, sequence=sequence, strike_time=plan.strike_time_s)

    def _handle_arm_event(self, event: ArmEvent, now: float) -> None:
        self._record(
            "arm_event",
            now,
            kind=event.kind,
            sequence=event.sequence,
            actual_time=event.actual_strike_time_s,
            actual_impact=event.actual_impact_m,
            detail=event.detail,
        )
        if event.kind == "error":
            self._fault(event.detail or "arm error", now)
            return
        if event.kind != "strike_done":
            return
        pending = self.pending
        if pending is None or pending.sequence != event.sequence:
            return

        outcome = self._evaluate(pending, event)
        self.summary.add(outcome)
        self._record("outcome", now, **outcome.__dict__)
        if self.verbose:
            verdict = "HIT" if outcome.hit is True else "MISS" if outcome.hit is False else "UNVERIFIED"
            timing = "n/a" if outcome.timing_error_ms is None else f"{outcome.timing_error_ms:+.1f} ms"
            total = "n/a" if outcome.total_error_m is None else f"{outcome.total_error_m * 100:.1f} cm"
            print(
                f"  strike {outcome.sequence}: {verdict}  timing {timing}  total error {total}",
                flush=True,
            )

        if outcome.hit is False:
            self._consecutive_misses += 1
        else:
            self._consecutive_misses = 0

        self.pending = None
        self.state = "cooldown"
        self.cooldown_until_s = now + self.config.run.cooldown_s
        self.observations.clear()
        self.gate.reset()
        self.last_observation_time = None
        if self._consecutive_misses >= self.config.safety.max_misses_before_fault:
            self._fault(f"{self._consecutive_misses} consecutive misses reached the configured limit", now)

    def _evaluate(self, pending: _Pending, event: ArmEvent) -> ShotOutcome:
        plan = pending.plan
        actual_time = event.actual_strike_time_s
        if actual_time is None:
            actual_time = plan.strike_time_s
        actual_impact = None if event.actual_impact_m is None else np.asarray(event.actual_impact_m, dtype=float)

        timing_error = None
        execution_error = None
        if actual_impact is not None:
            timing_error = (actual_time - plan.strike_time_s) * 1000.0
            try:
                predicted = self.estimator.state_at(pending.fit, actual_time)
                execution_error = float(np.linalg.norm(actual_impact - predicted.position_m))
            except ValueError:
                execution_error = None

        perception_error = None
        total_error = None
        hit: bool | None = None
        if self.truth_fn is not None:
            try:
                truth_at_intercept = self.truth_fn(pending.intercept.time_s)
                if truth_at_intercept is not None:
                    perception_error = float(
                        np.linalg.norm(pending.intercept.position_m - truth_at_intercept.position_m)
                    )
                if actual_impact is not None:
                    truth_at_actual = self.truth_fn(actual_time)
                    if truth_at_actual is not None:
                        total_error = float(np.linalg.norm(actual_impact - truth_at_actual.position_m))
                        hit = total_error <= self.config.safety.strike_tolerance_m
            except Exception:
                # Ground truth is a diagnostic only; never let it stop a run.
                perception_error = None

        if actual_impact is None:
            detail = "controller-reported (no impact measurement)"
        elif hit is None:
            detail = "impact measured, no ground truth"
        else:
            detail = "hit" if hit else "miss"
        return ShotOutcome(
            sequence=event.sequence,
            hit=hit,
            planned_time_s=plan.strike_time_s,
            actual_time_s=actual_time,
            timing_error_ms=timing_error,
            execution_error_m=execution_error,
            perception_error_m=perception_error,
            total_error_m=total_error,
            detail=detail,
        )

    def _reject(self, reason: str, now: float) -> None:
        key = reason.split("(")[0].split(":")[0].strip()
        self.summary.reject(key)
        self._record("rejection", now, reason=reason, key=key)

    def _fault(self, message: str, now: float) -> None:
        self.summary.fault = message
        self.state = "fault"
        self.pending = None
        self._record("fault", now, message=message)
        try:
            self.arm.abort(message)
        except Exception:
            pass

    def _prune(self, now: float) -> None:
        cutoff = now - 0.6
        self.observations = [observation for observation in self.observations if observation.time_s >= cutoff]
        if len(self.observations) > 200:
            self.observations = self.observations[-200:]

    def _status(self, now: float) -> None:
        fit = "-" if self.last_fit is None else f"{self.last_fit.rms_px:.1f} px"
        intercept = (
            "-" if self.last_intercept is None else f"{(self.last_intercept.time_s - now) * 1000:.0f} ms"
        )
        print(
            f"t={now - self.start_time_s:6.2f}s  state={self.state:9s}  frames={self.summary.frames:5d}  "
            f"obs={len(self.observations):3d}  fit={fit:8s}  intercept={intercept:8s}  strikes={self.summary.strikes}",
            flush=True,
        )

    def _record(self, record_kind: str, now: float, **data: Any) -> None:
        if self.recorder is not None:
            self.recorder.write(record_kind, now, **data)


@dataclass
class System:
    config: Config
    clock: Clock
    source: Any
    arm: Any
    pipeline: Pipeline

    def run(self) -> RunSummary:
        return self.pipeline.run()

    def close(self) -> None:
        for action in (self.pipeline.close, self.source.close, self.arm.close):
            try:
                action()
            except Exception:
                pass


def build_system(
    config: Config,
    *,
    seed: int | None = None,
    monitor: bool = False,
    record: bool = True,
    force_mock_arm: bool = False,
    verbose: bool = True,
) -> System:
    simulated = config.camera.kind == "simulated"
    clock: Clock = VirtualClock(0.0) if simulated else RealClock()
    truth_fn: Callable[[float], Any] | None = None
    if simulated:
        source = SimulatedSource(config, clock, seed)
        truth_fn = source.truth_at
    elif config.camera.kind == "remote":
        source = RemoteObservationSource(config, clock=clock.now)
    else:
        source = CameraSource(config)

    if force_mock_arm or config.arm.kind == "mock":
        arm = MockArm(config.arm)
    else:
        arm = EpsonArm(config.arm, read_only=monitor)
    try:
        arm.connect()
    except Exception:
        source.close()
        raise

    recorder = Recorder(config.run.record_dir, config, clock) if record else None
    pipeline = Pipeline(
        config,
        source,
        arm,
        clock,
        allow_strike=not monitor,
        truth_fn=truth_fn,
        recorder=recorder,
        verbose=verbose,
    )
    return System(config, clock, source, arm, pipeline)

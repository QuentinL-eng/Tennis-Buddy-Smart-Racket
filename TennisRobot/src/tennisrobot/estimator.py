"""Monocular flight estimation and intercept prediction.

A single camera gives a ray per detection.  Apparent ball size supplies a noisy
depth, and a window of such points is fitted with the same drag model used for
prediction.  The fit is a small Gauss-Newton solve over the six initial-state
parameters; both the image centre and the projected radius are residuals, which
is what makes depth observable at all.

The residual integrates one short time grid per evaluation and interpolates the
observation times, rather than integrating once per observation.  That keeps a
48-observation fit at about 12 ms on the development laptop and about 140 ms on
the UNO Q's CPU (measured).  The board therefore cannot sustain the default
240 fps fit cadence; see ``docs/FEASIBILITY.md``.

This is the weakest link in a monocular system.  The estimator reports its pixel
residual so the safety layer can refuse to swing on a bad fit, and the docs call
out the accuracy limits measured in simulation.
"""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np

from .camera import PinholeCamera
from .config import EstimatorSpec
from .geometry import unit
from .physics import FlightModel
from .types import BallObservation, BallState, FitResult, Intercept


@dataclass(frozen=True)
class _Prepared:
    t_ref: float
    times: np.ndarray
    pixels: np.ndarray
    radii: np.ndarray
    radius_slots: np.ndarray  # residual slot per observation, or -1
    grid_times: np.ndarray
    grid_index: np.ndarray
    grid_fraction: np.ndarray


class FlightEstimator:
    def __init__(self, camera: PinholeCamera, flight: FlightModel, settings: EstimatorSpec):
        self.camera = camera
        self.flight = flight
        self.settings = settings

    # ------------------------------------------------------------------ public
    def fit(self, observations: list[BallObservation]) -> FitResult | None:
        """Fit a flight state to the last window of detections."""
        prepared = self._prepare(observations)
        if prepared is None:
            return None
        initial = self._initial_guess(prepared)
        if initial is None:
            return None

        solved = self._solve(prepared, initial)
        if solved is None:
            return None
        params, rms, rms_radius, iterations, converged = solved

        errors = self._pixel_errors(params, prepared)
        if errors is None:
            return None
        center_errors = np.linalg.norm(errors[:, :2], axis=1)
        median = float(np.median(center_errors))
        threshold = max(self.settings.outlier_px, 3.0 * median)
        inliers = center_errors <= threshold
        if 0 < int((~inliers).sum()) and int(inliers.sum()) >= self.settings.min_observations:
            reduced = self._subset(prepared, inliers)
            retried = self._solve(reduced, params)
            if retried is not None:
                params, rms, rms_radius, iterations, converged = retried
                prepared = reduced
                errors = self._pixel_errors(params, prepared)
                if errors is not None:
                    rms = float(np.sqrt(np.mean(np.sum(errors[:, :2] ** 2, axis=1))))

        # Re-centre the reported state on the newest observation.  The fitted
        # trajectory is the same, but the estimate at the end of the window is
        # better conditioned than the one extrapolated back to its start.
        end_time = float(prepared.times[-1])
        end_state = self.flight.propagate_to(
            BallState(prepared.t_ref, params[:3], params[3:]), end_time
        )
        return FitResult(
            t_ref_s=end_time,
            position_m=end_state.position_m.copy(),
            velocity_m_s=end_state.velocity_m_s.copy(),
            rms_px=float(rms),
            rms_radius_px=float(rms_radius),
            n_observations=int(prepared.times.size),
            iterations=int(iterations),
            converged=bool(converged),
        )

    def predict_intercept(
        self,
        fit: FitResult,
        plane_point_m: np.ndarray,
        plane_normal: np.ndarray,
        now_s: float,
        max_horizon_s: float = 1.2,
    ) -> Intercept | None:
        """First crossing of the strike plane after ``now``, within the horizon."""
        normal = unit(plane_normal, "strike plane normal")
        point = np.asarray(plane_point_m, dtype=float).reshape(3)

        start = max(float(now_s), fit.t_ref_s)
        state = self.flight.propagate_to(fit.state(), start)
        distance = float(np.dot(state.position_m - point, normal))
        if distance <= 0.0:
            return None

        step = self.settings.intercept_step_s
        end = start + max_horizon_s
        previous_time = start
        previous_state = state
        previous_distance = distance

        while previous_time < end - 1e-9:
            next_time = min(previous_time + step, end)
            next_state = self.flight.propagate_to(previous_state, next_time)
            next_distance = float(np.dot(next_state.position_m - point, normal))
            if previous_distance > 0.0 >= next_distance and float(np.dot(next_state.velocity_m_s, normal)) < 0.0:
                low_time, low_state = previous_time, previous_state
                high_time, high_state = next_time, next_state
                for _ in range(24):
                    middle = 0.5 * (low_time + high_time)
                    middle_state = self.flight.propagate_to(low_state, middle)
                    middle_distance = float(np.dot(middle_state.position_m - point, normal))
                    if middle_distance > 0.0:
                        low_time, low_state = middle, middle_state
                    else:
                        high_time, high_state = middle, middle_state
                return Intercept(
                    time_s=high_time,
                    position_m=high_state.position_m.copy(),
                    ball_velocity_m_s=high_state.velocity_m_s.copy(),
                )
            previous_time, previous_state, previous_distance = next_time, next_state, next_distance
        return None

    def state_at(self, fit: FitResult, time_s: float) -> BallState:
        if time_s < fit.t_ref_s:
            raise ValueError("cannot evaluate a fit before its reference time")
        return self.flight.propagate_to(fit.state(), time_s)

    # ----------------------------------------------------------------- private
    def _prepare(self, observations: list[BallObservation]) -> _Prepared | None:
        clean: list[BallObservation] = []
        for observation in observations:
            if not all(np.isfinite([observation.time_s, observation.u_px, observation.v_px])):
                continue
            if observation.confidence <= 0.0:
                continue
            clean.append(observation)
        if len(clean) < self.settings.min_observations:
            return None
        clean.sort(key=lambda item: item.time_s)

        window = clean[-self.settings.window_observations :]
        times: list[float] = []
        pixels: list[tuple[float, float]] = []
        radii: list[float] = []
        for observation in window:
            if times and observation.time_s - times[-1] <= 1e-9:
                continue
            times.append(observation.time_s)
            pixels.append((observation.u_px, observation.v_px))
            radius = observation.radius_px
            radii.append(float(radius) if radius is not None and np.isfinite(radius) and radius > 0 else np.nan)
        if len(times) < self.settings.min_observations:
            return None
        if times[-1] - times[0] < 0.02:
            return None

        return self._make_prepared(
            float(times[0]),
            np.asarray(times, dtype=float),
            np.asarray(pixels, dtype=float),
            np.asarray(radii, dtype=float),
        )

    def _make_prepared(
        self, t_ref: float, times: np.ndarray, pixels: np.ndarray, radii: np.ndarray
    ) -> _Prepared:
        radius_slots = np.full(times.size, -1, dtype=int)
        if self.settings.use_radius:
            slot = 0
            for index, radius in enumerate(radii):
                if np.isfinite(radius):
                    radius_slots[index] = slot
                    slot += 1

        duration = float(times[-1] - t_ref)
        intervals = max(1, int(np.ceil(duration / self.settings.max_step_s)))
        grid_times = t_ref + np.linspace(0.0, duration, intervals + 1)
        grid_index = np.searchsorted(grid_times, times, side="right") - 1
        grid_index = np.clip(grid_index, 0, intervals - 1)
        span = grid_times[grid_index + 1] - grid_times[grid_index]
        grid_fraction = np.clip((times - grid_times[grid_index]) / span, 0.0, 1.0)

        return _Prepared(
            t_ref=t_ref,
            times=times,
            pixels=pixels,
            radii=radii,
            radius_slots=radius_slots,
            grid_times=grid_times,
            grid_index=grid_index,
            grid_fraction=grid_fraction,
        )

    def _subset(self, prepared: _Prepared, mask: np.ndarray) -> _Prepared:
        return self._make_prepared(
            prepared.t_ref,
            prepared.times[mask],
            prepared.pixels[mask],
            prepared.radii[mask],
        )

    def _initial_guess(self, prepared: _Prepared) -> np.ndarray | None:
        usable = np.flatnonzero(np.isfinite(prepared.radii))
        if usable.size < 4:
            return None
        t_ref = prepared.t_ref
        usable_times = prepared.times[usable]
        points = []
        for index in usable:
            radius_px = float(prepared.radii[index])
            depth = self.camera.fx * self.flight.ball.radius_m / radius_px
            u, v = prepared.pixels[index]
            points.append(self.camera.point_at_depth(float(u), float(v), float(depth)))
        points_array = np.asarray(points)
        design = np.column_stack([np.ones(usable_times.size), usable_times - t_ref])
        coefficients, *_ = np.linalg.lstsq(design, points_array, rcond=None)
        return np.concatenate([coefficients[0], coefficients[1]])

    def _grid_states(self, params: np.ndarray, prepared: _Prepared) -> tuple[np.ndarray, np.ndarray]:
        positions = np.empty((prepared.grid_times.size, 3))
        velocities = np.empty((prepared.grid_times.size, 3))
        state = BallState(prepared.t_ref, params[:3], params[3:])
        positions[0] = state.position_m
        velocities[0] = state.velocity_m_s
        for index in range(1, prepared.grid_times.size):
            state = self.flight.step(state, float(prepared.grid_times[index] - prepared.grid_times[index - 1]))
            positions[index] = state.position_m
            velocities[index] = state.velocity_m_s
        return positions, velocities

    def _positions_at_observations(self, params: np.ndarray, prepared: _Prepared) -> np.ndarray:
        """Cubic Hermite interpolation between grid states.

        The grid can be coarse (40 ms) without smearing the observations, because
        both endpoint positions and velocities are known.
        """
        positions, velocities = self._grid_states(params, prepared)
        index = prepared.grid_index
        span = (prepared.grid_times[index + 1] - prepared.grid_times[index])[:, None]
        s = prepared.grid_fraction[:, None]
        s2 = s * s
        s3 = s2 * s
        h00 = 2.0 * s3 - 3.0 * s2 + 1.0
        h10 = s3 - 2.0 * s2 + s
        h01 = -2.0 * s3 + 3.0 * s2
        h11 = s3 - s2
        return (
            h00 * positions[index]
            + h10 * span * velocities[index]
            + h01 * positions[index + 1]
            + h11 * span * velocities[index + 1]
        )

    def _residual(self, params: np.ndarray, prepared: _Prepared) -> np.ndarray | None:
        positions = self._positions_at_observations(params, prepared)
        uv, valid = self.camera.project_many(positions)
        if not bool(np.all(valid)):
            return None

        center = 2 * prepared.times.size
        radius_count = int(prepared.radius_slots.max() + 1) if prepared.times.size else 0
        residual = np.empty(center + radius_count)
        residual[:center] = ((uv - prepared.pixels) / self.settings.center_sigma_px).reshape(-1)
        if radius_count:
            radii = self.camera.pixel_radii(positions, self.flight.ball.radius_m)
            for index, slot in enumerate(prepared.radius_slots):
                if slot >= 0:
                    residual[center + slot] = (
                        radii[index] - prepared.radii[index]
                    ) / self.settings.radius_sigma_px
        return residual

    def _solve(
        self, prepared: _Prepared, initial: np.ndarray
    ) -> tuple[np.ndarray, float, float, int, bool] | None:
        params = np.asarray(initial, dtype=float).copy()
        base = self._residual(params, prepared)
        if base is None:
            return None
        cost = 0.5 * float(base @ base)
        damping = 1e-3
        steps = np.array([1e-3, 1e-3, 1e-3, 1e-2, 1e-2, 1e-2])
        converged = False
        iterations = 0

        for iterations in range(1, self.settings.max_iterations + 1):
            jacobian = np.zeros((base.size, 6))
            for column in range(6):
                trial = params.copy()
                trial[column] += steps[column]
                residual = self._residual(trial, prepared)
                if residual is None or residual.size != base.size:
                    continue
                jacobian[:, column] = (residual - base) / steps[column]
            normal = jacobian.T @ jacobian
            gradient = jacobian.T @ base
            diagonal = np.maximum(np.diag(normal), 1e-12)
            accepted = False
            delta = np.zeros(6)
            improvement = 0.0
            for _ in range(8):
                try:
                    delta = np.linalg.solve(normal + damping * np.diag(diagonal), -gradient)
                except np.linalg.LinAlgError:
                    delta = np.linalg.lstsq(normal + damping * np.diag(diagonal), -gradient, rcond=None)[0]
                delta[:3] = np.clip(delta[:3], -0.75, 0.75)
                delta[3:] = np.clip(delta[3:], -10.0, 10.0)
                trial_params = params + delta
                trial_residual = self._residual(trial_params, prepared)
                if trial_residual is None or trial_residual.size != base.size:
                    damping *= 10.0
                    continue
                trial_cost = 0.5 * float(trial_residual @ trial_residual)
                if trial_cost < cost:
                    improvement = cost - trial_cost
                    params, base, cost = trial_params, trial_residual, trial_cost
                    damping = max(1e-9, damping / 3.0)
                    accepted = True
                    break
                damping *= 10.0
            if not accepted:
                break
            if float(np.linalg.norm(delta)) < 1e-6 or improvement <= 1e-6 * max(cost, 1e-12):
                converged = True
                break

        errors = self._pixel_errors(params, prepared)
        if errors is None:
            return None
        rms = float(np.sqrt(np.mean(np.sum(errors[:, :2] ** 2, axis=1))))
        radius_errors = errors[:, 2][np.isfinite(errors[:, 2])]
        rms_radius = float(np.sqrt(np.mean(radius_errors**2))) if radius_errors.size else 0.0
        if not np.isfinite(rms) or rms > 100.0:
            return None
        return params, rms, rms_radius, iterations, converged

    def _pixel_errors(self, params: np.ndarray, prepared: _Prepared) -> np.ndarray | None:
        """Per-observation ``(du, dv, radius_error)`` in pixels (radius may be NaN)."""
        positions = self._positions_at_observations(params, prepared)
        uv, valid = self.camera.project_many(positions)
        if not bool(np.all(valid)):
            return None
        errors = np.full((prepared.times.size, 3), np.nan)
        errors[:, :2] = uv - prepared.pixels
        radii = self.camera.pixel_radii(positions, self.flight.ball.radius_m)
        errors[:, 2] = np.where(np.isfinite(prepared.radii), radii - prepared.radii, np.nan)
        return errors

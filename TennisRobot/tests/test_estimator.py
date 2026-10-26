import numpy as np

from tennisrobot.estimator import FlightEstimator
from tennisrobot.physics import BallProperties, FlightModel
from tennisrobot.types import BallObservation, BallState


def _flight(config, max_step: float = 0.002) -> FlightModel:
    ball = config.ball
    return FlightModel(
        BallProperties(
            mass_kg=ball.mass_kg,
            radius_m=ball.radius_m,
            drag_coefficient=ball.drag_coefficient,
            air_density_kg_m3=ball.air_density_kg_m3,
            lift_slope=ball.lift_slope,
        ),
        spin_rad_s=np.asarray(ball.spin_rad_s, dtype=float),
        max_step_s=max_step,
    )


def _shot(config, camera, rng, *, noise: float = 0.0, lead: float = 0.35, outlier: bool = False):
    flight = _flight(config)
    truth = BallState(
        0.0,
        np.array([0.0, 6.5, 1.15]),
        np.array([rng.uniform(-0.35, 0.35), -9.5 * rng.uniform(0.96, 1.04), 2.9]),
    )
    crossing = truth
    while crossing.position_m[1] > 0.58 and crossing.time_s < 2.0:
        crossing = flight.step(crossing, 0.001)

    observations: list[BallObservation] = []
    time_s = 0.02
    end = crossing.time_s - lead
    while time_s < end:
        state = flight.propagate_to(truth, time_s)
        projection = camera.project(state.position_m)
        radius = camera.pixel_radius(state.position_m, config.ball.radius_m)
        if projection is not None and camera.in_image(*projection) and radius >= 1.5:
            observations.append(
                BallObservation(
                    time_s,
                    projection[0] + rng.normal(0.0, noise),
                    projection[1] + rng.normal(0.0, noise),
                    radius + rng.normal(0.0, noise * 1.6),
                    1.0,
                )
            )
        time_s += 1.0 / config.camera.fps
    if outlier:
        observations.append(BallObservation(end, 100.0, 100.0, 10.0, 1.0))
    return flight, crossing, observations


def test_noiseless_fit_recovers_the_flight(config, camera):
    flight, crossing, observations = _shot(config, camera, np.random.default_rng(1))
    estimator = FlightEstimator(camera, flight, config.estimator)
    fit = estimator.fit(observations)
    assert fit is not None
    assert fit.rms_px < 0.05
    intercept = estimator.predict_intercept(
        fit, np.array([0.0, 0.58, 0.0]), np.array([0.0, 1.0, 0.0]), observations[-1].time_s
    )
    assert intercept is not None
    assert np.linalg.norm(intercept.position_m - crossing.position_m) < 0.01
    assert abs(intercept.time_s - crossing.time_s) < 0.002


def test_noisy_fit_stays_close_at_the_decision_point(config, camera):
    errors = []
    for seed in (2, 3, 4):
        flight, crossing, observations = _shot(
            config, camera, np.random.default_rng(seed), noise=0.25, lead=0.35
        )
        estimator = FlightEstimator(camera, flight, config.estimator)
        fit = estimator.fit(observations)
        assert fit is not None
        intercept = estimator.predict_intercept(
            fit, np.array([0.0, 0.58, 0.0]), np.array([0.0, 1.0, 0.0]), observations[-1].time_s
        )
        assert intercept is not None
        errors.append(np.linalg.norm(intercept.position_m - crossing.position_m))
    assert np.median(errors) < 0.06


def test_single_false_detection_does_not_ruin_the_fit(config, camera):
    flight, crossing, observations = _shot(
        config, camera, np.random.default_rng(9), noise=0.25, lead=0.35, outlier=True
    )
    estimator = FlightEstimator(camera, flight, config.estimator)
    fit = estimator.fit(observations)
    assert fit is not None
    intercept = estimator.predict_intercept(
        fit, np.array([0.0, 0.58, 0.0]), np.array([0.0, 1.0, 0.0]), observations[-1].time_s
    )
    assert intercept is not None
    assert np.linalg.norm(intercept.position_m - crossing.position_m) < 0.15


def test_without_a_radius_there_is_no_depth_cue(config, camera):
    flight, _crossing, observations = _shot(config, camera, np.random.default_rng(5))
    stripped = [
        BallObservation(item.time_s, item.u_px, item.v_px, None, item.confidence) for item in observations
    ]
    estimator = FlightEstimator(camera, flight, config.estimator)
    assert estimator.fit(stripped) is None


def test_no_intercept_after_the_ball_has_passed(config, camera):
    flight, crossing, observations = _shot(config, camera, np.random.default_rng(6))
    estimator = FlightEstimator(camera, flight, config.estimator)
    fit = estimator.fit(observations)
    assert fit is not None
    assert (
        estimator.predict_intercept(
            fit, np.array([0.0, 0.58, 0.0]), np.array([0.0, 1.0, 0.0]), crossing.time_s + 0.1
        )
        is None
    )

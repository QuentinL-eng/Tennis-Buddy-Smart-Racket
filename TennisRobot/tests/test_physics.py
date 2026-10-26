import numpy as np

from tennisrobot.physics import BallProperties, FlightModel
from tennisrobot.types import BallState


def _model(drag: float = 0.0, spin=(0.0, 0.0, 0.0), max_step: float = 0.001) -> FlightModel:
    return FlightModel(
        BallProperties(drag_coefficient=drag),
        spin_rad_s=np.asarray(spin, dtype=float),
        max_step_s=max_step,
    )


def test_free_fall_matches_analytic_solution():
    model = _model()
    state = BallState(0.0, np.array([0.0, 0.0, 10.0]), np.array([0.0, 0.0, 0.0]))
    for _ in range(1000):
        state = model.step(state, 0.001)
    assert np.isclose(state.position_m[2], 10.0 - 0.5 * 9.80665 * 1.0**2, atol=2e-3)
    assert np.isclose(state.velocity_m_s[2], -9.80665, atol=1e-3)


def test_drag_shortens_a_projectile():
    start = BallState(0.0, np.array([0.0, 0.0, 2.0]), np.array([30.0, 0.0, 0.0]))
    plain = _model(drag=0.0)
    dragged = _model(drag=0.507)

    plain_state = start
    dragged_state = start
    for _ in range(3000):
        plain_state = plain.step(plain_state, 0.001)
        dragged_state = dragged.step(dragged_state, 0.001)
    assert dragged_state.position_m[0] < plain_state.position_m[0] - 1.0


def test_topspin_accelerates_downwards():
    model = _model(drag=0.0, spin=(200.0, 0.0, 0.0))
    acceleration = model.acceleration(np.array([0.0, -10.0, 0.0]))
    assert acceleration[2] < -9.80665


def test_propagation_is_independent_of_step_size():
    start = BallState(0.0, np.array([0.0, 5.0, 1.0]), np.array([0.5, -10.0, 3.0]))
    coarse = _model(drag=0.507, max_step=0.01).propagate_to(start, 0.5)
    fine = _model(drag=0.507, max_step=0.0005).propagate_to(start, 0.5)
    assert np.allclose(coarse.position_m, fine.position_m, atol=2e-5)
    assert np.allclose(coarse.velocity_m_s, fine.velocity_m_s, atol=2e-5)

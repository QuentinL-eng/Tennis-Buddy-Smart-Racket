import numpy as np

from tennisrobot.geometry import (
    Transform,
    axes_frame,
    euler_zyx_to_matrix,
    matrix_to_euler_zyx,
)


def test_euler_roundtrip():
    rng = np.random.default_rng(4)
    for _ in range(300):
        angles = rng.uniform(-179.0, 179.0, size=3)
        matrix = euler_zyx_to_matrix(*angles)
        recovered = euler_zyx_to_matrix(*matrix_to_euler_zyx(matrix))
        assert np.allclose(matrix, recovered, atol=1e-8)


def test_euler_gimbal_lock_is_still_the_same_rotation():
    matrix = euler_zyx_to_matrix(20.0, 90.0, 30.0)
    recovered = euler_zyx_to_matrix(*matrix_to_euler_zyx(matrix))
    assert np.allclose(matrix, recovered, atol=1e-8)


def test_transform_compose_and_inverse():
    parent = Transform.from_pose([1.0, -2.0, 0.5, 12.0, -7.0, 33.0])
    child = Transform.from_pose([0.3, 0.1, -0.2, -4.0, 8.0, 11.0])
    point = np.array([0.2, -0.4, 1.1])

    combined = parent @ child
    assert np.allclose(combined.apply_point(point), parent.apply_point(child.apply_point(point)))
    assert np.allclose(parent.inverse().apply_point(parent.apply_point(point)), point)
    assert np.allclose(parent.pose6(), Transform.from_pose(parent.pose6()).pose6())


def test_look_at_points_at_target_and_down_is_negative_up():
    eye = np.array([2.0, -1.0, 1.7])
    target = np.array([0.0, 2.2, 1.05])
    pose = Transform.look_at(eye, target)
    forward = pose.apply_vector([0.0, 0.0, 1.0])
    down = pose.apply_vector([0.0, 1.0, 0.0])
    assert np.allclose(forward, (target - eye) / np.linalg.norm(target - eye))
    assert down[2] < 0.0
    assert np.isclose(np.linalg.det(pose.rotation), 1.0)


def test_axes_frame_orthonormal_and_uses_face_normal():
    frame = axes_frame([0.2, 0.9, -0.1], [0.0, 0.0, 1.0], [1.0, 2.0, 3.0])
    assert np.allclose(frame.rotation.T @ frame.rotation, np.eye(3), atol=1e-12)
    assert np.isclose(np.linalg.det(frame.rotation), 1.0)
    assert np.allclose(frame.rotation[:, 1], np.array([0.2, 0.9, -0.1]) / np.linalg.norm([0.2, 0.9, -0.1]))
    assert np.allclose(frame.translation, [1.0, 2.0, 3.0])
    assert np.isclose(np.dot(frame.rotation[:, 1], frame.rotation[:, 2]), 0.0)


def test_camera_project_and_backproject(camera):
    point = np.array([0.2, 2.0, 0.9])
    projection = camera.project(point)
    assert projection is not None
    u, v = projection
    assert camera.in_image(u, v)
    depth = (camera.pose.inverse().apply_point(point))[2]
    recovered = camera.point_at_depth(u, v, depth)
    assert np.allclose(recovered, point, atol=1e-9)

    origin, direction = camera.ray(u, v)
    offset = point - origin
    assert np.allclose(direction, offset / np.linalg.norm(offset), atol=1e-9)


def test_camera_rejects_points_behind_it(camera):
    behind = camera.pose.apply_point(np.array([0.0, 0.0, -1.0]))
    assert camera.project(behind) is None

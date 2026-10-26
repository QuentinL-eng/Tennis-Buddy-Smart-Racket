"""Rigid transforms and frame helpers.

Conventions used everywhere in this project:

* ``world`` is right-handed with +Z up. Its origin is the robot base on the
  floor, +X points to the robot's right, +Y points forward towards the court
  (the incoming ball) and +Z points up.
* A camera uses the optical convention: +X right in the image, +Y down in the
  image, +Z along the optical axis away from the lens.
* A racket frame has its origin at the butt cap, +Z along the shaft towards the
  tip, +Y out of the string bed (face normal) and +X across the strings.
* An Epson tool frame has +Z out of the flange.

Rotations in configuration files are XYZ Euler angles in degrees, interpreted as
``R = Rz(yaw) @ Ry(pitch) @ Rx(roll)``.  That is the common industrial
yaw/pitch/roll order; validate it against a known pose on the real controller
before trusting a converted pose.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field

import numpy as np

Vec3 = np.ndarray


def unit(vector: Vec3, name: str = "vector") -> Vec3:
    """Return a unit copy of ``vector``, raising if it has no direction."""
    value = np.asarray(vector, dtype=float)
    length = float(np.linalg.norm(value))
    if length < 1e-12:
        raise ValueError(f"{name} must have non-zero length")
    return value / length


def rot_x(degrees: float) -> np.ndarray:
    a = math.radians(degrees)
    c, s = math.cos(a), math.sin(a)
    return np.array([[1.0, 0.0, 0.0], [0.0, c, -s], [0.0, s, c]])


def rot_y(degrees: float) -> np.ndarray:
    a = math.radians(degrees)
    c, s = math.cos(a), math.sin(a)
    return np.array([[c, 0.0, s], [0.0, 1.0, 0.0], [-s, 0.0, c]])


def rot_z(degrees: float) -> np.ndarray:
    a = math.radians(degrees)
    c, s = math.cos(a), math.sin(a)
    return np.array([[c, -s, 0.0], [s, c, 0.0], [0.0, 0.0, 1.0]])


def euler_zyx_to_matrix(roll_deg: float, pitch_deg: float, yaw_deg: float) -> np.ndarray:
    """Rz(yaw) @ Ry(pitch) @ Rx(roll)."""
    return rot_z(yaw_deg) @ rot_y(pitch_deg) @ rot_x(roll_deg)


def matrix_to_euler_zyx(rotation: np.ndarray) -> tuple[float, float, float]:
    """Inverse of :func:`euler_zyx_to_matrix`, in degrees."""
    r = np.asarray(rotation, dtype=float)
    sin_pitch = float(np.clip(-r[2, 0], -1.0, 1.0))
    pitch = math.asin(sin_pitch)
    if abs(sin_pitch) < 1.0 - 1e-10:
        roll = math.atan2(r[2, 1], r[2, 2])
        yaw = math.atan2(r[1, 0], r[0, 0])
    else:  # gimbal lock: only roll - yaw (or roll + yaw) is observable
        roll = math.atan2(-r[1, 2], r[1, 1])
        yaw = 0.0
    return math.degrees(roll), math.degrees(pitch), math.degrees(yaw)


@dataclass(frozen=True)
class Transform:
    """A rigid transform that maps coordinates from a child frame to its parent."""

    rotation: np.ndarray = field(default_factory=lambda: np.eye(3))
    translation: np.ndarray = field(default_factory=lambda: np.zeros(3))

    def __post_init__(self) -> None:
        rotation = np.asarray(self.rotation, dtype=float)
        translation = np.asarray(self.translation, dtype=float).reshape(3)
        if rotation.shape != (3, 3):
            raise ValueError(f"rotation must be 3x3, got {rotation.shape}")
        object.__setattr__(self, "rotation", rotation)
        object.__setattr__(self, "translation", translation)

    @classmethod
    def identity(cls) -> "Transform":
        return cls(np.eye(3), np.zeros(3))

    @classmethod
    def from_translation(cls, translation: Vec3) -> "Transform":
        return cls(np.eye(3), translation)

    @classmethod
    def from_rpy(cls, translation: Vec3, roll_deg: float, pitch_deg: float, yaw_deg: float) -> "Transform":
        return cls(euler_zyx_to_matrix(roll_deg, pitch_deg, yaw_deg), translation)

    @classmethod
    def from_pose(cls, pose: tuple[float, ...] | list[float] | np.ndarray) -> "Transform":
        """Build from ``[x, y, z, roll, pitch, yaw]`` (metres and degrees)."""
        values = np.asarray(pose, dtype=float).reshape(-1)
        if values.size == 16:
            matrix = values.reshape(4, 4)
            return cls(matrix[:3, :3], matrix[:3, 3])
        if values.size != 6:
            raise ValueError("a pose needs 6 values (x,y,z,roll,pitch,yaw) or a 4x4 matrix")
        return cls.from_rpy(values[:3], values[3], values[4], values[5])

    @classmethod
    def look_at(cls, eye: Vec3, target: Vec3, up: Vec3 = (0.0, 0.0, 1.0)) -> "Transform":
        """Camera pose looking from ``eye`` at ``target`` (optical +Z forward)."""
        forward = unit(np.asarray(target, dtype=float) - np.asarray(eye, dtype=float), "view direction")
        world_up = unit(up, "up")
        right = np.cross(forward, world_up)
        if np.linalg.norm(right) < 1e-9:  # looking straight up or down
            right = np.cross(forward, np.array([0.0, 1.0, 0.0]))
        right = unit(right, "camera right")
        down = unit(np.cross(forward, right), "camera down")
        rotation = np.column_stack([right, down, forward])
        return cls(rotation, np.asarray(eye, dtype=float))

    def compose(self, child: "Transform") -> "Transform":
        """``self @ child``: ``child`` expressed in ``self``'s frame."""
        return Transform(self.rotation @ child.rotation, self.translation + self.rotation @ child.translation)

    def __matmul__(self, child: "Transform") -> "Transform":
        return self.compose(child)

    def inverse(self) -> "Transform":
        rotation = self.rotation.T
        return Transform(rotation, -rotation @ self.translation)

    def apply_point(self, point: Vec3) -> Vec3:
        return self.rotation @ np.asarray(point, dtype=float) + self.translation

    def apply_vector(self, vector: Vec3) -> Vec3:
        return self.rotation @ np.asarray(vector, dtype=float)

    def pose6(self) -> tuple[float, float, float, float, float, float]:
        roll, pitch, yaw = matrix_to_euler_zyx(self.rotation)
        x, y, z = self.translation
        return float(x), float(y), float(z), roll, pitch, yaw

    def orthonormalized(self) -> "Transform":
        """Project a drifted rotation back onto SO(3)."""
        u, _, vt = np.linalg.svd(self.rotation)
        rotation = u @ vt
        if np.linalg.det(rotation) < 0:
            u[:, -1] *= -1
            rotation = u @ vt
        return Transform(rotation, self.translation)


def axes_frame(y_axis: Vec3, z_hint: Vec3, origin: Vec3) -> Transform:
    """Build a frame from a required +Y axis and a hint for +Z.

    Used for the racket: +Y is the face normal and +Z is the shaft direction.
    The hint is projected onto the plane perpendicular to +Y, so any component
    of the hint along the normal is ignored.  ``+X = +Y x +Z`` keeps the frame
    right-handed.
    """
    y = unit(y_axis, "face normal")
    hint = np.asarray(z_hint, dtype=float)
    z = hint - y * float(np.dot(hint, y))
    if np.linalg.norm(z) < 1e-9:
        raise ValueError("shaft hint is parallel to the face normal; give an independent direction")
    z = unit(z, "shaft direction")
    x = unit(np.cross(y, z), "racket width direction")
    rotation = np.column_stack([x, y, z])
    return Transform(rotation, np.asarray(origin, dtype=float))


def project_to_plane(point: Vec3, plane_point: Vec3, plane_normal: Vec3) -> Vec3:
    normal = unit(plane_normal, "plane normal")
    distance = float(np.dot(np.asarray(point, dtype=float) - np.asarray(plane_point, dtype=float), normal))
    return np.asarray(point, dtype=float) - distance * normal

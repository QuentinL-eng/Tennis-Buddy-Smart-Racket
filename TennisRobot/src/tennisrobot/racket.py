"""Racket geometry and the flange pose that puts a chosen point on the ball.

Racket frame (right-handed): origin at the butt cap, +Z along the shaft towards
the tip, +Y out of the string bed, +X across the strings.  The impact point is a
fixed offset in this frame, so the robot can be commanded in terms of the string
bed rather than the flange.

``T_flange_racket`` (the physical mount) is supplied by calibration.  A desired
world pose for the impact point therefore determines the flange pose exactly:

    T_world_racket  = pose with origin q, orientation R and q + R p_impact = p
    T_world_flange  = T_world_racket @ inverse(T_flange_racket)

Because the impact point travels along a straight line with a fixed orientation,
the flange orientation is constant for the whole swing.
"""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np

from .config import RacketSpec
from .geometry import Transform, axes_frame


@dataclass(frozen=True)
class Racket:
    spec: RacketSpec

    @property
    def impact_local_m(self) -> np.ndarray:
        return np.asarray(self.spec.impact_point_m, dtype=float).reshape(3)

    @property
    def mount(self) -> Transform:
        return Transform.from_pose(self.spec.mount_pose)

    def pose_for_impact(
        self, impact_world_m: np.ndarray, face_normal: np.ndarray, shaft_hint_world: np.ndarray
    ) -> Transform:
        """World pose of the racket frame for a given impact point and orientation."""
        orientation = axes_frame(face_normal, shaft_hint_world, np.zeros(3)).rotation
        origin = np.asarray(impact_world_m, dtype=float).reshape(3) - orientation @ self.impact_local_m
        return Transform(orientation, origin)

    def flange_for_impact(
        self, impact_world_m: np.ndarray, face_normal: np.ndarray, shaft_hint_world: np.ndarray
    ) -> Transform:
        """Flange pose that places the designated racket point at ``impact_world_m``."""
        return self.pose_for_impact(impact_world_m, face_normal, shaft_hint_world) @ self.mount.inverse()

    def impact_point_world(
        self, racket_pose: Transform, impact_local_m: np.ndarray | None = None
    ) -> np.ndarray:
        local = self.impact_local_m if impact_local_m is None else np.asarray(impact_local_m, dtype=float)
        return racket_pose.apply_point(local)

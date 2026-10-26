"""Pinhole camera model and USB (UVC) capture.

The camera model is the calibrated mapping between world points and pixels.  The
capture backend is deliberately thin: it opens a V4L2/UVC device, applies the
requested format and exposure, and timestamps frames on arrival.  Accuracy of
the timestamps and of the exposure setting must be checked on the actual board
(``tools/camera_check.py``) before trusting them for a strike.
"""

from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np

from . import clock
from .config import CameraSpec
from .geometry import Transform, unit

try:  # OpenCV is an optional dependency; core planning works without it.
    import cv2
except ImportError:  # pragma: no cover - exercised on a machine without OpenCV
    cv2 = None


@dataclass(frozen=True)
class PinholeCamera:
    width: int
    height: int
    fx: float
    fy: float
    cx: float
    cy: float
    distortion: tuple[float, float, float, float] = (0.0, 0.0, 0.0, 0.0)
    pose: Transform = field(default_factory=Transform.identity)

    @classmethod
    def from_spec(cls, spec: CameraSpec) -> "PinholeCamera":
        fx, fy, cx, cy = spec.intrinsics()
        k1, k2, p1, p2 = (float(value) for value in spec.distortion)
        return cls(
            width=spec.width,
            height=spec.height,
            fx=fx,
            fy=fy,
            cx=cx,
            cy=cy,
            distortion=(k1, k2, p1, p2),
            pose=spec.transform(),
        )

    def _distort(self, x: float, y: float) -> tuple[float, float]:
        k1, k2, p1, p2 = self.distortion
        r2 = x * x + y * y
        radial = 1.0 + k1 * r2 + k2 * r2 * r2
        xd = x * radial + 2.0 * p1 * x * y + p2 * (r2 + 2.0 * x * x)
        yd = y * radial + p1 * (r2 + 2.0 * y * y) + 2.0 * p2 * x * y
        return xd, yd

    def _undistort(self, u: float, v: float) -> tuple[float, float]:
        k1, k2, p1, p2 = self.distortion
        xd = (u - self.cx) / self.fx
        yd = (v - self.cy) / self.fy
        x, y = xd, yd
        for _ in range(8):
            r2 = x * x + y * y
            radial = 1.0 + k1 * r2 + k2 * r2 * r2
            if abs(radial) < 1e-9:
                break
            dx = 2.0 * p1 * x * y + p2 * (r2 + 2.0 * x * x)
            dy = p1 * (r2 + 2.0 * y * y) + 2.0 * p2 * x * y
            x = (xd - dx) / radial
            y = (yd - dy) / radial
        return x, y

    def project(self, point_world: np.ndarray) -> tuple[float, float] | None:
        """Project a world point to pixels, or return None if behind the camera."""
        point_camera = self.pose.inverse().apply_point(point_world)
        if point_camera[2] <= 1e-6:
            return None
        x = float(point_camera[0] / point_camera[2])
        y = float(point_camera[1] / point_camera[2])
        xd, yd = self._distort(x, y)
        return self.fx * xd + self.cx, self.fy * yd + self.cy

    def project_many(self, points_world: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
        """Vectorised projection: returns ``(uv, valid)`` for an (N, 3) array."""
        points = np.asarray(points_world, dtype=float).reshape(-1, 3)
        # R^T (p - t) == (p - t) @ R for an orthonormal R.
        points_camera = (points - self.pose.translation) @ self.pose.rotation
        depth = points_camera[:, 2]
        valid = depth > 1e-6
        safe_depth = np.where(valid, depth, 1.0)
        x = points_camera[:, 0] / safe_depth
        y = points_camera[:, 1] / safe_depth
        k1, k2, p1, p2 = self.distortion
        r2 = x * x + y * y
        radial = 1.0 + k1 * r2 + k2 * r2 * r2
        xd = x * radial + 2.0 * p1 * x * y + p2 * (r2 + 2.0 * x * x)
        yd = y * radial + p1 * (r2 + 2.0 * y * y) + 2.0 * p2 * x * y
        uv = np.column_stack([self.fx * xd + self.cx, self.fy * yd + self.cy])
        return uv, valid

    def pixel_radius(self, point_world: np.ndarray, radius_m: float) -> float:
        """Approximate projected radius of a sphere at ``point_world``."""
        point_camera = self.pose.inverse().apply_point(point_world)
        depth = float(point_camera[2])
        if depth <= 1e-6:
            return 0.0
        return self.fx * radius_m / depth

    def pixel_radii(self, points_world: np.ndarray, radius_m: float) -> np.ndarray:
        """Vectorised projected radius for an (N, 3) array of sphere centres."""
        points = np.asarray(points_world, dtype=float).reshape(-1, 3)
        points_camera = (points - self.pose.translation) @ self.pose.rotation
        depth = points_camera[:, 2]
        safe_depth = np.where(depth > 1e-6, depth, np.inf)
        return self.fx * radius_m / safe_depth

    def point_at_depth(self, u: float, v: float, depth_m: float) -> np.ndarray:
        """Back-project a pixel to a world point at a given camera-frame depth."""
        x, y = self._undistort(u, v)
        point_camera = np.array([x * depth_m, y * depth_m, depth_m])
        return self.pose.apply_point(point_camera)

    def ray(self, u: float, v: float) -> tuple[np.ndarray, np.ndarray]:
        """World-space origin and unit direction of the ray through a pixel."""
        x, y = self._undistort(u, v)
        direction_camera = unit(np.array([x, y, 1.0]), "camera ray")
        return self.pose.translation.copy(), unit(self.pose.apply_vector(direction_camera), "world ray")

    def in_image(self, u: float, v: float, margin_px: float = 0.0) -> bool:
        return -margin_px <= u < self.width + margin_px and -margin_px <= v < self.height + margin_px


class UvcCamera:
    """A USB webcam/UVC camera opened through OpenCV's V4L2 backend."""

    def __init__(self, spec: CameraSpec):
        if cv2 is None:
            raise RuntimeError("OpenCV is required for a UVC camera: install the '.[vision]' extra")
        self.spec = spec
        self._capture = None
        self.negotiated: dict[str, float | str] = {}

    def open(self) -> None:
        if self._capture is not None:
            return
        device: int | str = int(self.spec.device) if str(self.spec.device).isdigit() else self.spec.device
        capture = cv2.VideoCapture(device, cv2.CAP_V4L2)
        if not capture.isOpened():
            capture.release()
            capture = cv2.VideoCapture(device)
        if not capture.isOpened():
            capture.release()
            raise RuntimeError(f"cannot open camera {self.spec.device!r}")

        capture.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*self.spec.fourcc[:4]))
        capture.set(cv2.CAP_PROP_FRAME_WIDTH, self.spec.width)
        capture.set(cv2.CAP_PROP_FRAME_HEIGHT, self.spec.height)
        capture.set(cv2.CAP_PROP_FPS, self.spec.fps)
        capture.set(cv2.CAP_PROP_BUFFERSIZE, self.spec.buffersize)
        if self.spec.exposure >= 0:
            # V4L2 quirk: 0.25 selects manual exposure on many drivers; the exact
            # meaning of CAP_PROP_EXPOSURE depends on the camera.  Verify it.
            capture.set(cv2.CAP_PROP_AUTO_EXPOSURE, 0.25)
            capture.set(cv2.CAP_PROP_EXPOSURE, self.spec.exposure)
        if self.spec.gain >= 0:
            capture.set(cv2.CAP_PROP_GAIN, self.spec.gain)

        self._capture = capture
        self.negotiated = {
            "width": capture.get(cv2.CAP_PROP_FRAME_WIDTH),
            "height": capture.get(cv2.CAP_PROP_FRAME_HEIGHT),
            "fps": capture.get(cv2.CAP_PROP_FPS),
            "fourcc": int(capture.get(cv2.CAP_PROP_FOURCC)),
            "exposure": capture.get(cv2.CAP_PROP_EXPOSURE),
            "auto_exposure": capture.get(cv2.CAP_PROP_AUTO_EXPOSURE),
            "gain": capture.get(cv2.CAP_PROP_GAIN),
        }

    def read(self) -> tuple[float, np.ndarray] | None:
        """Return ``(monotonic_time_s, bgr_frame)``, or None on a dropped frame."""
        if self._capture is None:
            raise RuntimeError("camera is not open")
        ok, frame = self._capture.read()
        if not ok or frame is None:
            return None
        return clock.now(), frame

    def close(self) -> None:
        if self._capture is not None:
            self._capture.release()
            self._capture = None

    def __enter__(self) -> "UvcCamera":
        self.open()
        return self

    def __exit__(self, *_exc: object) -> None:
        self.close()

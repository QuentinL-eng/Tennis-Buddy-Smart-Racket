"""Ball detection, observation gating and the real-camera source.

The detector is deliberately classical: a tennis ball is a saturated
yellow-green sphere, so a calibrated HSV threshold with a circularity check is a
better first detector than a generic object model, and it costs a fraction of the
CPU.  A learned detector can be dropped in behind the same ``detect`` signature.

Everything here except the gate needs OpenCV.
"""

from __future__ import annotations

import math

import numpy as np

from . import clock
from .camera import UvcCamera
from .config import Config, VisionSpec
from .types import BallObservation

try:  # OpenCV is optional for the planning-only path.
    import cv2
except ImportError:  # pragma: no cover
    cv2 = None


class ColorBlobDetector:
    def __init__(self, spec: VisionSpec):
        self.spec = spec
        self._lower = np.asarray(spec.hsv_lower, dtype=np.uint8)
        self._upper = np.asarray(spec.hsv_upper, dtype=np.uint8)

    def detect(self, frame_bgr: np.ndarray, time_s: float) -> list[BallObservation]:
        if cv2 is None:
            raise RuntimeError("OpenCV is required for ball detection: install the '.[vision]' extra")
        hsv = cv2.cvtColor(frame_bgr, cv2.COLOR_BGR2HSV)
        mask = cv2.inRange(hsv, self._lower, self._upper)
        kernel = np.ones((3, 3), dtype=np.uint8)
        mask = cv2.morphologyEx(mask, cv2.MORPH_OPEN, kernel, iterations=1)
        mask = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, kernel, iterations=1)
        contours, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)

        candidates: list[BallObservation] = []
        for contour in contours:
            area = float(cv2.contourArea(contour))
            if area < self.spec.min_area_px:
                continue
            perimeter = float(cv2.arcLength(contour, True))
            if perimeter <= 0.0:
                continue
            circularity = 4.0 * math.pi * area / (perimeter * perimeter)
            if circularity < self.spec.min_circularity:
                continue
            (u, v), radius = cv2.minEnclosingCircle(contour)
            if not self.spec.min_radius_px <= radius <= self.spec.max_radius_px:
                continue
            candidates.append(
                BallObservation(
                    time_s=time_s,
                    u_px=float(u),
                    v_px=float(v),
                    radius_px=float(radius),
                    confidence=float(min(1.0, circularity)),
                )
            )
        candidates.sort(key=lambda item: item.confidence, reverse=True)
        return candidates[: self.spec.max_candidates]


class ObservationGate:
    """Reject detections that are too confident-poor or physically implausible."""

    def __init__(self, spec: VisionSpec):
        self.spec = spec
        self.last: BallObservation | None = None

    def reset(self) -> None:
        self.last = None

    def accept(self, observation: BallObservation) -> bool:
        if observation.confidence < self.spec.min_confidence:
            return False
        if self.last is not None:
            dt = observation.time_s - self.last.time_s
            if dt <= 0.0:
                return False
            if dt <= 0.25:
                jump = math.hypot(observation.u_px - self.last.u_px, observation.v_px - self.last.v_px)
                if jump > self.spec.max_pixel_speed_px_s * dt:
                    return False
        self.last = observation
        return True


class CameraSource:
    """UVC frames -> ball detections, with frame-arrival timestamps."""

    def __init__(self, config: Config):
        self.camera = UvcCamera(config.camera)
        self.detector = ColorBlobDetector(config.vision)
        self.latency_s = max(0.0, config.camera.latency_s)
        self.timeout_s = float(config.safety.source_timeout_s)
        self.camera.open()
        self.last_frame_s = clock.now()

    def read(self) -> list[BallObservation]:
        result = self.camera.read()
        if result is None:
            return []
        time_s, frame = result
        self.last_frame_s = clock.now()
        # The frame was exposed before read() returned; report the estimated
        # exposure time, not the arrival time.
        return self.detector.detect(frame, time_s - self.latency_s)

    @property
    def healthy(self) -> bool:
        return clock.now() - self.last_frame_s <= self.timeout_s

    @property
    def done(self) -> bool:
        return False

    def close(self) -> None:
        self.camera.close()

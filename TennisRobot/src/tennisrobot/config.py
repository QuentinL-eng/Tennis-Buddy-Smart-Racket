"""Configuration for the camera, racket, arm, planner and safety limits.

All physical quantities are SI (metres, seconds, kilograms); orientations are in
degrees because that is the natural unit at the configuration boundary and in the
Epson point format.  Pose vectors are ``[x, y, z, roll, pitch, yaw]``.

Unknown keys are rejected: a typo in a safety limit should stop the program, not
silently fall back to a permissive default.
"""

from __future__ import annotations

import tomllib
from dataclasses import asdict, dataclass, field, fields
from pathlib import Path
from typing import Any

import numpy as np

from .geometry import Transform


class ConfigError(ValueError):
    """Raised for an invalid or misspelled configuration."""


def _section(cls: type, data: Any, name: str) -> Any:
    if data is None:
        data = {}
    if not isinstance(data, dict):
        raise ConfigError(f"[{name}] must be a table")
    allowed = {item.name for item in fields(cls)}
    unknown = sorted(set(data) - allowed)
    if unknown:
        raise ConfigError(f"[{name}] has unknown key(s): {', '.join(unknown)}")
    try:
        return cls(**data)
    except TypeError as exc:
        raise ConfigError(f"[{name}] {exc}") from exc


def _vec3(value: Any, name: str) -> tuple[float, float, float]:
    try:
        array = np.asarray(value, dtype=float).reshape(-1)
    except (TypeError, ValueError) as exc:
        raise ConfigError(f"{name} must be three numbers") from exc
    if array.size != 3:
        raise ConfigError(f"{name} must be three numbers, got {array.size}")
    return float(array[0]), float(array[1]), float(array[2])


def _pose6(value: Any, name: str) -> tuple[float, ...]:
    try:
        array = np.asarray(value, dtype=float).reshape(-1)
    except (TypeError, ValueError) as exc:
        raise ConfigError(f"{name} must be six numbers (x,y,z,roll,pitch,yaw)") from exc
    if array.size != 6:
        raise ConfigError(f"{name} must be six numbers, got {array.size}")
    return tuple(float(x) for x in array)


@dataclass(frozen=True)
class BallSpec:
    mass_kg: float = 0.0575
    radius_m: float = 0.0335
    drag_coefficient: float = 0.507
    air_density_kg_m3: float = 1.225
    lift_slope: float = 0.5
    spin_rad_s: list[float] = field(default_factory=lambda: [0.0, 0.0, 0.0])
    wind_m_s: list[float] = field(default_factory=lambda: [0.0, 0.0, 0.0])


@dataclass(frozen=True)
class CameraSpec:
    kind: str = "simulated"  # "simulated" | "uvc" | "remote"
    device: str = "0"
    # Used only when kind == "remote": the iPhone TennisCamera TCP server.
    remote_host: str = "127.0.0.1"
    remote_port: int = 5000
    width: int = 1280
    height: int = 720
    fps: float = 240.0
    horizontal_fov_deg: float = 55.0
    fx: float | None = None
    fy: float | None = None
    cx: float | None = None
    cy: float | None = None
    distortion: list[float] = field(default_factory=lambda: [0.0, 0.0, 0.0, 0.0])
    # pose wins when both are present; look_at is the more convenient way to
    # point a fixed camera at the strike zone.
    pose: list[float] | None = None
    look_at: list[float] | None = field(default_factory=lambda: [2.0, -1.0, 1.7, 0.0, 2.2, 1.05])
    exposure: float = -1.0  # -1 leaves the driver setting alone
    gain: float = -1.0
    fourcc: str = "MJPG"
    # On the UNO Q's UVC driver, one V4L2 buffer halves the delivered frame rate
    # (30 -> 15 fps) even though the driver reports 30.  Keep at least two.
    buffersize: int = 2
    # Exposure-to-arrival delay.  The capture timestamp is taken after read();
    # subtract the measured delay so observations are not treated as newer than
    # they are.  Measure it with a flashing LED or a falling ball.
    latency_s: float = 0.0

    def transform(self) -> Transform:
        if self.pose is not None:
            return Transform.from_pose(_pose6(self.pose, "camera.pose"))
        if self.look_at is not None:
            values = _pose6(self.look_at, "camera.look_at")
            return Transform.look_at(values[:3], values[3:6])
        raise ConfigError("camera needs either pose or look_at")

    def intrinsics(self) -> tuple[float, float, float, float]:
        if self.width <= 0 or self.height <= 0:
            raise ConfigError("camera.width and camera.height must be positive")
        fx = self.fx
        if fx is None:
            fov = np.radians(self.horizontal_fov_deg)
            if not 0.0 < fov < np.pi:
                raise ConfigError("camera.horizontal_fov_deg must be between 0 and 180")
            fx = (self.width / 2.0) / np.tan(fov / 2.0)
        fy = fx if self.fy is None else self.fy
        cx = self.width / 2.0 if self.cx is None else self.cx
        cy = self.height / 2.0 if self.cy is None else self.cy
        return float(fx), float(fy), float(cx), float(cy)


@dataclass(frozen=True)
class VisionSpec:
    hsv_lower: list[int] = field(default_factory=lambda: [25, 70, 70])
    hsv_upper: list[int] = field(default_factory=lambda: [50, 255, 255])
    min_area_px: float = 40.0
    min_radius_px: float = 3.0
    max_radius_px: float = 80.0
    min_circularity: float = 0.55
    max_candidates: int = 3
    min_confidence: float = 0.25
    max_pixel_speed_px_s: float = 12000.0


@dataclass(frozen=True)
class RacketSpec:
    length_m: float = 0.686
    # The point on the racket that must meet the ball, in the racket frame
    # (origin at the butt cap, +Z up the shaft, +Y out of the strings).
    impact_point_m: list[float] = field(default_factory=lambda: [0.0, 0.0, 0.52])
    # Rigid flange -> butt transform (the physical mount).
    mount_pose: list[float] = field(default_factory=lambda: [0.0, 0.0, 0.0, 0.0, 0.0, 0.0])
    string_half_width_m: float = 0.145
    string_half_height_m: float = 0.175


@dataclass(frozen=True)
class ArmSpec:
    kind: str = "mock"  # "mock" | "epson"
    host: str = "127.0.0.1"
    port: int = 12000
    # Epson base frame in world coordinates (default: base +X faces the court).
    base_pose: list[float] = field(default_factory=lambda: [0.0, 0.0, 0.0, 0.0, 0.0, 90.0])
    max_tcp_speed_m_s: float = 2.8
    max_accel_m_s2: float = 12.0
    command_latency_s: float = 0.03
    timing_jitter_s: float = 0.004
    position_noise_m: float = 0.002
    heartbeat_s: float = 0.25
    response_timeout_s: float = 1.0
    # Boxes are in the arm base frame and are checked for the impact point and
    # for all three flange poses.  They are conservative until the real
    # workspace has been measured.
    impact_box_min: list[float] = field(default_factory=lambda: [0.45, -0.45, 0.55])
    impact_box_max: list[float] = field(default_factory=lambda: [0.78, 0.45, 1.35])
    flange_box_min: list[float] = field(default_factory=lambda: [0.30, -0.55, 0.20])
    flange_box_max: list[float] = field(default_factory=lambda: [0.82, 0.55, 1.25])

    def base_transform(self) -> Transform:
        return Transform.from_pose(_pose6(self.base_pose, "arm.base_pose"))


@dataclass(frozen=True)
class PlannerSpec:
    strike_plane_point_m: list[float] = field(default_factory=lambda: [0.0, 0.58, 0.0])
    strike_plane_normal: list[float] = field(default_factory=lambda: [0.0, 1.0, 0.0])
    swing_speed_m_s: float = 2.4
    pre_swing_distance_m: float = 0.24
    post_swing_distance_m: float = 0.20
    min_swing_speed_m_s: float = 1.2
    min_lead_s: float = 0.28
    max_lead_s: float = 0.40
    decision_margin_s: float = 0.03
    shaft_hint_world: list[float] = field(default_factory=lambda: [0.0, 0.0, 1.0])
    face_horizontal: bool = True


@dataclass(frozen=True)
class SafetySpec:
    require_operator_arm: bool = True
    max_fit_rms_px: float = 2.0
    min_observations: int = 6
    strike_tolerance_m: float = 0.10
    min_ball_speed_m_s: float = 3.0
    max_ball_speed_m_s: float = 45.0
    max_misses_before_fault: int = 3
    source_timeout_s: float = 1.0


@dataclass(frozen=True)
class EstimatorSpec:
    window_observations: int = 48
    min_observations: int = 6
    max_iterations: int = 12
    center_sigma_px: float = 0.7
    radius_sigma_px: float = 1.0
    use_radius: bool = True
    outlier_px: float = 6.0
    max_step_s: float = 0.04  # fit grid; Hermite interpolation keeps it accurate
    intercept_step_s: float = 0.01


@dataclass(frozen=True)
class SimSpec:
    shots: int = 4
    interval_s: float = 2.5
    warmup_s: float = 1.0
    launch_position_m: list[float] = field(default_factory=lambda: [0.0, 6.5, 1.15])
    launch_velocity_m_s: list[float] = field(default_factory=lambda: [0.0, -9.5, 2.9])
    lateral_jitter_m_s: float = 0.35
    speed_jitter_fraction: float = 0.04
    noise_px: float = 0.25
    radius_noise_px: float = 0.4
    outlier_rate: float = 0.01
    seed: int = 7


@dataclass(frozen=True)
class RunSpec:
    record_dir: str = "runs"
    cooldown_s: float = 1.0
    max_runtime_s: float = 0.0
    fit_every_n_frames: int = 12


@dataclass(frozen=True)
class Config:
    ball: BallSpec = field(default_factory=BallSpec)
    camera: CameraSpec = field(default_factory=CameraSpec)
    vision: VisionSpec = field(default_factory=VisionSpec)
    racket: RacketSpec = field(default_factory=RacketSpec)
    arm: ArmSpec = field(default_factory=ArmSpec)
    planner: PlannerSpec = field(default_factory=PlannerSpec)
    safety: SafetySpec = field(default_factory=SafetySpec)
    estimator: EstimatorSpec = field(default_factory=EstimatorSpec)
    sim: SimSpec = field(default_factory=SimSpec)
    run: RunSpec = field(default_factory=RunSpec)

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> "Config":
        if not isinstance(data, dict):
            raise ConfigError("the configuration root must be a table")
        sections = {
            "ball": BallSpec,
            "camera": CameraSpec,
            "vision": VisionSpec,
            "racket": RacketSpec,
            "arm": ArmSpec,
            "planner": PlannerSpec,
            "safety": SafetySpec,
            "estimator": EstimatorSpec,
            "sim": SimSpec,
            "run": RunSpec,
        }
        unknown = sorted(set(data) - set(sections))
        if unknown:
            raise ConfigError(f"unknown configuration section(s): {', '.join(unknown)}")
        config = cls(**{name: _section(section, data.get(name, {}), name) for name, section in sections.items()})
        config.validate()
        return config

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)

    def validate(self) -> None:
        ball = self.ball
        if ball.mass_kg <= 0 or ball.radius_m <= 0:
            raise ConfigError("ball.mass_kg and ball.radius_m must be positive")
        if ball.drag_coefficient < 0:
            raise ConfigError("ball.drag_coefficient must be non-negative")
        if len(ball.spin_rad_s) != 3 or len(ball.wind_m_s) != 3:
            raise ConfigError("ball.spin_rad_s and ball.wind_m_s must have three components")
        _vec3(ball.spin_rad_s, "ball.spin_rad_s")
        _vec3(ball.wind_m_s, "ball.wind_m_s")

        camera = self.camera
        if camera.kind not in {"simulated", "uvc", "remote"}:
            raise ConfigError("camera.kind must be 'simulated', 'uvc' or 'remote'")
        if camera.kind == "remote":
            if not camera.remote_host.strip():
                raise ConfigError("camera.remote_host must not be empty")
            if not 0 < camera.remote_port < 65536:
                raise ConfigError("camera.remote_port must be 1..65535")
        if camera.fps <= 0:
            raise ConfigError("camera.fps must be positive")
        if camera.latency_s < 0:
            raise ConfigError("camera.latency_s must be non-negative")
        camera.intrinsics()
        if camera.pose is not None:
            _pose6(camera.pose, "camera.pose")
        if camera.look_at is not None:
            _pose6(camera.look_at, "camera.look_at")
        if len(camera.distortion) != 4:
            raise ConfigError("camera.distortion must be [k1, k2, p1, p2]")

        vision = self.vision
        if len(vision.hsv_lower) != 3 or len(vision.hsv_upper) != 3:
            raise ConfigError("vision HSV bounds must have three components")
        if not all(0 <= value <= 255 for value in vision.hsv_lower + vision.hsv_upper):
            raise ConfigError("vision HSV bounds must be 0..255")
        if not 0.0 <= vision.min_circularity <= 1.0:
            raise ConfigError("vision.min_circularity must be 0..1")
        if vision.min_radius_px <= 0 or vision.max_radius_px <= vision.min_radius_px:
            raise ConfigError("vision radius bounds are invalid")

        racket = self.racket
        _pose6(racket.mount_pose, "racket.mount_pose")
        impact = np.asarray(_vec3(racket.impact_point_m, "racket.impact_point_m"))
        if np.linalg.norm(impact) > racket.length_m + 0.05:
            raise ConfigError("racket.impact_point_m lies beyond the racket length")
        if racket.length_m <= 0:
            raise ConfigError("racket.length_m must be positive")

        arm = self.arm
        if arm.kind not in {"mock", "epson"}:
            raise ConfigError("arm.kind must be 'mock' or 'epson'")
        if not 0 < arm.port < 65536:
            raise ConfigError("arm.port must be 1..65535")
        _pose6(arm.base_pose, "arm.base_pose")
        if arm.max_tcp_speed_m_s <= 0 or arm.max_accel_m_s2 <= 0:
            raise ConfigError("arm speed and acceleration limits must be positive")
        for low_name, high_name in (("impact_box_min", "impact_box_max"), ("flange_box_min", "flange_box_max")):
            low = np.asarray(_vec3(getattr(arm, low_name), f"arm.{low_name}"))
            high = np.asarray(_vec3(getattr(arm, high_name), f"arm.{high_name}"))
            if np.any(low >= high):
                raise ConfigError(f"arm.{low_name} must be below arm.{high_name} on every axis")
        if arm.heartbeat_s <= 0 or arm.response_timeout_s <= 0:
            raise ConfigError("arm heartbeat and response timeout must be positive")

        planner = self.planner
        _vec3(planner.strike_plane_point_m, "planner.strike_plane_point_m")
        normal = np.asarray(_vec3(planner.strike_plane_normal, "planner.strike_plane_normal"))
        if np.linalg.norm(normal) < 1e-9:
            raise ConfigError("planner.strike_plane_normal must be non-zero")
        hint = np.asarray(_vec3(planner.shaft_hint_world, "planner.shaft_hint_world"))
        if np.linalg.norm(hint) < 1e-9:
            raise ConfigError("planner.shaft_hint_world must be non-zero")
        if planner.swing_speed_m_s <= 0 or planner.min_swing_speed_m_s <= 0:
            raise ConfigError("planner swing speeds must be positive")
        if planner.swing_speed_m_s > arm.max_tcp_speed_m_s:
            raise ConfigError("planner.swing_speed_m_s exceeds arm.max_tcp_speed_m_s")
        if planner.pre_swing_distance_m <= 0 or planner.post_swing_distance_m <= 0:
            raise ConfigError("planner swing distances must be positive")
        if not 0 < planner.min_lead_s < planner.max_lead_s:
            raise ConfigError("planner needs 0 < min_lead_s < max_lead_s")

        safety = self.safety
        if safety.max_fit_rms_px <= 0 or safety.strike_tolerance_m <= 0:
            raise ConfigError("safety limits must be positive")
        if safety.min_ball_speed_m_s >= safety.max_ball_speed_m_s:
            raise ConfigError("safety ball speed range is empty")
        if safety.max_misses_before_fault < 1:
            raise ConfigError("safety.max_misses_before_fault must be at least 1")
        if safety.source_timeout_s <= 0:
            raise ConfigError("safety.source_timeout_s must be positive")

        estimator = self.estimator
        if not 3 <= estimator.min_observations <= estimator.window_observations:
            raise ConfigError("estimator.min_observations must be >= 3 and <= window_observations")
        if estimator.center_sigma_px <= 0 or estimator.radius_sigma_px <= 0:
            raise ConfigError("estimator noise sigmas must be positive")
        if estimator.max_step_s <= 0 or estimator.intercept_step_s <= 0:
            raise ConfigError("estimator time steps must be positive")

        sim = self.sim
        if sim.shots < 0 or sim.interval_s <= 0 or sim.noise_px < 0 or sim.radius_noise_px < 0:
            raise ConfigError("sim values must be non-negative and interval_s positive")
        if not 0.0 <= sim.outlier_rate <= 1.0:
            raise ConfigError("sim.outlier_rate must be 0..1")
        _vec3(sim.launch_position_m, "sim.launch_position_m")
        _vec3(sim.launch_velocity_m_s, "sim.launch_velocity_m_s")

        if self.run.cooldown_s < 0 or self.run.max_runtime_s < 0:
            raise ConfigError("run durations must be non-negative")
        if self.run.fit_every_n_frames < 1:
            raise ConfigError("run.fit_every_n_frames must be at least 1")


def load_config(path: str | Path | None = None) -> Config:
    """Load a TOML file, falling back to the built-in defaults.

    The returned object is always validated, including when no path is given.
    """
    if path is None:
        config = Config()
        config.validate()
        return config
    file = Path(path)
    try:
        text = file.read_text(encoding="utf-8")
    except OSError as exc:
        raise ConfigError(f"cannot read {file}: {exc}") from exc
    try:
        data = tomllib.loads(text)
    except tomllib.TOMLDecodeError as exc:
        raise ConfigError(f"{file}: {exc}") from exc
    return Config.from_dict(data)


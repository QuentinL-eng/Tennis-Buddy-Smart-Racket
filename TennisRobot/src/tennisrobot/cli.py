"""Command line interface.

    python -m tennisrobot simulate          # full loop, simulated camera + mock arm
    python -m tennisrobot run --monitor     # real camera, no strikes
    python -m tennisrobot run --arm         # real camera + controller, strikes enabled
    python -m tennisrobot replay runs/...   # re-fit a recorded run
    python -m tennisrobot feasibility       # timing/camera budget for this config
"""

from __future__ import annotations

import argparse
import dataclasses
import sys
from collections import Counter
from pathlib import Path

import numpy as np

from . import __version__
from .arm import ArmError
from .camera import PinholeCamera
from .config import Config, ConfigError, load_config
from .estimator import FlightEstimator
from .physics import BallProperties, FlightModel
from .pipeline import build_system
from .planner import SwingPlanner
from .racket import Racket
from .recorder import load_events
from .types import BallObservation, BallState, PlanRejection


def _default_config(name: str) -> Path | None:
    candidates = [Path(__file__).resolve().parents[2] / "config" / name, Path("config") / name]
    for candidate in candidates:
        if candidate.exists():
            return candidate
    return None


def _load(args: argparse.Namespace, name: str) -> Config:
    path = Path(args.config) if args.config else _default_config(name)
    return load_config(path)


def _flight(config: Config, max_step: float = 0.002) -> FlightModel:
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
        wind_m_s=np.asarray(ball.wind_m_s, dtype=float),
        max_step_s=max_step,
    )


def _simulate(args: argparse.Namespace) -> int:
    config = _load(args, "default.toml")
    sim = config.sim
    if args.shots is not None:
        sim = dataclasses.replace(sim, shots=args.shots)
    if args.seed is not None:
        sim = dataclasses.replace(sim, seed=args.seed)
    config = dataclasses.replace(config, sim=sim)
    config.validate()

    system = build_system(
        config,
        seed=args.seed,
        monitor=False,
        record=not args.no_record,
        force_mock_arm=True,
        verbose=not args.quiet,
    )
    print(
        f"TennisRobot simulation: {config.sim.shots} shots, "
        f"{config.camera.width}x{config.camera.height} @ {config.camera.fps:.0f} fps, "
        f"fit every {config.run.fit_every_n_frames} frames, "
        f"hit tolerance {config.safety.strike_tolerance_m * 100:.0f} cm"
    )
    print("Camera and arm are simulated; no hardware is touched.\n")
    try:
        summary = system.run()
    finally:
        system.close()
    print()
    print(summary.report())
    if system.pipeline.recorder is not None:
        print(f"recording: {system.pipeline.recorder.path}")
    return 0 if summary.fault == "" else 1


def _run(args: argparse.Namespace) -> int:
    config = _load(args, "uno_q.toml")
    if args.duration is not None:
        config = dataclasses.replace(config, run=dataclasses.replace(config.run, max_runtime_s=args.duration))
        config.validate()
    monitor = not args.arm
    mode = "MONITOR (no strike commands)" if monitor else "ARMED (strike commands enabled)"
    print(f"TennisRobot: {mode}")
    if config.camera.kind == "remote":
        camera_desc = f"remote {config.camera.remote_host}:{config.camera.remote_port}"
    else:
        camera_desc = f"{config.camera.kind} {config.camera.device}"
    print(
        f"camera={camera_desc} {config.camera.width}x{config.camera.height} "
        f"@ {config.camera.fps:.0f} fps   arm={config.arm.kind} {config.arm.host}:{config.arm.port}"
    )
    print(f"fit every {config.run.fit_every_n_frames} frames   strike tolerance {config.safety.strike_tolerance_m * 100:.0f} cm")
    if not monitor:
        print("\n!! Verify the physical E-stop, guarding and the restricted work envelope before continuing.")
        if config.arm.kind == "mock":
            print("!! Mock arm: strikes are simulated. No hardware will move.\n")
        else:
            print("!! The software watchdog is not a safety-rated stop.\n")

    system = build_system(
        config,
        monitor=monitor,
        record=not args.no_record,
        force_mock_arm=False,
        verbose=not args.quiet,
    )
    try:
        summary = system.run()
    finally:
        system.close()
    print()
    print(summary.report())
    if system.pipeline.recorder is not None:
        print(f"recording: {system.pipeline.recorder.path}")
    return 0 if summary.fault == "" else 1


def _replay(args: argparse.Namespace) -> int:
    config_dict, events = load_events(args.path)
    config = Config.from_dict(config_dict)
    camera = PinholeCamera.from_spec(config.camera)
    flight = _flight(config, max_step=config.estimator.max_step_s)
    estimator = FlightEstimator(camera, flight, config.estimator)
    planner = SwingPlanner(Racket(config.racket), config.arm, config.planner)
    plane_point = np.asarray(config.planner.strike_plane_point_m, dtype=float)
    plane_normal = np.asarray(config.planner.strike_plane_normal, dtype=float)

    observations = [
        BallObservation(
            time_s=record["t"],
            u_px=record["u"],
            v_px=record["v"],
            radius_px=record.get("r"),
            confidence=record.get("confidence", 1.0),
        )
        for record in events
        if record.get("kind") == "observation"
    ]
    if not observations:
        print("recording has no observations")
        return 1

    buffer: list[BallObservation] = []
    fits = 0
    rms_values: list[float] = []
    intercepts = 0
    plans = 0
    rejections: Counter[str] = Counter()
    previous_time: float | None = None
    for index, observation in enumerate(observations):
        if previous_time is not None and observation.time_s - previous_time > 0.4:
            buffer.clear()
        previous_time = observation.time_s
        buffer.append(observation)
        buffer = [item for item in buffer if item.time_s >= observation.time_s - 0.6]
        if index % config.run.fit_every_n_frames != 0:
            continue
        fit = estimator.fit(buffer)
        if fit is None:
            continue
        fits += 1
        rms_values.append(fit.rms_px)
        intercept = estimator.predict_intercept(
            fit, plane_point, plane_normal, observation.time_s, max(1.0, config.planner.max_lead_s + 0.65)
        )
        if intercept is None:
            continue
        intercepts += 1
        plan = planner.plan(intercept, observation.time_s)
        if isinstance(plan, PlanRejection):
            rejections[plan.reason.split("(")[0].strip()] += 1
        else:
            plans += 1

    print(f"replay: {args.path}")
    print(f"  observations: {len(observations)}  fits: {fits}  intercepts: {intercepts}  feasible plans: {plans}")
    if rms_values:
        print(f"  fit residual: median {np.median(rms_values):.2f} px  max {max(rms_values):.2f} px")
    if rejections:
        print("  plan rejections: " + ", ".join(f"{reason} x{count}" for reason, count in rejections.most_common()))
    print("  (replay stops at planning; it does not command an arm)")
    return 0


def _feasibility(args: argparse.Namespace) -> int:
    config = _load(args, "default.toml")
    camera = PinholeCamera.from_spec(config.camera)
    frame_dt = 1.0 / config.camera.fps
    flight = _flight(config)
    plane_point = np.asarray(config.planner.strike_plane_point_m, dtype=float)
    normal = np.asarray(config.planner.strike_plane_normal, dtype=float)
    normal = normal / np.linalg.norm(normal)

    print("Camera")
    print(f"  {config.camera.width}x{config.camera.height} @ {config.camera.fps:.0f} fps "
          f"({frame_dt * 1000:.2f} ms/frame), fx={camera.fx:.0f} px")
    print("  ball travel per frame: " + "   ".join(
        f"{speed:.0f} m/s -> {speed * frame_dt * 100:.1f} cm" for speed in (10, 15, 20, 30)
    ))
    print(f"  ~5 cm/frame ceiling at this rate: {0.05 / frame_dt:.1f} m/s")
    print("  fps for 5 cm/frame at 10/20/30 m/s: 200 / 400 / 600")
    print()

    launch = BallState(0.0, np.asarray(config.sim.launch_position_m, dtype=float),
                       np.asarray(config.sim.launch_velocity_m_s, dtype=float))
    state = launch
    crossing = None
    for _ in range(3000):
        next_state = flight.step(state, 0.001)
        if np.dot(state.position_m - plane_point, normal) > 0 >= np.dot(next_state.position_m - plane_point, normal):
            crossing = next_state
            break
        state = next_state
    print("Nominal feed (from sim launch, no jitter)")
    if crossing is None:
        print("  ball never crosses the strike plane")
        strike_speed = 0.0
    else:
        strike_speed = float(np.linalg.norm(crossing.velocity_m_s))
        print(f"  flight to strike plane: {crossing.time_s * 1000:.0f} ms, speed {strike_speed:.1f} m/s, "
              f"height {crossing.position_m[2]:.2f} m, lateral {crossing.position_m[0]:+.2f} m")
        print(f"  ball travel in 1 ms: {strike_speed:.0f} mm; in one camera frame: {strike_speed * frame_dt * 100:.1f} cm")
    print()

    acceleration = config.arm.max_accel_m_s2
    speed = min(
        config.planner.swing_speed_m_s,
        float(np.sqrt(2 * acceleration * config.planner.pre_swing_distance_m)),
        float(np.sqrt(2 * acceleration * config.planner.post_swing_distance_m)),
    )
    accel_distance = speed * speed / (2 * acceleration)
    required_lead = speed / acceleration + max(
        0.0, config.planner.pre_swing_distance_m - accel_distance
    ) / speed
    deadline = max(
        config.planner.min_lead_s,
        required_lead + config.arm.command_latency_s + config.planner.decision_margin_s,
    )
    print("Swing")
    print(f"  effective racket speed: {speed:.2f} m/s (limited by the {config.planner.pre_swing_distance_m:.2f} m "
          f"pre / {config.planner.post_swing_distance_m:.2f} m post runway)")
    print(f"  required lead: {required_lead * 1000:.0f} ms   decision deadline: {deadline * 1000:.0f} ms   "
          f"allowed window: {config.planner.min_lead_s * 1000:.0f}-{config.planner.max_lead_s * 1000:.0f} ms")
    if deadline > config.planner.max_lead_s:
        print("  WARNING: the planner can never meet its own deadline inside max_lead_s.")
    if strike_speed > 0:
        timing_tolerance = config.safety.strike_tolerance_m / strike_speed * 1000
        jitter_miss = config.arm.timing_jitter_s * strike_speed * 1000
        print(f"  hit tolerance {config.safety.strike_tolerance_m * 100:.0f} cm -> ~{timing_tolerance:.1f} ms "
              f"of timing budget at {strike_speed:.1f} m/s")
        print(f"  configured timing jitter {config.arm.timing_jitter_s * 1000:.1f} ms -> "
              f"{jitter_miss:.0f} mm of ball travel before control lag")
    print()

    print("Arm envelope (base frame)")
    print(f"  impact box: {config.arm.impact_box_min} .. {config.arm.impact_box_max}")
    print(f"  flange box: {config.arm.flange_box_min} .. {config.arm.flange_box_max}")
    print()

    print("Read this before trusting a number")
    print("  - A single camera has weak depth.  Apparent radius plus the physics fit are the only depth cues.")
    print("  - A rolling-shutter 30 fps webcam cannot see a tennis ball; use a global-shutter camera at >=240 fps.")
    print("  - The model assumes constant spin; a real spin estimate needs more cameras or a radar.")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="tennisrobot", description=__doc__.splitlines()[0])
    parser.add_argument("--version", action="version", version=f"tennisrobot {__version__}")
    subparsers = parser.add_subparsers(dest="command", required=True)

    simulate = subparsers.add_parser("simulate", help="run the full pipeline against the simulator")
    simulate.add_argument("--config", help="TOML configuration (default: config/default.toml)")
    simulate.add_argument("--shots", type=int, help="override the number of simulated balls")
    simulate.add_argument("--seed", type=int, help="override the simulation seed")
    simulate.add_argument("--no-record", action="store_true", help="do not write a JSONL run")
    simulate.add_argument("--quiet", action="store_true", help="only print the final summary")
    simulate.set_defaults(func=_simulate)

    run = subparsers.add_parser("run", help="run against the camera (and optionally the arm)")
    run.add_argument("--config", help="TOML configuration (default: config/uno_q.toml)")
    run.add_argument("--arm", action="store_true", help="enable strike commands (default is monitor-only)")
    run.add_argument("--duration", type=float, help="stop after this many seconds")
    run.add_argument("--no-record", action="store_true", help="do not write a JSONL run")
    run.add_argument("--quiet", action="store_true", help="only print strikes and the final summary")
    run.set_defaults(func=_run)

    replay = subparsers.add_parser("replay", help="re-fit a recorded run")
    replay.add_argument("path", help="a JSONL recording from runs/")
    replay.set_defaults(func=_replay)

    feasibility = subparsers.add_parser("feasibility", help="print the camera/timing budget for a config")
    feasibility.add_argument("--config", help="TOML configuration (default: config/default.toml)")
    feasibility.set_defaults(func=_feasibility)
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except (ConfigError, ArmError, RuntimeError, ValueError) as exc:
        parser.exit(2, f"error: {exc}\n")
    except KeyboardInterrupt:
        parser.exit(130, "interrupted\n")


if __name__ == "__main__":
    sys.exit(main())

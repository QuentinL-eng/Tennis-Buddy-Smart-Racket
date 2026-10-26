"""Run synthetic iPhone observations through the PC planner and mock arm only.

From TennisRobot: python tools/demo_iphone_ball.py
No camera, Epson connection, controller settings or robot motion are used.
"""
from __future__ import annotations
import argparse
import dataclasses
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))
from tennisrobot.config import load_config
from tennisrobot.fake_iphone import FakeIphoneServer
from tennisrobot.pipeline import build_system
from tennisrobot.recorder import load_events


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--duration", type=float, default=8.0)
    parser.add_argument("--shots", type=int, default=3)
    parser.add_argument("--seed", type=int, default=7)
    args = parser.parse_args()
    if args.duration <= 0 or args.shots < 1:
        parser.error("duration must be positive and shots must be at least one")
    config = load_config(ROOT / "config" / "iphone.toml")
    config = dataclasses.replace(
        config,
        camera=dataclasses.replace(config.camera, kind="remote", remote_host="127.0.0.1"),
        arm=dataclasses.replace(config.arm, kind="mock"),
        sim=dataclasses.replace(config.sim, shots=args.shots, seed=args.seed),
        run=dataclasses.replace(config.run, max_runtime_s=args.duration,
                                record_dir=str(ROOT / "runs")),
    )
    server = FakeIphoneServer(config, host="127.0.0.1", port=0,
                              duration_s=args.duration + 2, seed=args.seed)
    config = dataclasses.replace(config, camera=dataclasses.replace(
        config.camera, remote_port=server.port))
    config.validate()
    server.start()
    system = None
    try:
        system = build_system(config, force_mock_arm=True, record=True, verbose=False)
        summary = system.run()
        packets = system.source.packets_received
        observations = system.source.observations_received
        gaps = system.source.sequence_gaps
        recording = system.pipeline.recorder.path
    finally:
        if system is not None:
            system.close()
        server.close()
    _, events = load_events(recording)
    sent = [e for e in events if e["kind"] == "strike_sent"]
    plans = [e for e in events if e["kind"] == "plan"]
    result = {
        "test": "synthetic iPhone observations -> PC estimator/planner -> mock arm",
        "real_robot_connected": False,
        "seed": args.seed,
        "requested_balls": args.shots,
        "nominal_launch_position_m": config.sim.launch_position_m,
        "nominal_launch_velocity_m_s": config.sim.launch_velocity_m_s,
        "camera_fps": config.camera.fps,
        "frame_size": [config.camera.width, config.camera.height],
        "pixel_noise_sigma": config.sim.noise_px,
        "radius_noise_sigma_px": config.sim.radius_noise_px,
        "outlier_rate": config.sim.outlier_rate,
        "packets_received": packets,
        "observations_received": observations,
        "sequence_gaps": gaps,
        "summary": dataclasses.asdict(summary),
        "submitted_plans": [max((p for p in plans if p["t"] <= e["t"]),
                                 key=lambda p: p["t"]) for e in sent],
        "recording": str(recording),
        "limits": [
            "Synthetic physics, noise and camera calibration; not a measured iPhone flight.",
            "Mock completions do not establish hits, Epson reach, collision clearance or timing.",
            "Planner racket mount and base calibration are placeholders, not the RC+ mount.",
            "Phone 3D telemetry is accepted but not used by the PC pixel estimator.",
        ],
    }
    output = recording.with_suffix(".summary.json")
    output.write_text(json.dumps(result, indent=2), encoding="utf-8")
    print(summary.report())
    print(f"Packets: {packets}; observations: {observations}; sequence gaps: {gaps}")
    print(f"Recording: {recording}")
    print(f"Summary: {output}")
    return 0 if not summary.fault and summary.strikes > 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())

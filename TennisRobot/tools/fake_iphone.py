#!/usr/bin/env python3
"""Simulate the iPhone TennisCamera TCP server on the PC.

    python tools/fake_iphone.py --config config/iphone.toml --duration 10
    python -m tennisrobot run --config config/iphone.toml --arm --duration 6

The fake server uses the same 40-byte packet format as the real app, so it tests
the remote source, estimator, planner, safety monitor and mock arm end to end.
It opens no camera and commands no arm.
"""

from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from tennisrobot.config import load_config  # noqa: E402
from tennisrobot.fake_iphone import FakeIphoneServer  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--config", default="config/iphone.toml")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=5000)
    parser.add_argument("--shots", type=int, help="override sim.shots")
    parser.add_argument("--warmup", type=float, help="override sim.warmup_s")
    parser.add_argument("--interval", type=float, help="override sim.interval_s")
    parser.add_argument("--duration", type=float, default=10.0, help="streaming time after the client connects")
    parser.add_argument("--seed", type=int, help="override the simulation seed")
    args = parser.parse_args()

    config = load_config(args.config)
    server = FakeIphoneServer(
        config,
        host=args.host,
        port=args.port,
        shots=args.shots,
        warmup_s=args.warmup,
        interval_s=args.interval,
        duration_s=args.duration,
        seed=args.seed,
        verbose=True,
    )
    print(f"fake iPhone listening on {server.host}:{server.port}")
    print(f"start the PC pipeline with: python -m tennisrobot run --config {args.config} --arm")
    server.start()
    try:
        while server.running:
            time.sleep(0.2)
    except KeyboardInterrupt:
        print("\nstopping fake iPhone")
    finally:
        server.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

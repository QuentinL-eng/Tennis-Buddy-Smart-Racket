#!/usr/bin/env python3
"""Check the live iPhone TennisCamera observation stream from this PC.

    iproxy 5000 5000
    python tools/iphone_check.py --duration 10

    # No iPhone app yet? Exercise the receiver against the fake iPhone:
    python tools/iphone_check.py --fake --duration 10

The check connects to the same TCP stream the pipeline uses, reports packet and
observation rates, sequence gaps, the minimum capture-to-arrival delay and the
phone's own status packet.  It does not run the estimator or command an arm.
"""

from __future__ import annotations

import argparse
import dataclasses
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from tennisrobot import clock  # noqa: E402
from tennisrobot.config import load_config  # noqa: E402
from tennisrobot.fake_iphone import FakeIphoneServer  # noqa: E402
from tennisrobot.remote import RemoteObservationSource, RemoteProtocolError  # noqa: E402

_THERMAL = ("nominal", "fair", "serious", "critical")


def _thermal_name(value: float) -> str:
    index = int(round(value))
    if 0 <= index < len(_THERMAL):
        return _THERMAL[index]
    return f"state {index}"


def _fmt_offset(ns: int | None) -> str:
    return "-" if ns is None else f"{ns / 1e6:6.1f} ms"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--config", default="config/iphone.toml")
    parser.add_argument("--host", help="override camera.remote_host")
    parser.add_argument("--port", type=int, help="override camera.remote_port")
    parser.add_argument("--duration", type=float, default=10.0, help="seconds to watch")
    parser.add_argument("--connect-timeout", type=float, default=5.0)
    parser.add_argument(
        "--fake",
        action="store_true",
        help="start the fake iPhone server in this process (no phone or iproxy)",
    )
    args = parser.parse_args()

    if args.duration <= 0:
        print("error: --duration must be positive")
        return 2

    config = load_config(args.config)
    if config.camera.kind != "remote":
        print(f"error: {args.config} has camera.kind = {config.camera.kind!r}; use a remote config")
        return 2

    camera = config.camera
    if args.host:
        camera = dataclasses.replace(camera, remote_host=args.host)
    if args.port is not None:
        camera = dataclasses.replace(camera, remote_port=args.port)
    config = dataclasses.replace(config, camera=camera)

    server: FakeIphoneServer | None = None
    if args.fake:
        server = FakeIphoneServer(
            config,
            host="127.0.0.1",
            port=0,
            duration_s=max(2.0, args.duration + 3.0),
            verbose=False,
        )
        server.start()
        camera = dataclasses.replace(camera, remote_host="127.0.0.1", remote_port=server.port)
        config = dataclasses.replace(config, camera=camera)
        print(f"fake iPhone: 127.0.0.1:{server.port}  (simulated packets, no hardware)")

    print(
        f"target: {camera.remote_host}:{camera.remote_port}  "
        f"frame {camera.width}x{camera.height}  expected {camera.fps:.0f} fps"
    )
    print("waiting for packets; Ctrl+C to stop\n")

    source: RemoteObservationSource | None = None
    healthy_at_end = False
    started = clock.now()
    try:
        source = RemoteObservationSource(config, connect_timeout_s=args.connect_timeout)
        last_check = started
        last_packets = 0
        last_observations = 0
        last_gaps = 0
        while True:
            now = clock.now()
            if now - started >= args.duration:
                break
            source.read()
            now = clock.now()
            if now - last_check >= 1.0:
                elapsed = max(1e-6, now - last_check)
                packets = source.packets_received - last_packets
                observations = source.observations_received - last_observations
                gaps = source.sequence_gaps - last_gaps
                status = source.last_status
                if status is None:
                    phone = "no status yet"
                else:
                    phone = (
                        f"{status.u:5.1f} fps"
                        f"  det {status.v:4.1f} ms"
                        f"  drop {int(round(status.radius))}"
                        f"  thermal {_thermal_name(status.confidence)}"
                    )
                health = "ok" if source.healthy else "STALE"
                print(
                    f"t={now - started:5.1f}s  "
                    f"packets {packets / elapsed:6.1f}/s  "
                    f"obs {observations / elapsed:6.1f}/s  "
                    f"gaps {gaps:2d}  "
                    f"clock offset {_fmt_offset(source.offset_ns)}  "
                    f"phone {phone}  source {health}",
                    flush=True,
                )
                last_check = now
                last_packets = source.packets_received
                last_observations = source.observations_received
                last_gaps = source.sequence_gaps
            if not source.connected:
                time.sleep(0.05)
    except KeyboardInterrupt:
        print("\nstopped")
    except RemoteProtocolError as exc:
        print(f"protocol error: {exc}")
        return 2
    except RuntimeError as exc:
        print(f"error: {exc}")
        return 2
    finally:
        if source is not None:
            healthy_at_end = source.healthy
            source.close()
        if server is not None:
            server.close()

    if source is None:
        return 2
    print()
    print(
        f"received {source.packets_received} packets "
        f"({source.observations_received} observations, "
        f"{source.sequence_gaps} sequence gaps)"
    )
    print(f"estimated clock offset: {_fmt_offset(source.offset_ns)}")
    status = source.last_status
    if status is not None:
        print(
            f"phone status: {status.u:.1f} fps, detector median {status.v:.1f} ms, "
            f"dropped {int(round(status.radius))}, thermal {_thermal_name(status.confidence)}"
        )
    if source.packets_received == 0:
        print("FAIL: connected but no packets arrived. Is the app running and capturing?")
        return 1
    if not healthy_at_end:
        print("FAIL: the stream was stale at the end; expected a status packet every ~1 s.")
        return 1
    if status is not None and status.u < 100.0:
        print(f"WARN: the phone reports {status.u:.0f} fps; 240 fps is the target for a real ball.")
    if source.sequence_gaps:
        print(f"WARN: {source.sequence_gaps} sequence gap(s); TCP lost or the phone dropped packets.")
    print("OK: the PC receiver is receiving the iPhone stream.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

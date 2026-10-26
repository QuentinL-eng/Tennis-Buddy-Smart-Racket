#!/usr/bin/env python3
"""A stand-in for the RC700-E SPEL+ strike server.

    python3 tools/fake_arm.py --port 12000

It speaks the fixed-width ASCII protocol in docs/PROTOCOL.md and prints each
strike it receives.  Use it to exercise ``EpsonArm`` from the UNO Q before the
real controller is available:

    # config/uno_q.toml: arm.host = "<laptop or server address>"
    python -m tennisrobot run --config config/uno_q.toml --arm

This is a protocol test double, not a safety device and not a motion simulator.
"""

from __future__ import annotations

import argparse
import socketserver
import time


class Handler(socketserver.StreamRequestHandler):
    def handle(self) -> None:
        for raw in self.rfile:
            text = raw.decode("ascii", errors="replace").strip()
            if not text:
                continue
            parts = text.split(",")
            try:
                opcode = int(parts[0])
                sequence = int(parts[1])
            except (IndexError, ValueError):
                continue

            if opcode == 3:  # ping
                if getattr(self.server, "verbose", False):
                    print(f"PING {sequence}", flush=True)
                self._reply(f"PONG,{sequence}")
            elif opcode == 2:  # abort
                print(f"ABORT {sequence}", flush=True)
                self._reply(f"ACK,{sequence}")
            elif opcode == 1:  # strike
                if len(parts) != 22:
                    print(f"STRIKE {sequence}: wrong field count ({len(parts)})")
                    self._reply(f"ERR,{sequence},1")
                    continue
                values = [float(item) for item in parts[2:]]
                pre = values[0:6]
                strike = values[6:12]
                post = values[12:18]
                speed = values[18]
                lead_ms = values[19]
                print(
                    f"STRIKE {sequence}: pre=({pre[0]:.0f},{pre[1]:.0f},{pre[2]:.0f}) "
                    f"strike=({strike[0]:.0f},{strike[1]:.0f},{strike[2]:.0f}) "
                    f"post=({post[0]:.0f},{post[1]:.0f},{post[2]:.0f}) "
                    f"speed={speed:.0f} mm/s lead={lead_ms:.0f} ms",
                    flush=True,
                )
                self._reply(f"ACK,{sequence}")
                time.sleep(float(getattr(self.server, "delay_s", 0.3)))
                print(f"DONE {sequence}", flush=True)
                self._reply(f"DONE,{sequence}")
            else:
                self._reply(f"ERR,{sequence},3")

    def _reply(self, line: str) -> None:
        self.wfile.write((line + "\n").encode("ascii"))
        self.wfile.flush()


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=12000)
    parser.add_argument("--delay", type=float, default=0.3, help="simulated motion time before DONE")
    parser.add_argument("--verbose", action="store_true", help="print pings too")
    args = parser.parse_args()

    with Server((args.host, args.port), Handler) as server:
        server.delay_s = args.delay
        server.verbose = args.verbose
        print(f"fake RC700-E listening on {args.host}:{args.port} (Ctrl+C to stop)")
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            print("\nstopped")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

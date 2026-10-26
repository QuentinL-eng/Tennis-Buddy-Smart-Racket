import dataclasses
import socket
import threading
import time

import numpy as np
import pytest

from tennisrobot import clock
from tennisrobot.arm import ArmError, EpsonArm, MockArm
from tennisrobot.planner import SwingPlanner
from tennisrobot.racket import Racket
from tennisrobot.types import Intercept, PlanRejection


def _make_plan(config, now: float, lead: float = 0.38):
    intercept = Intercept(
        now + lead,
        np.array([0.1, 0.58, 0.9]),
        np.array([0.2, -9.0, -3.5]),
    )
    plan = SwingPlanner(Racket(config.racket), config.arm, config.planner).plan(intercept, now)
    assert not isinstance(plan, PlanRejection)
    return plan


def test_mock_arm_reports_an_impact_near_the_plan(config):
    arm = MockArm(config.arm)
    arm.connect()
    plan = _make_plan(config, 10.0)
    sequence = arm.strike(plan, 10.0)
    assert arm.busy
    assert arm.service(10.0) == []

    events = arm.service(plan.strike_time_s + 0.2)
    assert len(events) == 1
    event = events[0]
    assert event.kind == "strike_done"
    assert event.sequence == sequence
    assert event.actual_impact_m is not None
    assert np.linalg.norm(event.actual_impact_m - plan.impact_point_m) < 0.05
    assert abs(event.actual_strike_time_s - plan.strike_time_s) < 0.05
    assert arm.status == "ready"


def test_mock_arm_refuses_when_read_only(config):
    arm = MockArm(config.arm, read_only=True)
    plan = _make_plan(config, 10.0)
    with pytest.raises(ArmError):
        arm.strike(plan, 10.0)


class FakeController(threading.Thread):
    def __init__(self):
        super().__init__(daemon=True)
        self.listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.listener.bind(("127.0.0.1", 0))
        self.listener.listen(1)
        self.port = self.listener.getsockname()[1]

    def run(self):
        try:
            connection, _ = self.listener.accept()
        except OSError:
            return
        reader = connection.makefile("rb")
        try:
            for raw in reader:
                text = raw.decode("ascii").strip()
                if not text:
                    continue
                parts = text.split(",")
                if parts[0] == "3":
                    connection.sendall(f"PONG,{parts[1]}\n".encode())
                elif parts[0] == "1":
                    connection.sendall(f"ACK,{parts[1]}\nDONE,{parts[1]}\n".encode())
                elif parts[0] == "2":
                    connection.sendall(f"ACK,{parts[1]}\n".encode())
        finally:
            reader.close()
            connection.close()

    def stop(self):
        try:
            self.listener.close()
        except OSError:
            pass


def test_epson_client_handshake_and_strike(config):
    server = FakeController()
    server.start()
    spec = dataclasses.replace(
        config.arm, host="127.0.0.1", port=server.port, heartbeat_s=0.05, response_timeout_s=2.0
    )
    arm = EpsonArm(spec)
    try:
        arm.connect()
        deadline = clock.now() + 3.0
        while arm.rtt_s == 0.0 and clock.now() < deadline:
            arm.service(clock.now())
            time.sleep(0.01)
        assert arm.rtt_s > 0.0, "no PONG received"

        plan = _make_plan(config, clock.now())
        sequence = arm.strike(plan, clock.now())
        events = []
        deadline = clock.now() + 3.0
        while not events and clock.now() < deadline:
            events.extend(arm.service(clock.now()))
            time.sleep(0.005)
        assert any(event.kind == "strike_done" for event in events), events
        assert events[0].sequence == sequence
        assert events[0].actual_impact_m is None
        assert arm.status == "ready"
    finally:
        arm.close()
        server.stop()


def test_epson_client_refuses_in_read_only_mode(config):
    arm = EpsonArm(config.arm, read_only=True)
    plan = _make_plan(config, 10.0)
    with pytest.raises(ArmError):
        arm.strike(plan, 10.0)

import dataclasses
import socket
import threading
import time

import pytest

from tennisrobot.config import Config
from tennisrobot.fake_iphone import FakeIphoneServer
from tennisrobot.pipeline import build_system
from tennisrobot.remote import (
    KIND_OBSERVATION,
    KIND_STATUS,
    PACKET_SIZE,
    RemoteObservationSource,
    RemoteProtocolError,
    decode_packet,
    encode_observation,
    encode_status,
)


def _remote_config(port: int) -> Config:
    base = Config()
    camera = dataclasses.replace(
        base.camera,
        kind="remote",
        remote_host="127.0.0.1",
        remote_port=port,
        width=1920,
        height=1080,
        fps=240.0,
    )
    return dataclasses.replace(base, camera=camera)


def _serve_once(packets: list[bytes], *, close_after: bool = True):
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", 0))
    listener.listen(1)
    port = int(listener.getsockname()[1])

    def serve() -> None:
        try:
            client, _ = listener.accept()
            try:
                for packet in packets:
                    client.sendall(packet)
                if not close_after:
                    time.sleep(1.0)
            finally:
                client.close()
        except OSError:
            pass
        finally:
            listener.close()

    thread = threading.Thread(target=serve, daemon=True)
    thread.start()
    return port, thread


def test_observation_packet_roundtrip():
    payload = encode_observation(7, 123_456_789, 640.5, 360.25, 12.5, 0.9, 1920, 1080)
    assert len(payload) == PACKET_SIZE == 40
    packet = decode_packet(payload)
    assert packet.kind == KIND_OBSERVATION
    assert packet.sequence == 7
    assert packet.t_capture_ns == 123_456_789
    assert packet.u == pytest.approx(640.5)
    assert packet.v == pytest.approx(360.25)
    assert packet.radius == pytest.approx(12.5)
    assert packet.confidence == pytest.approx(0.9)
    assert (packet.width, packet.height) == (1920, 1080)


def test_status_packet_roundtrip():
    payload = encode_status(3, 99, 240.0, 0.8, 0.0, 0.0, 1920, 1080)
    packet = decode_packet(payload)
    assert packet.kind == KIND_STATUS
    assert packet.u == pytest.approx(240.0)
    assert packet.v == pytest.approx(0.8)


def test_bad_packet_magic_and_length_are_rejected():
    payload = bytearray(encode_observation(1, 2, 3.0, 4.0, 5.0, 0.9, 1920, 1080))
    payload[0] ^= 0xFF
    with pytest.raises(RemoteProtocolError):
        decode_packet(bytes(payload))
    with pytest.raises(RemoteProtocolError):
        decode_packet(b"\0" * (PACKET_SIZE - 1))


def test_remote_source_maps_capture_time_and_frame_size():
    clock_value = [100.0]
    now = 100.0
    capture_ns = int(99.99 * 1_000_000_000)
    port, thread = _serve_once([encode_observation(1, capture_ns, 640.0, 360.0, 12.0, 0.9, 1920, 1080)])
    source = RemoteObservationSource(
        _remote_config(port),
        clock=lambda: clock_value[0],
        connect_timeout_s=2.0,
    )
    try:
        observations = source.read()
        assert len(observations) == 1
        observation = observations[0]
        assert observation.time_s == pytest.approx(now, abs=1e-6)
        assert observation.u_px == pytest.approx(640.0)
        assert observation.v_px == pytest.approx(360.0)
        assert observation.radius_px == pytest.approx(12.0)
        assert observation.confidence == pytest.approx(0.9)
        assert source.healthy
    finally:
        source.close()
        thread.join(timeout=1.0)


def test_remote_latency_is_subtracted_from_the_mapped_capture_time():
    clock_value = [100.0]
    port, thread = _serve_once([encode_observation(1, int(99.9e9), 640.0, 360.0, 12.0, 0.9, 1920, 1080)])
    config = _remote_config(port)
    config = dataclasses.replace(
        config, camera=dataclasses.replace(config.camera, latency_s=0.02)
    )
    source = RemoteObservationSource(
        config,
        clock=lambda: clock_value[0],
        connect_timeout_s=2.0,
    )
    try:
        observations = source.read()
        assert observations[0].time_s == pytest.approx(99.98, abs=1e-6)
    finally:
        source.close()
        thread.join(timeout=1.0)


def test_status_updates_health_without_producing_an_observation():
    clock_value = [100.0]
    port, thread = _serve_once([encode_status(1, int(99.9e9), 240.0, 0.8, 0.0, 0.0, 1920, 1080)])
    source = RemoteObservationSource(
        _remote_config(port),
        clock=lambda: clock_value[0],
        connect_timeout_s=2.0,
    )
    try:
        assert source.read() == []
        assert source.last_status is not None
        assert source.last_status.kind == KIND_STATUS
        clock_value[0] += 2.0
        assert not source.healthy
    finally:
        source.close()
        thread.join(timeout=1.0)


def test_frame_size_mismatch_is_rejected():
    port, thread = _serve_once([encode_observation(1, int(99.9e9), 640.0, 360.0, 12.0, 0.9, 1280, 720)])
    source = RemoteObservationSource(_remote_config(port), connect_timeout_s=2.0)
    try:
        with pytest.raises(RemoteProtocolError):
            source.read()
    finally:
        source.close()
        thread.join(timeout=1.0)


def test_disconnect_marks_source_unhealthy():
    port, thread = _serve_once([])
    source = RemoteObservationSource(_remote_config(port), connect_timeout_s=2.0)
    try:
        assert source.read() == []
        assert not source.connected
        assert not source.healthy
    finally:
        source.close()
        thread.join(timeout=1.0)


def test_connect_retries_then_reports_an_unreachable_stream():
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.bind(("127.0.0.1", 0))
    port = int(listener.getsockname()[1])
    listener.close()
    with pytest.raises(RuntimeError, match="cannot connect"):
        RemoteObservationSource(_remote_config(port), connect_timeout_s=0.2)


def test_zero_capture_timestamp_does_not_poison_the_clock_offset():
    clock_value = [100.0]
    packets = [
        encode_status(1, 0, 240.0, 0.8, 0.0, 0.0, 0, 0),
        encode_observation(2, int(99.9 * 1_000_000_000), 640.0, 360.0, 12.0, 0.9, 1920, 1080),
    ]
    port, thread = _serve_once(packets)
    source = RemoteObservationSource(
        _remote_config(port),
        clock=lambda: clock_value[0],
        connect_timeout_s=2.0,
    )
    try:
        assert source.read() == []
        observations = source.read()
        assert len(observations) == 1
        assert observations[0].time_s == pytest.approx(100.0, abs=1e-6)
        assert source.offset_ns == pytest.approx(100_000_000, abs=2)
    finally:
        source.close()
        thread.join(timeout=1.0)


def test_sequence_gaps_are_counted():
    clock_value = [100.0]
    packets = [
        encode_status(1, int(99.9e9), 240.0, 0.8, 0.0, 0.0, 1920, 1080),
        encode_status(3, int(99.8e9), 240.0, 0.8, 0.0, 0.0, 1920, 1080),
        encode_observation(4, int(99.9e9), 640.0, 360.0, 12.0, 0.9, 1920, 1080),
    ]
    port, thread = _serve_once(packets)
    source = RemoteObservationSource(
        _remote_config(port),
        clock=lambda: clock_value[0],
        connect_timeout_s=2.0,
    )
    try:
        assert source.read() == []
        assert source.read() == []
        assert len(source.read()) == 1
        assert source.packets_received == 3
        assert source.sequence_gaps == 1
    finally:
        source.close()
        thread.join(timeout=1.0)


def test_fake_iphone_pipeline_strikes_with_mock_arm():
    base = Config()
    camera = dataclasses.replace(
        base.camera,
        kind="remote",
        remote_host="127.0.0.1",
        remote_port=0,
        width=1920,
        height=1080,
        fps=240.0,
    )
    sim = dataclasses.replace(base.sim, shots=1, warmup_s=0.1, interval_s=1.0, seed=7)
    run = dataclasses.replace(base.run, max_runtime_s=2.5, fit_every_n_frames=12)
    safety = dataclasses.replace(base.safety, source_timeout_s=2.0, max_misses_before_fault=10)
    config0 = dataclasses.replace(base, camera=camera, sim=sim, run=run, safety=safety)

    server = FakeIphoneServer(config0, port=0, duration_s=3.0, verbose=False)
    config = dataclasses.replace(
        config0,
        camera=dataclasses.replace(camera, remote_port=server.port),
    )
    server.start()
    try:
        system = build_system(config, record=False, verbose=False)
        try:
            summary = system.run()
        finally:
            system.close()
    finally:
        server.close()

    assert summary.frames > 0
    assert summary.fits > 0
    assert summary.strikes >= 1
    assert summary.fault == ""


@pytest.mark.parametrize("kind", [2, 3])
def test_phone_3d_telemetry_does_not_enter_pixel_estimator(kind):
    from tennisrobot.remote import encode_packet

    telemetry = encode_packet(kind, 1, int(99.9e9), -0.2, 0.3, 1.5, 0.4, 1920, 1080)
    observation = encode_observation(2, int(99.9e9), 640, 360, 12, 0.9, 1920, 1080)
    port, thread = _serve_once([telemetry, observation])
    source = RemoteObservationSource(_remote_config(port), clock=lambda: 100.0)
    try:
        assert source.read() == []
        pixels = source.read()
        assert len(pixels) == 1
        assert pixels[0].u_px == 640
        assert source.observations_received == 1
        assert source.packets_received == 2
        assert source.sequence_gaps == 0
    finally:
        source.close()
        thread.join(timeout=1.0)

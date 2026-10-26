import dataclasses

from tennisrobot.config import Config
from tennisrobot.pipeline import build_system
from tennisrobot.recorder import load_events


def _test_config(config: Config, shots: int = 2, seed: int = 7) -> Config:
    return dataclasses.replace(
        config,
        sim=dataclasses.replace(config.sim, shots=shots, seed=seed, warmup_s=0.1, interval_s=1.0),
        safety=dataclasses.replace(config.safety, max_misses_before_fault=10),
    )


def test_simulated_pipeline_strikes_without_a_fault(config):
    system = build_system(_test_config(config), record=False, verbose=False)
    try:
        summary = system.run()
    finally:
        system.close()
    assert summary.frames > 0
    assert summary.fits > 0
    assert summary.strikes >= 1
    assert summary.fault == ""
    assert len(summary.outcomes) == summary.strikes


def test_monitor_mode_tracks_but_never_strikes(config):
    system = build_system(_test_config(config, shots=1), monitor=True, record=False, verbose=False)
    try:
        summary = system.run()
    finally:
        system.close()
    assert summary.strikes == 0
    assert summary.fits > 0
    assert summary.fault == ""


def test_a_run_can_be_recorded_and_loaded(config, tmp_path):
    recorded = _test_config(config, shots=1)
    recorded = dataclasses.replace(recorded, run=dataclasses.replace(recorded.run, record_dir=str(tmp_path)))
    system = build_system(recorded, record=True, verbose=False)
    try:
        system.run()
        path = system.pipeline.recorder.path
    finally:
        system.close()

    assert path.exists()
    recorded_config, events = load_events(path)
    assert recorded_config["camera"]["kind"] == "simulated"
    kinds = [event["kind"] for event in events]
    assert "run_start" in kinds
    assert "observation" in kinds
    assert "run_end" in kinds

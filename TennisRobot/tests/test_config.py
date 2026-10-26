import dataclasses
from pathlib import Path

import pytest

from tennisrobot.config import Config, ConfigError, load_config


def test_defaults_validate_and_roundtrip():
    config = Config()
    config.validate()
    restored = Config.from_dict(config.to_dict())
    assert restored == config


def test_unknown_section_and_key_are_rejected():
    with pytest.raises(ConfigError):
        Config.from_dict({"nonsense": {}})
    with pytest.raises(ConfigError):
        Config.from_dict({"camera": {"fps": 120, "typo": 1}})


def test_invalid_values_are_rejected():
    with pytest.raises(ConfigError):
        Config.from_dict({"camera": {"fps": 0}})
    with pytest.raises(ConfigError):
        Config.from_dict({"arm": {"impact_box_min": [1, 0, 0], "impact_box_max": [0, 1, 1]}})
    with pytest.raises(ConfigError):
        Config.from_dict({"rackets": {}})  # typo in a section name


def test_impact_point_must_lie_on_the_racket():
    base = Config()
    bad = dataclasses.replace(base.racket, impact_point_m=[0.0, 0.0, 2.0])
    with pytest.raises(ConfigError):
        dataclasses.replace(base, racket=bad).validate()


def test_camera_intrinsics_can_be_explicit():
    config = Config.from_dict(
        {"camera": {"fx": 900.0, "fy": 910.0, "cx": 640.0, "cy": 360.0, "horizontal_fov_deg": 40.0}}
    )
    fx, fy, cx, cy = config.camera.intrinsics()
    assert (fx, fy, cx, cy) == (900.0, 910.0, 640.0, 360.0)


def test_partial_toml_uses_defaults(tmp_path):
    path = tmp_path / "partial.toml"
    path.write_text("[sim]\nshots = 1\n", encoding="utf-8")
    config = load_config(path)
    assert config.sim.shots == 1
    assert config.camera.fps == Config().camera.fps


def test_shipped_default_config_matches_builtin_defaults():
    path = Path(__file__).resolve().parents[1] / "config" / "default.toml"
    assert load_config(path) == Config()

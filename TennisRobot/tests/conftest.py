import pytest

from tennisrobot.camera import PinholeCamera
from tennisrobot.config import Config


@pytest.fixture
def config() -> Config:
    return Config()


@pytest.fixture
def camera(config: Config) -> PinholeCamera:
    return PinholeCamera.from_spec(config.camera)

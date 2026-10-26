"""Camera-to-arm tennis ball interception framework.

The public surface is intentionally small: configuration, the pipeline, and the
geometry/physics primitives needed to test a plan without hardware.
"""

from .config import Config, ConfigError, load_config

__all__ = ["Config", "ConfigError", "load_config"]
__version__ = "0.1.0"

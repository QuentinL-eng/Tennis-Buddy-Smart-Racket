"""JSONL run recorder and replay loader.

Every run can be recorded, including the configuration snapshot and every
accepted observation.  A recording is enough to re-fit trajectories and reproduce
planning decisions offline, which is how the camera and estimator get tuned
between hardware sessions.
"""

from __future__ import annotations

import json
import os
import time
from dataclasses import asdict, is_dataclass
from pathlib import Path
from typing import Any

import numpy as np

from . import __version__
from .config import Config
from .geometry import Transform
from .types import RunSummary


def _plain(value: Any) -> Any:
    if isinstance(value, Transform):
        return list(value.pose6())
    if isinstance(value, np.ndarray):
        return [float(item) for item in value.reshape(-1)]
    if isinstance(value, (np.floating, np.integer)):
        return value.item()
    if is_dataclass(value):
        return _plain(asdict(value))
    if isinstance(value, dict):
        return {str(key): _plain(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [_plain(item) for item in value]
    return value


class Recorder:
    def __init__(self, directory: str | Path, config: Config, clock: Any):
        directory = Path(directory)
        directory.mkdir(parents=True, exist_ok=True)
        stamp = time.strftime("%Y%m%d-%H%M%S", time.localtime())
        self.path = directory / f"run-{stamp}-{os.getpid()}.jsonl"
        self._file = open(self.path, "w", encoding="utf-8")
        self._closed = False
        self.write("run_start", clock.now(), config=config.to_dict(), version=__version__)

    def write(self, record_kind: str, at_s: float, **data: Any) -> None:
        if self._closed:
            return
        record: dict[str, Any] = {"kind": record_kind, "t": round(float(at_s), 6)}
        for key, value in data.items():
            record[key] = _plain(value)
        self._file.write(json.dumps(record, separators=(",", ":"), ensure_ascii=False) + "\n")

    def close(self, time_s: float | None = None, summary: RunSummary | None = None) -> None:
        if self._closed:
            return
        if summary is not None:
            self.write("run_end", time_s if time_s is not None else 0.0, summary=asdict(summary))
        self._file.flush()
        self._file.close()
        self._closed = True


def load_events(path: str | Path) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    """Return ``(config_dict, events)`` from a recording."""
    records: list[dict[str, Any]] = []
    config: dict[str, Any] = {}
    with open(path, "r", encoding="utf-8") as source:
        for line in source:
            line = line.strip()
            if not line:
                continue
            record = json.loads(line)
            records.append(record)
            if record.get("kind") == "run_start" and not config:
                config = record.get("config", {})
    if not config:
        raise ValueError(f"{path} has no run_start record")
    return config, records

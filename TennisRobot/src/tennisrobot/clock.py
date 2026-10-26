"""The real-time clock used by every timing-sensitive path.

``time.monotonic()`` is quantized to roughly 15.6 ms on Windows, which is four
camera frames at 240 fps.  ``time.perf_counter()`` is the high-resolution
monotonic clock on both Windows and Linux, and ``perf_counter_ns`` avoids
floating-point rounding in the packet timestamps.  Use this module instead of
calling either one directly, so the source, pipeline and arm always agree on the
same epoch.
"""

from __future__ import annotations

import time


def now() -> float:
    """Seconds on the shared monotonic clock."""
    return time.perf_counter()


def now_ns() -> int:
    """Nanoseconds on the shared monotonic clock."""
    return time.perf_counter_ns()

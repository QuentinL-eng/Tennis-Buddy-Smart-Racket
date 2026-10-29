"""Reference feature extractor for the sweet-spot model.

This file is the *specification*: firmware/src/sweetspot.cpp re-implements it in C++ and
ml/test_parity.py checks that both produce the same numbers. Change one, change the other.

Input: one impact clip, 512 int16 samples at 16 kHz (32 ms). The impact onset sits at index PRE (64).
Output: 12 level-invariant features (nothing depends on how loud the hit was).
"""
import numpy as np

FS = 16000
N = 512
PRE = 64
BLOCK = 16                  # envelope block = 1 ms
NBLK = N // BLOCK           # 32 blocks
BAND_HZ = [250, 500, 800, 1200, 1800, 2600, 3800, 5500]
N_FEATURES = len(BAND_HZ) + 4
FEATURE_NAMES = [f"band_{f}Hz" for f in BAND_HZ] + ["decay", "attack_share", "zcr", "crest"]


def goertzel_power(x, f_hz):
    coeff = np.float32(2.0 * np.cos(2.0 * np.pi * f_hz / FS))
    s1 = np.float32(0.0)
    s2 = np.float32(0.0)
    for v in x:                     # sequential on purpose: same op order as the C++ code
        s0 = np.float32(v) + coeff * s1 - s2
        s2 = s1
        s1 = s0
    return s1 * s1 + s2 * s2 - coeff * s1 * s2


def extract(clip):
    """clip: array-like of N int16 -> np.float32 vector of N_FEATURES."""
    x = np.asarray(clip, dtype=np.float32)
    assert x.shape == (N,), f"expected {N} samples, got {x.shape}"
    return extract_window(x)


def extract_window(clip):
    """Offline window experiment. The firmware extractor still uses exactly N samples."""
    x = np.asarray(clip, dtype=np.float32)
    if x.ndim != 1 or x.size < 12 * BLOCK or x.size % BLOCK:
        raise ValueError("feature window must be 1-D, at least 192 samples, and a multiple of 16")
    size = x.size
    blocks = size // BLOCK
    x = x - np.float32(x.mean())
    sumsq = np.float32(np.sum(x * x))
    feats = []
    for f in BAND_HZ:
        r = goertzel_power(x, f) / (np.float32(size) * sumsq + np.float32(1.0))
        feats.append(np.log10(max(float(r), 0.0) + 1e-6))

    env = np.abs(x).reshape(blocks, BLOCK).sum(axis=1)
    pk = int(np.argmax(env))
    below = np.nonzero(env[pk:] < 0.25 * env[pk])[0]
    decay_blocks = int(below[0]) if below.size else blocks - pk
    feats.append(decay_blocks / blocks)

    feats.append(float(env[4:12].sum() / (env.sum() + 1.0)))

    sgn = x >= 0
    feats.append(float(np.count_nonzero(sgn[1:] != sgn[:-1])) / (size - 1))

    rms = np.sqrt(sumsq / size)
    feats.append(float(np.log10(np.max(np.abs(x)) / (rms + 1.0) + 1e-6)))
    return np.asarray(feats, dtype=np.float32)

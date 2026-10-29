"""Physics-inspired synthetic impact sounds, used until real labelled clips exist.

Hypothesis encoded here (the model is only as good as this hypothesis until retrained on real data):
  * Sweet spot: stiff, well-tensioned string bed -> bright, short "pop" (higher pitch, fast decay,
    little frame energy).
  * Toward the frame: the string bed is shorter/stiffer in the wrong way -> duller (lower pitch,
    less high-frequency energy), faster string damping, and the frame itself is excited, which adds
    low-frequency ringing that lasts tens of milliseconds.
Racket-to-racket and mic-to-mic variation (mode frequencies, damping, mic coloring, noise) is
randomised so the model has to rely on relative cues, not absolute ones.

Labels per clip: distance from the sweet spot in cm, derived: is_sweet = dist <= SWEET_RADIUS_CM,
off_pct = min(dist / EDGE_CM, 1) * 100.
"""
import numpy as np

from features import FS, N, PRE

SWEET_RADIUS_CM = 4.0       # matches ShotMetrics.sweetSpotRadiusCm in the app
EDGE_CM = 12.0              # distance from the sweet spot to the frame = 100 %


def _damped(t, f, tau, amp, phase=0.0):
    return amp * np.exp(-t / tau) * np.sin(2 * np.pi * f * t + phase)


def make_clip(rng, dist_cm, racket):
    """racket: dict of per-unit random factors (see make_racket)."""
    d = min(dist_cm / EDGE_CM, 1.0)
    t = np.arange(N - PRE) / FS
    sig = np.zeros(N, dtype=np.float64)
    body = np.zeros(N - PRE)

    # string-bed pop and its overtones
    f_pop = racket["f_pop"] * (1.0 - 0.28 * d) * rng.uniform(0.96, 1.04)
    tau_pop = racket["tau_pop"] * (1.0 - 0.55 * d)
    a_pop = 1.0 - 0.55 * d
    body += _damped(t, f_pop, tau_pop, a_pop, rng.uniform(0, 6.28))
    body += _damped(t, f_pop * 1.93, tau_pop * 0.6, 0.45 * a_pop, rng.uniform(0, 6.28))
    body += _damped(t, f_pop * 3.1, tau_pop * 0.4, 0.25 * a_pop, rng.uniform(0, 6.28))

    # frame ringing: grows with distance from the sweet spot
    g_frame = 0.10 + 0.9 * d ** 1.4
    for f, tau, a in ((racket["f_frame1"], 0.030, 0.55), (racket["f_frame2"], 0.018, 0.40),
                      (racket["f_frame2"] * 2.4, 0.010, 0.20)):
        body += _damped(t, f * rng.uniform(0.97, 1.03), tau, a * g_frame, rng.uniform(0, 6.28))

    # contact transient: ~2 ms of noise, high-passed by differencing
    n_tr = int(0.002 * FS)
    tr = np.diff(rng.standard_normal(n_tr + 1)) * np.hanning(n_tr) * 0.6
    body[:n_tr] += tr

    onset = PRE + rng.integers(-3, 4)
    onset = int(np.clip(onset, 8, N - 8))
    seg = body[: N - onset]
    sig[onset:onset + seg.size] = seg

    # mic coloring: one-pole high-pass/low-pass mix
    a_lp = racket["mic_lp"]
    out = np.empty_like(sig)
    y = 0.0
    for i, v in enumerate(sig):
        y = a_lp * y + (1 - a_lp) * v
        out[i] = v - racket["mic_hp"] * y        # removes some low end, like a small port
    sig = out

    # noise floor + low-frequency hum, then random loudness
    snr_db = rng.uniform(12, 38)
    p = np.max(np.abs(sig)) + 1e-9
    noise = rng.standard_normal(N) * p * 10 ** (-snr_db / 20)
    hum = np.sin(2 * np.pi * rng.uniform(40, 120) * np.arange(N) / FS + rng.uniform(0, 6.28))
    sig = sig + noise + hum * p * 10 ** (-rng.uniform(25, 45) / 20)
    sig *= rng.uniform(0.05, 0.9) / (np.max(np.abs(sig)) + 1e-9)
    return np.clip(np.round(sig * 32767), -32768, 32767).astype(np.int16)


def make_racket(rng, spread=1.0):
    """Per-unit variation. spread > 1 gives a harder 'unseen racket' test set."""
    s = spread
    return {
        "f_pop": 2300 * np.exp(rng.normal(0, 0.10 * s)),
        "tau_pop": 0.0065 * np.exp(rng.normal(0, 0.15 * s)),
        "f_frame1": 180 * np.exp(rng.normal(0, 0.12 * s)),
        "f_frame2": 520 * np.exp(rng.normal(0, 0.12 * s)),
        "mic_lp": float(np.clip(0.55 + rng.normal(0, 0.10 * s), 0.2, 0.9)),
        "mic_hp": float(np.clip(0.35 + rng.normal(0, 0.15 * s), 0.0, 0.8)),
    }


def sample_distance(rng):
    """~45 % of simulated hits land in the sweet spot, the rest spread out to the frame."""
    if rng.random() < 0.45:
        return SWEET_RADIUS_CM * np.sqrt(rng.random())          # uniform over the sweet disc
    return rng.uniform(SWEET_RADIUS_CM, 14.0)


def make_dataset(n, seed, rackets=24, spread=1.0):
    rng = np.random.default_rng(seed)
    units = [make_racket(rng, spread) for _ in range(rackets)]
    clips = np.empty((n, N), dtype=np.int16)
    dist = np.empty(n, dtype=np.float32)
    for i in range(n):
        dist[i] = sample_distance(rng)
        clips[i] = make_clip(rng, dist[i], units[rng.integers(len(units))])
    return clips, dist


def labels_from_dist(dist):
    sweet = (dist <= SWEET_RADIUS_CM).astype(np.float32)
    pct = np.minimum(dist / EDGE_CM, 1.0) * 100.0
    return sweet, pct.astype(np.float32)

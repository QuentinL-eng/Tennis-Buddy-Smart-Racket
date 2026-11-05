#!/usr/bin/env python3
"""A close-mic voice chain for takes recorded on a tablet across the room.

Voice Memos on an iPad sounds boxy and distant: too much 300-500 Hz, little chest, little presence, and the room on
every word. In order: remove noise (DeepFilterNet), take down the room, tighten the pauses and breaths, match the tone
to a speech spectrum with a broadcast curve on top, de-ess, a touch of harmonics, level, compress, then normalize.

    FFMPEG=... DEEP_FILTER=... python scripts/voice.py in.m4a out.wav [--natural] [--tempo 1.04]

--natural keeps the timing, for speech that has to stay in sync with a mouth on camera. Nothing leaves the machine.
"""
import os
import subprocess
import sys
import tempfile
import json
import re
from pathlib import Path

import numpy as np
from scipy.io import wavfile
from scipy.ndimage import maximum_filter1d, uniform_filter1d
from scipy.signal import fftconvolve, istft, stft

FFMPEG = os.environ.get('FFMPEG', 'ffmpeg')
DEEP_FILTER = os.environ.get('DEEP_FILTER', 'deep-filter')
SR = 48000

# Long-term average speech spectrum for a male voice, by third octave (Byrne et al. 1994), plus the usual close-mic curve:
# more chest, less box, more presence and air. The second column is the curve on top, in dB.
TARGET = [
    (63, 38.6, -10), (80, 43.5, -8), (100, 54.4, -3), (125, 57.7, 1.5), (160, 56.8, 2.5), (200, 60.2, 1.5), (250, 60.3, 0),
    (315, 59.0, -2.5), (400, 62.1, -3.5), (500, 62.1, -2.5), (630, 60.5, -1), (800, 56.8, 0), (1000, 53.7, 0),
    (1250, 53.0, 0), (1600, 52.0, 0.5), (2000, 48.7, 1.5), (2500, 48.1, 2.5), (3150, 46.8, 3), (4000, 45.6, 3),
    (5000, 44.5, 2), (6300, 44.3, 1), (8000, 43.7, 1.5), (10000, 43.4, 2.5), (12500, 41.3, 3), (16000, 40.7, 2),
]
MAX_BOOST, MAX_CUT = 9.0, 9.0


def run(*args):
    return subprocess.run([FFMPEG, '-hide_banner', *map(str, args)], check=True, capture_output=True, text=True)


def read(path):
    sr, x = wavfile.read(path)
    assert sr == SR
    return x.astype(np.float64) / (32768.0 if x.dtype == np.int16 else 1.0)


def write(path, x):
    wavfile.write(path, SR, np.clip(x, -1, 1).astype(np.float32))


def denoise(src, tmp):
    raw = Path(tmp) / 'in.wav'
    run('-y', '-i', src, '-vn', '-af', 'apad=pad_dur=0.5', '-ac', 1, '-ar', SR, '-sample_fmt', 's16', raw)  # room for the last word
    subprocess.run([DEEP_FILTER, '-D', '--pf', '-o', f'{tmp}/df', str(raw)], check=True, capture_output=True)
    return read(Path(tmp) / 'df' / 'in.wav')


def dereverb(x, strength):
    """Late-reverb suppression: a word's own energy from 60 ms ago, decayed, is treated as room."""
    nper, hop = 1024, 256
    f, t, Z = stft(x, SR, nperseg=nper, noverlap=nper - hop)
    P = np.abs(Z) ** 2
    rt60 = 0.45
    delay = max(1, int(0.06 * SR / hop))
    decay = np.exp(-13.8 * (delay * hop / SR) / rt60)
    late = np.zeros_like(P)
    late[:, delay:] = decay * P[:, :-delay]
    late = uniform_filter1d(late, 5, axis=1)
    gain = np.clip(1 - strength * late / (P + 1e-12), 0.28, 1)
    gain = uniform_filter1d(uniform_filter1d(gain, 3, axis=1), 5, axis=0)
    _, y = istft(Z * gain, SR, nperseg=nper, noverlap=nper - hop)
    return y[:len(x)]


def envelope(x, ms=8):
    hop = int(SR * ms / 1000)
    e = np.sqrt(np.maximum(uniform_filter1d(x ** 2, hop * 2), 0))[::hop]
    return 20 * np.log10(e + 1e-9), hop


def tighten(x):
    """Shortens pauses and drops the breaths in them. Long gaps stay a little longer: they are the sentence breaks."""
    env, hop = envelope(x)
    top = np.percentile(env, 95)
    speech = maximum_filter1d((env > top - 38).astype(np.uint8), int(0.09 * SR / hop)) > 0  # holds 45 ms each side, so soft word ends stay
    out, i, n = [], 0, len(speech)
    cuts = []
    while i < n:
        if speech[i]:
            i += 1
            continue
        j = i
        while j < n and not speech[j]:
            j += 1
        cuts.append((i * hop, j * hop))
        i = j
    fade = int(0.012 * SR)
    pos = 0
    if cuts and cuts[0][0] == 0:
        pos = max(0, cuts[0][1] - int(0.02 * SR))
        cuts = cuts[1:]
    for a, b in cuts:
        gap = (b - a) / SR
        if b >= len(x) - hop:  # the tail
            keep = 0.12
        elif gap < 0.14:
            continue
        else:
            keep = 0.2 if gap > 0.38 else 0.09
        k = int(keep * SR)
        if b - a <= k + fade * 2:
            continue
        seg = x[pos:a + k // 2].copy()
        seg[-fade:] *= np.linspace(1, 0, fade)
        out.append(seg)
        pos = b - k // 2 - fade
        head = np.linspace(0, 1, fade)
        nxt = x[pos:pos + fade] * head
        out.append(nxt)
        pos += fade
    out.append(x[pos:])
    return np.concatenate(out)


def third_octave(x):
    f, _, Z = stft(x, SR, nperseg=4096, noverlap=3072)
    P = np.abs(Z) ** 2
    level = 10 * np.log10(P.sum(axis=0) + 1e-14)
    speech = level > np.percentile(level, 92) - 20
    ltas = P[:, speech].mean(axis=1)
    bands = []
    for fc, _, _ in TARGET:
        m = (f >= fc / 2 ** (1 / 6)) & (f < fc * 2 ** (1 / 6))
        bands.append(10 * np.log10(ltas[m].sum() + 1e-16))
    return np.array(bands)


def match_tone(x, amount=1.0):
    fc = np.array([t[0] for t in TARGET], dtype=float)
    target = np.array([t[1] + t[2] for t in TARGET])
    now = third_octave(x)
    mid = (fc >= 500) & (fc <= 2500)
    delta = (target - target[mid].mean()) - (now - now[mid].mean())
    delta = np.convolve(np.pad(delta, 1, mode='edge'), [0.25, 0.5, 0.25], mode='valid')  # no narrow peaks
    delta = np.clip(delta * amount, -MAX_CUT, np.where(fc < 200, 6.0, MAX_BOOST))  # boosting lows further only finds rumble and plosives
    n = 4097
    freqs = np.fft.rfftfreq(n * 2, 1 / SR)
    db = np.interp(np.log10(np.maximum(freqs, 1)), np.log10(fc), delta, left=delta[0], right=delta[-1])
    db[freqs < 80] -= 24 * np.log2(80 / np.maximum(freqs[freqs < 80], 10))  # high-pass
    h = np.fft.irfft(10 ** (db / 20))
    h = np.roll(h, n) * np.hanning(len(h))
    return fftconvolve(x, h, mode='same')


def deess(x):
    nper, hop = 1024, 256
    f, _, Z = stft(x, SR, nperseg=nper, noverlap=nper - hop)
    band = (f >= 4800) & (f <= 11000)
    level = 10 * np.log10((np.abs(Z[band]) ** 2).sum(axis=0) + 1e-14)
    loud = level > np.percentile(level, 50)
    th = np.percentile(level[loud], 72)
    reduce = np.clip((level - th) * 0.7, 0, 9)
    reduce = uniform_filter1d(maximum_filter1d(reduce, 3), 3)
    gain = np.ones(Z.shape)
    gain[np.ix_(band, np.arange(Z.shape[1]))] = 10 ** (-reduce / 20)
    _, y = istft(Z * gain, SR, nperseg=nper, noverlap=nper - hop)
    return y[:len(x)]


def warm(x, mix=0.14):
    peak = np.abs(x).max() + 1e-9
    n = x / peak * 0.8
    sat = np.tanh(2.2 * n + 0.08) - np.tanh(0.08)
    sat *= np.abs(n).max() / (np.abs(sat).max() + 1e-9)
    return (n * (1 - mix) + sat * mix) * peak / 0.8


def trim_tail(x):
    env, hop = envelope(x, 8)
    top = np.percentile(env, 95)
    last = np.where(env > top - 28)[0][-1]
    return x[:min(len(x), (last + 1) * hop + int(0.2 * SR))]


def expand(x):
    """Pulls the gaps between words down, so the compressor can't lift the room back up."""
    env, hop = envelope(x, 5)
    top = np.percentile(env, 95)
    gate = np.clip((env - (top - 36)) / 10, 0, 1)
    gate = uniform_filter1d(maximum_filter1d(gate, int(0.09 * SR / hop)), int(0.03 * SR / hop))
    g = np.interp(np.arange(len(x)), np.arange(len(gate)) * hop, 10 ** ((gate - 1) * 16 / 20))
    return x * g


def finish(src, out, tempo):
    chain = (('atempo=%.3f,' % tempo) if tempo != 1 else '') + (
        'dynaudnorm=f=300:g=11:p=0.8:m=2.5:r=0.35,'
        'acompressor=threshold=-20dB:ratio=2.2:attack=8:release=90:knee=6:makeup=2,'
        'acompressor=threshold=-13dB:ratio=1.8:attack=25:release=220:knee=8:makeup=1.3,'
        'alimiter=limit=0.89:attack=3:release=40:level=false')
    target = 'I=-16:TP=-1.5:LRA=6'
    first = subprocess.run([FFMPEG, '-hide_banner', '-i', src, '-af', f'{chain},loudnorm={target}:print_format=json', '-f', 'null', '-'],
                           capture_output=True, text=True, check=True).stderr
    m = json.loads(re.search(r'\{[^{}]*"input_i"[^{}]*\}', first).group(0))
    run('-y', '-i', src, '-af',
        f"{chain},loudnorm={target}:linear=true:measured_I={m['input_i']}:measured_TP={m['input_tp']}:measured_LRA={m['input_lra']}:"
        f"measured_thresh={m['input_thresh']}:offset={m['target_offset']}", '-ar', SR, '-ac', 1, out)


def pro_voice(src, out, natural=False, tempo=1.04, end=None):
    with tempfile.TemporaryDirectory() as tmp:
        x = denoise(src, tmp)
        x = dereverb(x, 0.85 if natural else 0.7)
        if not natural:
            x = tighten(x)
        x = match_tone(x)
        x = deess(x)
        x = warm(x)
        x = expand(x)
        if not natural:
            x = trim_tail(x)
        mid = Path(tmp) / 'mid.wav'
        write(mid, x / (np.abs(x).max() + 1e-9) * 0.7)
        finish(mid, out, 1 if natural else tempo)
        if end:
            trimmed = Path(tmp) / 'trimmed.wav'
            run('-y', '-i', out, '-af', f'atrim=0:{end},afade=t=out:st={end - 0.04}:d=0.04', trimmed)
            Path(out).write_bytes(trimmed.read_bytes())


if __name__ == '__main__':
    args = sys.argv[1:]
    natural = '--natural' in args
    if natural:
        args.remove('--natural')
    tempo = 1.04
    if '--tempo' in args:
        i = args.index('--tempo')
        tempo = float(args[i + 1])
        del args[i:i + 2]
    pro_voice(args[0], args[1], natural, tempo)

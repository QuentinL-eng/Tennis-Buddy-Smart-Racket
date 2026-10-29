"""Synthetic "what if" coaching data for Muse Spark's simulate_change tool.

Muse sees a session digest, proposes a technique change ("close the face 3°, swing 5% slower"), calls
simulate_change, and explains the estimated result. This script makes thousands of such conversations from
synthetic players whose numbers are anchored to real recordings, and answers every what-if with the same physics
the app runs (coach_sim.py mirrors ShotSimulator and CoachTools).

    python3 ml/whatif_synth.py priors                 # real recordings -> ml/whatif_priors.json (summary stats only)
    python3 ml/whatif_synth.py generate --out data/whatif --players 400 --seed 7

Where each number comes from (details in docs/WHATIF_DATASET.md):
  * Good data, phone sessions (data/phone/, camera-confirmed hits, full-rate IMU): racket speed at contact and its
    shot-to-shot spread. These anchor the players' swing speeds.
  * Good data, sweet-spot sessions (data/sessions/*/positions.csv, 274 reviewed contacts): the shape of the
    contact cloud, and the ridge model's 1.83 cm error for mic-only hits.
  * Bad data, club (data/club-2026-10-28/, 17% of the stream arrived): rally cadence, per-recording BLE throughput
    and the gyro range bug. These set which shots lose their impact window (mic-only) and which are saturated, the
    cases where Muse must not simulate.
  * Assumed, not measured: swing path and face angle per stroke (no orientation in any recording yet), the injected
    technique flaws, and shot mixes. Swap these for measured values once impact-mode sessions exist.

The physics is ShotSimulator: a bounded sensitivity model, not a validated ball-flight predictor. The dataset
inherits that: it teaches Muse to use the tool and report it honestly, not that the tool is right.
"""
import argparse
import csv
import glob
import hashlib
import json
import math
import os
import random
import sys
import uuid
from datetime import datetime, timedelta, timezone

import numpy as np

sys.path.insert(0, os.path.dirname(__file__))
from coach_sim import (DELTA_LIMITS, GROUND_INCOMING_KMH, INCOMING_KMH, LABELS, SYSTEM, Session, Shot,  # noqa: E402
                       Units, digest, get_session_digest, question_prompt, simulate, simulate_change, tool_json, tool_schemas)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PRIORS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "whatif_priors.json")
EFFECTIVE_RADIUS_M = 1.15                         # RacketProfile.effectiveRadiusM default
GYRO_2000_RADS = 32767 / 16.4 * math.pi / 180     # ±2000 dps wire limit, 34.87 rad/s
SATURATED_KMH = GYRO_2000_RADS * EFFECTIVE_RADIUS_M * 3.6
WINDOW_SAMPLES = 448                              # impact-mode window
RIDGE_MEAN_ERROR_CM = 1.83                        # ml/runs/SUMMARY-20261028.md, ridge, grouped CV
SWING_EVENT_RADS = 10.0                           # club high-g events with a real swing before them
VERSION = 1


# ------------------------------------------------------------------------------------------------ priors

def _kmh(rads):
    return float(rads) * EFFECTIVE_RADIUS_M * 3.6


def extract_priors(root=ROOT):
    sys.path.insert(0, os.path.join(root, "tools"))
    import csv_session_stats as cs

    # Good: phone sessions. Mean |gyro| 2–15 ms before each camera-confirmed impact.
    phone_kmh, phone_cv = [], []
    for path in sorted(glob.glob(os.path.join(root, "data/phone/*/imu_aligned.npz"))):
        z = np.load(path)
        t, g = z["t_phone_s"], np.linalg.norm(z["gyro_rad_s"], axis=1)
        speeds = [_kmh(g[(t > ti - 0.015) & (t < ti - 0.002)].mean()) for ti in z["impacts_phone_s"]
                  if ((t > ti - 0.015) & (t < ti - 0.002)).any()]
        phone_kmh += speeds
        phone_cv.append(float(np.std(speeds) / np.mean(speeds)))

    # Good: reviewed sweet-spot contacts (only the clips that made it into labels.csv).
    contacts = []
    for sdir in sorted(glob.glob(os.path.join(root, "data/sessions/*/"))):
        pos, lab = os.path.join(sdir, "positions.csv"), os.path.join(sdir, "labels.csv")
        if not (os.path.exists(pos) and os.path.exists(lab)):
            continue
        keep = {r["file"] for r in csv.DictReader(open(lab))}
        contacts += [[round(float(r["x_cm"]), 2), round(float(r["y_cm"]), 2)]
                     for r in csv.DictReader(open(pos)) if r["file"] in keep]

    # Bad: club raw-stream CSVs. Only what survives 83% loss: cadence, throughput, clipping, real-swing speeds.
    intervals, throughput, clipped, recordings, club_kmh = [], [], 0, 0, []
    for path in sorted(glob.glob(os.path.join(root, "data/club-*/*-racket.csv"))):
        r = cs.analyze(path)
        if r["samples"] < 1000:
            continue
        recordings += 1
        clipped += r["gyro_clipped"] > 0
        intervals += [round(x, 3) for x in r["intervals"]]
        throughput += [round(x) for x in r["throughput"]]
        d = np.loadtxt(path, delimiter=",", skiprows=1, ndmin=2)
        t, g, h = d[:, 0], np.linalg.norm(d[:, 4:7], axis=1), np.linalg.norm(d[:, 7:10], axis=1)
        for i in cs.events(t, h, cs.EVENT_G, 0.3):
            pre = (t > t[i] - 0.020) & (t < t[i] - 0.002)
            if pre.any() and g[pre][-1] >= SWING_EVENT_RADS:
                club_kmh.append(round(_kmh(g[pre][-1]), 1))

    if not phone_kmh or not contacts or not intervals:
        sys.exit("Missing recordings: need data/phone/*/imu_aligned.npz, data/sessions/*/positions.csv and "
                 "data/club-*/*-racket.csv")
    return {
        "version": VERSION,
        "sources": {"phone_impacts": len(phone_kmh), "reviewed_contacts": len(contacts),
                    "club_recordings": recordings, "club_swing_events": len(club_kmh)},
        "phone_swing_kmh": [round(x, 1) for x in phone_kmh],
        "phone_swing_cv": round(float(np.mean(phone_cv)), 3),
        "club_swing_kmh": club_kmh,
        "contacts_cm": contacts,
        "ridge_mean_error_cm": RIDGE_MEAN_ERROR_CM,
        "club_intervals_s": intervals,
        "club_throughput_sps": throughput,
        "club_gyro_clipped_fraction": round(clipped / recordings, 3),
        "phone_throughput_sps": 1000 * (1 - 0.25),   # phone sessions: about a quarter of packets lost (sync.json)
    }


# ------------------------------------------------------------------------------------------------ players

# Assumed stroke geometry (degrees). Path: + = low to high. Face: + = open. Brush ~ sin(path - face).
STYLES = {
    "forehand": {"topspin": (22, 0)},
    "backhand": {"topspin": (18, 1), "slice": (-12, 14)},
    "serve": {"flat": (-3, -2), "kick": (24, 0)},
    "volley": {"punch": (-5, 8)},
}
SWING_RATIO = {"forehand": (1.0, 1.0), "backhand": (0.82, 0.95), "serve": (1.05, 1.22), "volley": (0.35, 0.5)}

# Injected flaws: (stroke it applies to, what changes in the player's true technique, the objective Muse should pursue).
FLAWS = {
    "open_face":      "face opens 5–9° past the style's norm, so the ball goes out flat with little spin",
    "flat_path":      "path 8–14° flatter than the style's norm, so little spin",
    "tip_contact":    "contact centered 3–5 cm toward the tip",
    "throat_contact": "contact centered 3–5 cm toward the throat",
    "side_contact":   "contact centered 3–4 cm left or right",
    "slow_swing":     "swing 15–25% slower than the player's level",
    "overswing":      "swing 8–15% faster than the player's level, with a contact cloud 1.8 times as wide",
    "none":           "no injected flaw",
}


def make_player(rng, priors, index):
    # Swing anchor: half from the good phone hits, half from real swings seen at the club.
    pool = priors["phone_swing_kmh"] if rng.random() < 0.5 or not priors["club_swing_kmh"] else priors["club_swing_kmh"]
    level = float(np.clip(rng.choice(pool) * rng.lognormal(0, 0.08), 55, 150))
    strokes = {}
    for stroke, styles in STYLES.items():
        style = rng.choice(list(styles)) if stroke != "backhand" else ("slice" if rng.random() < 0.35 else "topspin")
        path, face = styles[style]
        strokes[stroke] = {"style": style, "swing_kmh": level * rng.uniform(*SWING_RATIO[stroke]),
                           "path_deg": path + rng.normal(0, 3), "face_deg": face + rng.normal(0, 1.5),
                           "contact_bias_cm": [rng.normal(0, 0.6), rng.normal(0, 0.8)],
                           "contact_scale": rng.uniform(0.55, 1.0)}
    flaw = rng.choice(list(FLAWS), p=[0.16, 0.12, 0.14, 0.1, 0.08, 0.14, 0.12, 0.14])
    target = rng.choice(["forehand", "backhand"], p=[0.55, 0.45]) if flaw != "none" else None
    if target == "backhand" and strokes["backhand"]["style"] == "slice" and flaw in ("open_face", "flat_path"):
        strokes["backhand"].update(style="topspin", path_deg=18 + rng.normal(0, 3), face_deg=1 + rng.normal(0, 1.5))
    s = strokes.get(target)
    if flaw == "open_face":
        s["face_deg"] += rng.uniform(5, 9)
    elif flaw == "flat_path":
        s["path_deg"] -= rng.uniform(8, 14)
    elif flaw == "tip_contact":
        s["contact_bias_cm"][1] = rng.uniform(3, 5)
    elif flaw == "throat_contact":
        s["contact_bias_cm"][1] = -rng.uniform(3, 5)
    elif flaw == "side_contact":
        s["contact_bias_cm"][0] = rng.choice([-1, 1]) * rng.uniform(3, 4)
    elif flaw == "slow_swing":
        s["swing_kmh"] *= 1 - rng.uniform(0.15, 0.25)
    elif flaw == "overswing":
        s["swing_kmh"] *= 1 + rng.uniform(0.08, 0.15)
        s["contact_scale"] *= 1.8
    mix = rng.dirichlet([9, 7, 2, 2])
    return {"player_id": f"p{index:04d}", "level_kmh": level, "flaw": flaw, "flaw_stroke": target,
            "metric": bool(rng.random() < 0.7), "mix": dict(zip(["forehand", "backhand", "serve", "volley"], mix)),
            "strokes": strokes}


# ------------------------------------------------------------------------------------------------ sessions

def make_session(rng, pyrng, priors, player, start):
    contacts = np.array(priors["contacts_cm"])
    noise = priors["ridge_mean_error_cm"] / math.sqrt(math.pi / 2)    # per-axis sigma for that mean radial error
    cv = priors["phone_swing_cv"]
    # Link conditions: like the club night (bad) or like the phone sessions (good).
    clubby = rng.random() < 0.5
    offline = rng.random() < 0.04                     # motion stream never came up: every hit is mic-only
    sps = float(rng.choice(priors["club_throughput_sps"])) if clubby else priors["phone_throughput_sps"]
    window_s = WINDOW_SAMPLES / max(sps, 1)
    gyro_bug = clubby and rng.random() < priors["club_gyro_clipped_fraction"]
    minutes = rng.uniform(20, 90)
    n = int(min(400, max(25, minutes * rng.uniform(3, 8))))
    gaps = rng.choice(priors["club_intervals_s"], size=n)
    kinds = rng.choice(list(player["mix"]), size=n, p=list(player["mix"].values()))
    shots, busy_until, t = [], -1.0, 0.0
    for kind, gap in zip(kinds, gaps):
        t += float(gap)
        st = player["strokes"][kind]
        swing = max(10.0, rng.normal(st["swing_kmh"], cv * st["swing_kmh"]))
        path, face = rng.normal(st["path_deg"], 3), rng.normal(st["face_deg"], 2)
        cx, cy = contacts[rng.integers(len(contacts))] * st["contact_scale"] + st["contact_bias_cm"]
        mx, my = cx + rng.normal(0, noise), cy + rng.normal(0, noise)
        if offline or t < busy_until:                            # the previous window is still sending: the sound model only
            true_d = math.hypot(cx, cy)
            pred = max(0.0, true_d + rng.normal(0, noise * 1.25))
            shots.append(Shot.from_mic(pred <= 4.0, int(round(pred / 12 * 100))))
            continue
        busy_until = t + window_s
        saturated = gyro_bug and swing > SATURATED_KMH
        swing_measured = min(swing, SATURATED_KMH) if saturated else swing
        _, ball, rpm, spin = simulate(swing_measured, path, face, mx, my, INCOMING_KMH.get(kind, GROUND_INCOMING_KMH))
        shots.append(Shot(type=kind, swing_kmh=swing_measured, ball_kmh=ball, spin_rpm=rpm, spin=spin, face_deg=face,
                          path_deg=path, x_cm=float(np.clip(mx, -12, 12)), y_cm=float(np.clip(my, -14, 14)),
                          saturated=bool(saturated)))
    sid = str(uuid.UUID(int=pyrng.getrandbits(128), version=4)).upper()
    played = rng.random() < 0.4
    session = Session(id=sid, start=start.strftime("%Y-%m-%dT%H:%M:%SZ"), duration_s=minutes * 60, shots=shots,
                      points_won=int(rng.integers(10, 60)) if played else 0,
                      points_lost=int(rng.integers(10, 60)) if played else 0)
    conditions = {"link": "offline" if offline else "club" if clubby else "phone", "throughput_sps": sps, "window_s": round(window_s, 2),
                  "gyro_range_bug": bool(gyro_bug)}
    return session, conditions


# ------------------------------------------------------------------------------------------------ what-if search

OBJECTIVES = {
    "more_spin": "more topspin without losing ball speed",
    "more_pace": "more ball speed without losing spin",
    "cleaner_contact": "hit closer to the sweet spot",
    "fix_slice": "turn a floating slice into topspin",
}


def candidates(base, objective):
    """Single- and two-lever changes in the clamped ranges, in the steps a coach would suggest."""
    out = []
    face = [-2, -3, -4, -5, -6, -8] if objective in ("more_spin", "fix_slice") else [-2, 2]
    path = [3, 5, 8, 10, 12, 15] if objective in ("more_spin", "fix_slice") else [3, 5]
    swing = [5, 10, 15] if objective in ("more_pace", "more_spin") else [-5, -10]
    cx, cy = -base["contactXcm"], -base["contactYcm"]
    contact = []
    for f in (0.5, 1.0):
        x, y = round(cx * f, 1), round(cy * f, 1)
        if abs(x) >= 0.5 or abs(y) >= 0.5:
            contact.append({"contact_x_cm": x if abs(x) >= 0.5 else 0.0, "contact_y_cm": y if abs(y) >= 0.5 else 0.0})
    singles = [{"face_deg": v} for v in face] + [{"path_deg": v} for v in path] + \
              [{"swing_percent": v} for v in swing] + contact
    out += singles
    for a in singles:
        for b in singles:
            if list(a)[0] < list(b)[0] and not ({"contact_x_cm", "contact_y_cm"} & set(a) & set(b)):
                out.append({**a, **b})
    return out


def score(objective, before, after):
    """Gain toward the goal (higher is better), or None when the change breaks the goal's guardrail."""
    db, ds = after["ball_speed"] / before["ball_speed"] - 1, after["spin_rpm"] - before["spin_rpm"]
    if objective == "more_spin":
        return ds / 100 if db >= -0.03 and after["spin_type"] == "topspin" and ds > 0 else None
    if objective == "more_pace":
        ok = after["spin_rpm"] >= 0.9 * before["spin_rpm"] and after["spin_type"] == before["spin_type"]
        return db * 100 if ok and db > 0 else None
    if objective == "cleaner_contact":
        return db * 100 if db > 0 else None
    if objective == "fix_slice":
        return after["spin_rpm"] / 100 if after["spin_type"] == "topspin" and db >= -0.05 else None
    raise ValueError(objective)


def reaches_target(objective, before, after):
    """The goal a coach would call done: a clear, not maximal, improvement."""
    if objective == "more_spin":
        return after["spin_rpm"] >= max(1.3 * before["spin_rpm"], before["spin_rpm"] + 400, 1200)
    if objective == "more_pace":
        return after["ball_speed"] >= 1.05 * before["ball_speed"]
    if objective == "cleaner_contact":
        return math.hypot(after["applied_parameters"]["contactXcm"], after["applied_parameters"]["contactYcm"]) <= 2.0
    if objective == "fix_slice":
        return after["spin_rpm"] >= 800
    raise ValueError(objective)


SCALE = {"swing_percent": 5, "face_deg": 3, "path_deg": 4, "contact_x_cm": 2, "contact_y_cm": 2}
OPEN_FACE_DEG, FLAT_PATH_DEG = 4, 14     # what a coach reading the digest would call open / flat on a topspin stroke


def diagnosis(base):
    """Levers the digest itself points at. Face and path move spin identically in the model, so this breaks the tie."""
    out = set()
    if base["faceAngleDeg"] >= OPEN_FACE_DEG:
        out.add("face_deg")
    if -5 < base["pathAngleDeg"] <= FLAT_PATH_DEG:
        out.add("path_deg")
    return out


def cost(deltas, flagged=()):
    """Simplicity: fewer levers and smaller changes first; a lever the digest flags costs half."""
    return sum((1 + abs(v) / SCALE[k]) * (0.5 if k in flagged else 1) for k, v in deltas.items() if v)


def search(session, units, stroke, objective):
    """Every candidate, ranked: the cheapest change that reaches the target wins; otherwise the best gain per cost."""
    rows = []
    base = simulate_change(session, units, type=stroke)["before"]["applied_parameters"]
    flagged = diagnosis(base) if objective in ("more_spin", "fix_slice") else set()
    for deltas in candidates(base, objective):
        r = simulate_change(session, units, type=stroke, **deltas)
        s = score(objective, r["before"], r["after"])
        hit = s is not None and reaches_target(objective, r["before"], r["after"])
        c = cost(deltas, flagged)
        rank = None if s is None else (1000 - c + 0.01 * s) if hit else s / (1 + c)
        rows.append({"deltas": deltas, "result": r, "score": s, "target": hit, "rank": rank})
    return rows


# ------------------------------------------------------------------------------------------------ language

def fmt_speed(v, unit):
    return f"{round(v)} {unit}"


def fmt_rpm(v):
    return f"{int(round(v, -1)):,} rpm"


def describe(deltas, units):
    """Coaching words for a change. Contact deltas only get a number in cm (the tool's unit)."""
    parts = []
    for k, v in deltas.items():
        if not v:
            continue
        a = abs(v)
        n = f"{a:g}"
        if k == "face_deg":
            parts.append(f"close the face {n}°" if v < 0 else f"open the face {n}°")
        elif k == "path_deg":
            parts.append(f"swing {n}° more low-to-high" if v > 0 else f"flatten the path {n}°")
        elif k == "swing_percent":
            parts.append(f"swing {n}% faster" if v > 0 else f"swing {n}% slower")
    x, y = deltas.get("contact_x_cm", 0), deltas.get("contact_y_cm", 0)
    if x or y:
        size = f"{math.hypot(x, y):.1f} cm " if units.metric else ""
        parts.append(f"move contact {size}back toward the center of the strings")
    return " and ".join(parts) if len(parts) < 3 else ", ".join(parts[:-1]) + " and " + parts[-1]


CUES = {
    "face_deg-": ["keep the strings facing the net a beat longer through contact", "turn the racket face slightly down at contact",
                  "let the forearm turn over through the ball instead of holding the face open"],
    "face_deg+": ["tilt the strings slightly up at contact", "hold the face a touch more open through the ball"],
    "path_deg+": ["start the racket below the ball and finish over your shoulder", "drop the racket head earlier and brush up the back of the ball"],
    "path_deg-": ["swing more through the ball than up it", "finish out toward the target, not straight up"],
    "swing_percent+": ["load your legs and turn your hips earlier for the extra racket speed", "relax the grip so the racket head can accelerate"],
    "swing_percent-": ["ease off to about 90% effort and stay balanced", "slow the swing slightly and keep your head still at contact"],
    "contact_y_cm-": ["step in so you are not reaching for the ball", "move your feet closer to the ball so you meet it nearer the middle"],
    "contact_y_cm+": ["give yourself a bit more room from the ball", "take a small step back so you're not crowded at contact"],
    "contact_x_cm": ["keep your head still and watch the ball onto the strings"],
}


def cue(deltas, rng):
    k = max((k for k, v in deltas.items() if v), key=lambda k: abs(deltas[k]) / SCALE[k])
    key = k if k == "contact_x_cm" else f"{k}{'+' if deltas[k] > 0 else '-'}"
    return rng.choice(CUES[key])


def effect(before, after):
    b, a = before, after
    unit = a["speed_unit"]
    if abs(a["spin_rpm"] - b["spin_rpm"]) < 10:
        spin = f"spin holds at {fmt_rpm(a['spin_rpm'])}"
    else:
        spin = f"spin goes from {fmt_rpm(b['spin_rpm'])} to about {fmt_rpm(a['spin_rpm'])}"
    if a["spin_type"] != b["spin_type"]:
        spin += f" ({b['spin_type']} becomes {a['spin_type']})"
    elif a["spin_type"] == "slice":
        spin += " (still slice)"
    if abs(a["ball_speed"] - b["ball_speed"]) < 1:
        speed = f"ball speed holds at {fmt_speed(a['ball_speed'], unit)}"
    else:
        speed = f"ball speed goes from {fmt_speed(b['ball_speed'], unit)} to about {fmt_speed(a['ball_speed'], unit)}"
    return spin, speed


def why(stroke, deltas, digest_stroke, units):
    """One sentence from the digest that motivates the main lever. Digest numbers are tool numbers too."""
    d = digest_stroke
    k = max((k for k, v in deltas.items() if v), key=lambda k: abs(deltas[k]) / SCALE[k])
    if k == "face_deg" and d["avgFaceDeg"] is not None and d["avgFaceDeg"] > 0:
        return f"Your {stroke} face averages {d['avgFaceDeg']}° open at contact."
    if k == "path_deg" and d["avgPathDeg"] is not None:
        return f"Your {stroke} path averages {d['avgPathDeg']}° upward."
    if k == "swing_percent" and d["avgSwingSpeed"] is not None:
        return f"Your {stroke} swing averages {d['avgSwingSpeed']} {units.speed_unit}."
    if k.startswith("contact") and d["avgContactTowardTip"] is not None:
        y, x = d["avgContactTowardTip"], d["avgContactRight"]
        if abs(y) >= abs(x):
            return f"Your {stroke} contact sits {abs(y):.1f} {units.length_unit} toward the {'tip' if y > 0 else 'throat'}."
        return f"Your {stroke} contact sits {abs(x):.1f} {units.length_unit} {'right' if x > 0 else 'left'} of center."
    return ""


def answer_objective(stroke, objective, best, alt, units, digest_stroke, rng):
    r = best["result"]
    spin, speed = effect(r["before"], r["after"])
    order = (spin, speed) if objective in ("more_spin", "fix_slice") else (speed, spin)
    change = describe(r["applied_deltas"], units)
    lead = rng.choice([f"Estimated: if you {change}, ", f"My pick: {change}. Estimated, ",
                       f"Try this: {change}. The estimate says "])
    head = why(stroke, r["applied_deltas"], digest_stroke, units)
    if not best["target"]:
        head = (head + " No small change gets all the way there; this was the best I found.").strip()
    body = lead + f"{order[0]} and {order[1]}."
    other = ""
    if alt is not None:
        a = alt["result"]["after"]
        what = fmt_rpm(a["spin_rpm"]) if objective in ("more_spin", "fix_slice") else fmt_speed(a["ball_speed"], a["speed_unit"])
        alt_change = describe(alt["result"]["applied_deltas"], units)
        if alt["score"] is not None and alt["score"] >= 0.98 * best["score"]:
            other = f"The other option I tested ({alt_change}) gets about the same, {what}, but your numbers point to this one."
        else:
            other = f"That beats the other option I tested ({alt_change}), which gets about {what}."
    tail = f"Cue: {cue(r['applied_deltas'], rng)}. " + rng.choice([
        "These are physics estimates on your average shot, not measured results.",
        f"It's an estimate, so check it with 10 {stroke}s next session.",
        "Estimates only; the model doesn't predict where the ball lands."])
    parts = [head, body, other, tail]
    if len(" ".join(parts).split()) > 80:          # the prompt asks for under 80 words: drop the comparison first
        parts[2] = ""
    return " ".join(p for p in parts if p)


def answer_no_gain(stroke, objective, result, units):
    """Nothing in range reaches the goal. Report the biggest change tested, honestly."""
    spin, speed = effect(result["before"], result["after"])
    change = describe(result["applied_deltas"], units)
    if objective == "fix_slice":
        lead = f"Turning this {stroke} from slice to topspin is bigger than any change I can simulate."
    else:
        lead = f"I couldn't find a small change that helps your {stroke} here without costing something else."
    return (f"{lead} Even if you {change}, the estimate says {spin} and {speed}. "
            f"That's a stroke rebuild, best done with a coach on court; for now, work on clean contact. Estimates only.")


# ------------------------------------------------------------------------------------------------ conversations

def tool_call(cid, name, args):
    return {"id": cid, "type": "function", "function": {"name": name, "arguments": json.dumps(args, separators=(",", ":"))}}


def conversation(session, catalog, units, question):
    """MuseCoach sends the system prompt and the question; the agent's first move is fetching the digest itself."""
    return [{"role": "system", "content": SYSTEM},
            {"role": "user", "content": question_prompt(question)},
            {"role": "assistant", "content": None, "tool_calls": [tool_call("call_0", "get_session_digest", {})]},
            {"role": "tool", "tool_call_id": "call_0", "content": tool_json(get_session_digest(session, catalog, units))}]


def add_calls(messages, session, units, calls, counter):
    """One assistant turn with parallel simulate_change calls. Returns the tool results."""
    tcs, results = [], []
    for args in calls:
        counter[0] += 1
        tcs.append(tool_call(f"call_{counter[0]}", "simulate_change", args))
        kw = {k: v for k, v in args.items() if k != "session"}
        results.append(simulate_change(session, units, **kw))
    messages.append({"role": "assistant", "content": None, "tool_calls": tcs})
    for tc, r in zip(tcs, results):
        messages.append({"role": "tool", "tool_call_id": tc["id"], "content": tool_json(r)})
    return results


QUESTIONS = {
    "more_spin": ["How can I get more topspin on my {s} without losing pace?", "My {s} feels flat. What one change adds spin?",
                  "What should I change on my {s} to get more spin?"],
    "more_pace": ["How do I hit my {s} harder?", "What's the quickest way to add speed to my {s}?",
                  "My {s} lacks pace. What would you change?"],
    "cleaner_contact": ["I keep mishitting my {s}. What should I fix?", "How do I find the sweet spot more on my {s}?",
                        "Why does my {s} feel off the frame?"],
    "fix_slice": ["My {s} keeps floating with slice. How do I turn it into topspin?",
                  "What change would make my {s} a topspin shot instead of a slice?"],
}

FLAW_OBJECTIVE = {"open_face": "more_spin", "flat_path": "more_spin", "tip_contact": "cleaner_contact",
                  "throat_contact": "cleaner_contact", "side_contact": "cleaner_contact", "slow_swing": "more_pace",
                  "overswing": "cleaner_contact", "none": None}


def example_objective(session, catalog, units, stroke, objective, rng, table, meta):
    question = rng.choice(QUESTIONS[objective]).format(s=stroke)
    messages = conversation(session, catalog, units, question)
    probe = simulate_change(session, units, type=stroke)
    if "error" in probe:
        return error_example(session, catalog, units, stroke, question, rng, meta)
    if objective == "cleaner_contact":
        base = probe["before"]["applied_parameters"]
        if math.hypot(base["contactXcm"], base["contactYcm"]) < CENTERED_CM:
            return example_spread(session, catalog, units, stroke, question, probe, rng, meta)
    rows = search(session, units, stroke, objective)
    for row in rows:
        table.append(table_row(meta, stroke, objective, row, False))
    ok = [r for r in rows if r["rank"] is not None]
    counter = [0]
    if not ok:
        spin_levers = {"face_deg", "path_deg"} if objective in ("more_spin", "fix_slice") else set(DELTA_LIMITS)
        pool = [r for r in rows if set(r["deltas"]) <= spin_levers] or rows
        biggest = max(pool, key=lambda r: (len(r["deltas"]), sum(abs(v) / SCALE[k] for k, v in r["deltas"].items())))
        result = add_calls(messages, session, units, [{"type": stroke, **biggest["deltas"]}], counter)[0]
        messages.append({"role": "assistant", "content": answer_no_gain(stroke, objective, result, units)})
        return messages, {"chosen": None, "levers": []}
    best = max(ok, key=lambda r: r["rank"])
    table[len(table) - len(rows) + rows.index(best)]["chosen"] = 1
    # Show the search a coach would do: the best single change for two different levers, then the combination.
    levers = {}
    for r in sorted(ok, key=lambda r: -r["rank"]):
        if len(r["deltas"]) == 1:
            levers.setdefault(lever(r["deltas"]), r)
    firsts = list(levers.values())[:2]
    if len(best["deltas"]) == 1 and best not in firsts:
        firsts = [best] + firsts[:1]
    add_calls(messages, session, units, [{"type": stroke, **r["deltas"]} for r in firsts], counter)
    if best not in firsts:
        add_calls(messages, session, units, [{"type": stroke, **best["deltas"]}], counter)
    alt = next((r for r in firsts if r is not best), None)
    stroke_digest = next(d for d in digest(session, units)["strokes"] if d["type"] == LABELS[stroke])
    messages.append({"role": "assistant", "content": answer_objective(stroke, objective, best, alt, units, stroke_digest, rng)})
    return messages, {"chosen": best["deltas"], "levers": sorted({lever({k: v}) for k, v in best["deltas"].items()})}


CENTERED_CM = 1.5


def example_spread(session, catalog, units, stroke, question, probe, rng, meta):
    """Average contact is already central: the miss is scatter, which the simulator can't model. Say so."""
    messages = conversation(session, catalog, units, question)
    base = probe["before"]["applied_parameters"]
    full = {"contact_x_cm": round(-base["contactXcm"], 1), "contact_y_cm": round(-base["contactYcm"], 1)}
    r = add_calls(messages, session, units, [{"type": stroke, **full}], [0])[0]
    d = next(x for x in digest(session, units)["strokes"] if x["type"] == LABELS[stroke])
    _, speed = effect(r["before"], r["after"])
    text = (f"Your {stroke} contact is already centered on average, so moving it gains little: the estimate says {speed}. "
            f"The issue is scatter: your hits spread {d['contactSpread']:.1f} {units.length_unit} around that point and "
            f"{d['sweetSpotPercent']}% land in the sweet spot. Cue: {rng.choice(CUES['contact_x_cm'])}, and shorten the "
            f"backswing until {rng.choice([8, 10, 12])} in a row feel clean.")
    messages.append({"role": "assistant", "content": text})
    return messages, {"chosen": r["applied_deltas"], "levers": ["contact"], "kind": "contact_spread"}


def lever(deltas):
    k = list(deltas)[0]
    return "contact" if k.startswith("contact") else k


def example_player_whatif(session, catalog, units, stroke, rng, meta, extreme=False):
    """The player proposes the change; Muse runs exactly that and reports it, noting any clamping."""
    if extreme:
        args = {"swing_percent": float(rng.choice([40, 50, -45])), "face_deg": float(rng.choice([20, -25]))}
    else:
        args = {"face_deg": float(rng.choice([-5, -3, -2, 2, 3, 5])), "swing_percent": float(rng.choice([-10, -5, 5, 10]))}
    words = describe(args, Units(True))
    question = rng.choice([f"What if I {words} on my {stroke}?", f"If I {words} on the {stroke}, what happens?",
                           f"Simulate this for my {stroke}: {words}."])
    messages = conversation(session, catalog, units, question)
    counter = [0]
    r = add_calls(messages, session, units, [{"type": stroke, **args}], counter)[0]
    if "error" in r:
        messages.append({"role": "assistant", "content": no_motion_answer(stroke, rng)})
        return messages, {"chosen": None, "levers": [], "kind": "player_whatif_error"}
    spin, speed = effect(r["before"], r["after"])
    text = f"Estimated for your {stroke}: {spin}, and {speed}."
    clamped = {k: v for k, v in args.items() if r["applied_deltas"][k] != v}
    if clamped:
        text = (f"That's beyond what I can simulate, so I capped it at {describe({k: r['applied_deltas'][k] for k in args}, units)}. "
                + text + " Changes that big would rebuild the stroke; I'd try a smaller step first.")
    elif r["after"]["spin_rpm"] < r["before"]["spin_rpm"] and r["after"]["ball_speed"] < r["before"]["ball_speed"]:
        text += " So on this model it costs you both spin and pace; I wouldn't make that change."
    elif r["after"]["spin_rpm"] > r["before"]["spin_rpm"] and r["after"]["ball_speed"] >= r["before"]["ball_speed"] - 1:
        text += f" That's a gain worth trying. Cue: {cue(r['applied_deltas'], rng)}."
    else:
        text += " It's a trade-off between spin and pace, so pick it if that matches what you want from this shot."
    text += " These are physics estimates, not measured shots."
    messages.append({"role": "assistant", "content": text})
    return messages, {"chosen": r["applied_deltas"], "levers": [], "kind": "player_whatif_extreme" if extreme else "player_whatif"}


def example_unmodeled(session, catalog, units, stroke, rng, meta):
    """Asks about landing depth: run the change, report speed/spin, refuse to claim depth or net clearance."""
    question = rng.choice([f"If I close my face 3° on the {stroke}, will it land deeper?",
                           f"Would swinging 10% faster on my {stroke} clear the net by more?"])
    args = {"face_deg": -3.0} if "face" in question else {"swing_percent": 10.0}
    messages = conversation(session, catalog, units, question)
    r = add_calls(messages, session, units, [{"type": stroke, **args}], [0])[0]
    if "error" in r:
        messages.append({"role": "assistant", "content": no_motion_answer(stroke, rng)})
        return messages, {"chosen": None, "levers": [], "kind": "unmodeled_error"}
    spin, speed = effect(r["before"], r["after"])
    target = "where the ball lands" if "deeper" in question else "net clearance"
    text = (f"I can't predict {target}: the racket model doesn't simulate ball flight. What it does estimate for your "
            f"{stroke}: {spin}, and {speed}. To see where it lands, try it on court against a target. These are "
            f"estimates, not measurements.")
    messages.append({"role": "assistant", "content": text})
    return messages, {"chosen": r["applied_deltas"], "levers": [], "kind": "unmodeled"}


def no_motion_answer(stroke, rng):
    return (f"I can't simulate your {stroke} from this session: its shots were heard by the racket's mic but the motion "
            f"data didn't come through (or the gyro maxed out), so there's no measured swing to start from. Play a few "
            f"{stroke}s with the motion sensors connected and ask again.")


def error_example(session, catalog, units, stroke, question, rng, meta):
    messages = conversation(session, catalog, units, question)
    add_calls(messages, session, units, [{"type": stroke}], [0])
    messages.append({"role": "assistant", "content": no_motion_answer(stroke, rng)})
    return messages, {"chosen": None, "levers": [], "kind": "no_motion"}


def table_row(meta, stroke, objective, row, chosen):
    d, r = row["deltas"], row["result"]
    b, a = r["before"], r["after"]
    return {**meta, "stroke": stroke, "objective": objective,
            **{k: d.get(k, 0.0) for k in DELTA_LIMITS},
            "base_swing_kmh": round(b["applied_parameters"]["swingSpeedKmh"], 2),
            "base_path_deg": round(b["applied_parameters"]["pathAngleDeg"], 2),
            "base_face_deg": round(b["applied_parameters"]["faceAngleDeg"], 2),
            "base_contact_x_cm": round(b["applied_parameters"]["contactXcm"], 2),
            "base_contact_y_cm": round(b["applied_parameters"]["contactYcm"], 2),
            "before_ball": round(b["ball_speed"], 2), "before_spin_rpm": round(b["spin_rpm"], 1), "before_spin": b["spin_type"],
            "after_ball": round(a["ball_speed"], 2), "after_spin_rpm": round(a["spin_rpm"], 1), "after_spin": a["spin_type"],
            "speed_unit": a["speed_unit"], "meets_guardrail": int(row["score"] is not None), "reaches_target": int(row["target"]),
            "rank_score": "" if row["rank"] is None else round(row["rank"], 4), "chosen": int(chosen)}


# ------------------------------------------------------------------------------------------------ main

def split_of(player_id):
    h = int(hashlib.sha256(player_id.encode()).hexdigest(), 16) % 10
    return "test" if h == 0 else "val" if h == 1 else "train"


def generate(priors, out, players=400, seed=7):
    rng, pyrng = np.random.default_rng(seed), random.Random(seed)
    os.makedirs(out, exist_ok=True)
    schemas = tool_schemas()
    files = {s: open(os.path.join(out, f"conversations_{s}.jsonl"), "w") for s in ("train", "val", "test")}
    table, counts = [], {}
    shot_rows, session_rows = [], []
    with open(os.path.join(out, "players.jsonl"), "w") as pf:
        for i in range(players):
            player = make_player(rng, priors, i)
            split = split_of(player["player_id"])
            pf.write(json.dumps({**player, "split": split}, default=float) + "\n")
            units = Units(player["metric"])
            start = datetime(2026, 9, 1, 17, tzinfo=timezone.utc) + timedelta(days=int(rng.integers(0, 50)))
            catalog, conds = [], []
            for _ in range(int(rng.integers(1, 4))):
                session, c = make_session(rng, pyrng, priors, player, start)
                catalog.append(session)
                conds.append(c)
                start += timedelta(days=int(rng.integers(2, 9)), hours=float(rng.uniform(-3, 3)))
            for session, c in zip(catalog, conds):
                meta = {"player_id": player["player_id"], "session_id": session.id, "split": split}
                session_rows.append({**meta, **c, "shots": len(session.shots),
                                     "mic_only": sum(s.mic_only for s in session.shots),
                                     "saturated": sum(s.saturated for s in session.shots)})
                for k, s in enumerate(session.shots):
                    shot_rows.append({"session_id": session.id, "index": k, "type": s.type, "mic_only": int(s.mic_only),
                                      "saturated": int(s.saturated), "swing_kmh": round(s.swing_kmh, 2),
                                      "ball_kmh": round(s.ball_kmh, 2), "spin_rpm": round(s.spin_rpm, 1), "spin": s.spin,
                                      "path_deg": round(s.path_deg, 2), "face_deg": round(s.face_deg, 2),
                                      "x_cm": round(s.x_cm, 2), "y_cm": round(s.y_cm, 2)})
                current = [s for s in catalog if s.start <= session.start]
                for kind, ex_meta in plan_examples(rng, player, session):
                    stroke = ex_meta.get("stroke")
                    if kind == "objective":
                        msgs, info = example_objective(session, current, units, stroke, ex_meta["objective"], rng, table, meta)
                        info.setdefault("kind", "objective")
                    elif kind == "player_whatif":
                        msgs, info = example_player_whatif(session, current, units, stroke, rng, meta)
                    elif kind == "player_whatif_extreme":
                        msgs, info = example_player_whatif(session, current, units, stroke, rng, meta, extreme=True)
                    else:
                        msgs, info = example_unmodeled(session, current, units, stroke, rng, meta)
                    record = {"messages": msgs, "tools": schemas,
                              "metadata": {**meta, **ex_meta, **info, "flaw": player["flaw"], "flaw_stroke": player["flaw_stroke"],
                                           "flaw_found": flaw_found(player, stroke, info), "link": c["link"],
                                           "units": units.speed_unit, "generator_version": VERSION, "seed": seed}}
                    files[split].write(json.dumps(record, ensure_ascii=False) + "\n")
                    counts[info["kind"]] = counts.get(info["kind"], 0) + 1
    for f in files.values():
        f.close()
    write_csv(os.path.join(out, "whatif_table.csv"), table)
    write_csv(os.path.join(out, "shots.csv"), shot_rows)
    write_csv(os.path.join(out, "sessions.csv"), session_rows)
    manifest = {"generator_version": VERSION, "seed": seed, "players": players, "sessions": len(session_rows),
                "shots": len(shot_rows), "whatif_rows": len(table), "examples": counts,
                "priors_sha256": hashlib.sha256(json.dumps(priors, sort_keys=True).encode()).hexdigest()[:16],
                "priors_sources": priors["sources"]}
    with open(os.path.join(out, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=2)
    return manifest


def plan_examples(rng, player, session):
    """Two to three questions per session: the flaw's objective, another objective, and a player-proposed what-if."""
    motion = {s.type for s in session.shots if not s.mic_only}
    strokes = [s for s in ("forehand", "backhand") if any(x.type == s for x in session.shots)] or ["forehand"]
    out = []
    flaw_obj = FLAW_OBJECTIVE[player["flaw"]]
    if flaw_obj and player["flaw_stroke"] in strokes:
        out.append(("objective", {"stroke": player["flaw_stroke"], "objective": flaw_obj}))
    stroke = str(rng.choice(strokes))
    style = player["strokes"][stroke]["style"]
    if style == "slice":
        objective = "fix_slice" if rng.random() < 0.6 else str(rng.choice(["more_pace", "cleaner_contact"]))
    else:
        objective = str(rng.choice(["more_spin", "more_pace", "cleaner_contact"]))
    if (stroke, objective) not in [(m["stroke"], m["objective"]) for _, m in out]:
        out.append(("objective", {"stroke": stroke, "objective": objective}))
    roll = rng.random()
    kind = "player_whatif" if roll < 0.6 else "player_whatif_extreme" if roll < 0.75 else "unmodeled"
    out.append((kind, {"stroke": str(rng.choice(sorted(motion & set(strokes)) or strokes))}))
    return out


def flaw_found(player, stroke, info):
    """Did the chosen change address the injected flaw? None when there was nothing to find."""
    flaw = player["flaw"]
    if flaw == "none" or stroke != player["flaw_stroke"] or not info.get("levers"):
        return None
    want = {"open_face": {"face_deg"}, "flat_path": {"path_deg", "face_deg"}, "tip_contact": {"contact"},
            "throat_contact": {"contact"}, "side_contact": {"contact"}, "slow_swing": {"swing_percent"},
            "overswing": {"contact", "swing_percent"}}[flaw]
    return bool(want & set(info["levers"]))


def write_csv(path, rows):
    with open(path, "w", newline="") as f:
        if not rows:
            return
        w = csv.DictWriter(f, fieldnames=list(rows[0]))
        w.writeheader()
        w.writerows(rows)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("priors", help="summarize the real recordings into ml/whatif_priors.json")
    p.add_argument("--out", default=PRIORS)
    g = sub.add_parser("generate", help="write the synthetic dataset")
    g.add_argument("--out", default=os.path.join(ROOT, "data", "whatif"))
    g.add_argument("--players", type=int, default=400)
    g.add_argument("--seed", type=int, default=7)
    g.add_argument("--priors", default=PRIORS)
    a = ap.parse_args()
    if a.cmd == "priors":
        priors = extract_priors()
        with open(a.out, "w") as f:
            json.dump(priors, f, separators=(",", ":"))
        print(json.dumps(priors["sources"]), "->", a.out)
    else:
        print(json.dumps(generate(json.load(open(a.priors)), a.out, a.players, a.seed), indent=2))


if __name__ == "__main__":
    main()

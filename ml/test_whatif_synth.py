"""Checks for the what-if dataset: python -m unittest discover -s ml -p test_whatif_synth.py

The golden rows come from running apple/RacketKit/Sources/RacketKit/ShotSimulator.swift itself (Swift keeps
acorCenter as a Float, hence the 1e-6 tolerance).
"""
import json
import math
import os
import re
import tempfile
import unittest

from coach_sim import Session, Shot, Units, digest, simulate, simulate_change, swift_round
from whatif_synth import PRIORS, generate

# swing, path, face, x, y, incoming -> ball km/h, rpm, spin (from Swift)
GOLDEN = [
    [110.0, 22.0, 0.0, 0.0, 0.0, 43.2, 174.34399799108505, 2283.9690214951765, "topspin"],
    [95.0, 8.0, 6.0, 3.0, -2.0, 43.2, 145.71917677831607, 183.76587889679664, "flat"],
    [80.0, -12.0, 14.0, -1.0, 4.0, 43.2, 124.2768894053913, 1943.8110890559462, "slice"],
    [150.0, -3.0, -2.0, 0.0, 0.0, 0.0, 212.99999803304672, 145.10042494236785, "flat"],
    [40.0, -5.0, 8.0, 2.0, 2.0, 54.0, 75.57167828842522, 498.73532636811586, "flat"],
    [250.0, 100.0, -70.0, 20.0, -20.0, 300.0, 292.3999971151352, 7125.569809785166, "topspin"],
    [60.0, 10.0, 10.0, 0.0, 0.0, 43.2, 103.34399864673614, 0.0, "flat"],
]


def shot(**kw):
    p, ball, rpm, spin = simulate(kw.get("swing_kmh", 100), kw.get("path_deg", 20), kw.get("face_deg", 0),
                                  kw.get("x_cm", 0), kw.get("y_cm", 0))
    return Shot(type=kw.get("type", "forehand"), swing_kmh=p["swingSpeedKmh"], ball_kmh=ball, spin_rpm=rpm, spin=spin,
                face_deg=p["faceAngleDeg"], path_deg=p["pathAngleDeg"], x_cm=p["contactXcm"], y_cm=p["contactYcm"],
                saturated=kw.get("saturated", False))


def read(path):
    with open(path) as f:
        return f.read()


def numbers(value):
    """Every number in a tool result, plus the length of each contact move (answers describe moves by length)."""
    if isinstance(value, bool):
        return []
    if isinstance(value, (int, float)):
        return [float(value)]
    if isinstance(value, dict):
        extra = [math.hypot(value["contact_x_cm"], value["contact_y_cm"])] if "contact_x_cm" in value else []
        return extra + [n for v in value.values() for n in numbers(v)]
    if isinstance(value, list):
        return [n for v in value for n in numbers(v)]
    return []


class Physics(unittest.TestCase):
    def test_simulate_matches_swift(self):
        for *args, ball, rpm, spin in GOLDEN:
            _, b, r, s = simulate(*args)
            self.assertAlmostEqual(b, ball, delta=ball * 1e-6)
            self.assertAlmostEqual(r, rpm, delta=max(rpm, 1) * 1e-6)
            self.assertEqual(s, spin)

    def test_simulate_change_clamps_like_the_app(self):
        session = Session("S", "2026-10-28T19:00:00Z", 600, [shot(), shot(swing_kmh=120)])
        r = simulate_change(session, Units(), type="forehand", swing_percent=999, face_deg=100)
        self.assertEqual(r["applied_deltas"]["swing_percent"], 30)
        self.assertEqual(r["applied_deltas"]["face_deg"], 15)
        self.assertAlmostEqual(r["after"]["applied_parameters"]["swingSpeedKmh"], 110 * 1.3)
        self.assertTrue(r["estimated"])

    def test_mic_only_and_saturated_shots_give_no_baseline(self):
        session = Session("S", "2026-10-28T19:00:00Z", 600, [Shot.from_mic(True, 0), shot(saturated=True)])
        self.assertIn("error", simulate_change(session, Units(), type="forehand"))
        d = digest(session, Units())
        hit = next(s for s in d["strokes"] if s["type"] == "Hit")
        self.assertIsNone(hit["avgBallSpeed"])
        self.assertEqual(d["motion_shots"], 1)

    def test_rounding_follows_swift(self):
        self.assertEqual(swift_round(2.5), 3)
        self.assertEqual(swift_round(-2.5), -3)
        session = Session("S", "2026-10-28T19:00:00Z", 600, [shot(path_deg=-7.9)])
        self.assertEqual(digest(session, Units())["strokes"][0]["avgPathDeg"], -7)   # Int() truncates

    def test_imperial_units(self):
        session = Session("S", "2026-10-28T19:00:00Z", 600, [shot(y_cm=2.54)])
        d = digest(session, Units(metric=False))
        self.assertEqual((d["speedUnit"], d["lengthUnit"]), ("mph", "in"))
        self.assertAlmostEqual(d["strokes"][0]["avgContactTowardTip"], 1.0)


@unittest.skipUnless(os.path.exists(PRIORS), "run `python3 ml/whatif_synth.py priors` first")
class Dataset(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.priors = json.load(open(PRIORS))
        cls.dir = tempfile.TemporaryDirectory()
        generate(cls.priors, cls.dir.name, players=25, seed=11)
        cls.examples = [json.loads(line) for s in ("train", "val", "test")
                        for line in read(os.path.join(cls.dir.name, f"conversations_{s}.jsonl")).splitlines()]

    @classmethod
    def tearDownClass(cls):
        cls.dir.cleanup()

    def test_reproducible(self):
        with tempfile.TemporaryDirectory() as again:
            generate(self.priors, again, players=25, seed=11)
            for name in ("conversations_train.jsonl", "whatif_table.csv", "shots.csv"):
                self.assertEqual(read(os.path.join(again, name)), read(os.path.join(self.dir.name, name)))

    def test_splits_hold_out_whole_players(self):
        owners = {}
        for e in self.examples:
            owners.setdefault(e["metadata"]["player_id"], set()).add(e["metadata"]["split"])
        self.assertTrue(all(len(s) == 1 for s in owners.values()))

    def test_conversations_follow_the_muse_protocol(self):
        for e in self.examples:
            m = e["messages"]
            self.assertEqual([x["role"] for x in m[:4]], ["system", "user", "assistant", "tool"])
            self.assertEqual(m[2]["tool_calls"][0]["function"]["name"], "get_session_digest")
            self.assertEqual(m[-1]["role"], "assistant")
            self.assertTrue(m[-1]["content"])
            calls = {}
            for x in m:
                for tc in x.get("tool_calls") or []:
                    calls[tc["id"]] = tc
                if x["role"] == "tool":
                    self.assertIn(x["tool_call_id"], calls)
            self.assertLessEqual(sum(1 for x in m if x["role"] == "assistant" and x.get("tool_calls")), 5)

    def test_answers_are_short_and_labeled_estimates(self):
        for e in self.examples:
            text = e["messages"][-1]["content"]
            self.assertLessEqual(len(text.split()), 80, text)
            self.assertRegex(text.lower(), r"estimate|can't simulate", text)
            self.assertNotRegex(text, r"[a-z]+_[a-z_]+|[a-z]+[A-Z][a-zA-Z]+", text)   # no JSON field names

    def test_answers_only_cite_tool_numbers(self):
        for e in self.examples:
            pool = []
            for x in e["messages"]:
                if x["role"] == "tool":
                    pool += numbers(json.loads(x["content"]))
            text = e["messages"][-1]["content"]
            for raw in re.findall(r"\d[\d,]*(?:\.\d+)?", text):
                n = float(raw.replace(",", ""))
                ok = any(abs(abs(v) - n) < 0.051 or round(abs(v)) == n or round(v, -1) == n for v in pool)
                self.assertTrue(ok, f"{raw} not in tool results: {text}")

    def test_what_if_table_matches_conversations(self):
        import csv
        rows = list(csv.DictReader(read(os.path.join(self.dir.name, "whatif_table.csv")).splitlines()))
        chosen = [r for r in rows if r["chosen"] == "1"]
        objective = [e for e in self.examples if e["metadata"]["kind"] == "objective" and e["metadata"]["chosen"]]
        self.assertEqual(len(chosen), len(objective))
        self.assertTrue(all(r["meets_guardrail"] == "1" for r in chosen))


if __name__ == "__main__":
    unittest.main()

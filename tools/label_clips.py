#!/usr/bin/env python3
"""Label a recorded session (tools/collect_clips.py --batch) from your video review.

    python3 tools/label_clips.py data/impacts/session-20261027-153000.csv

For each clip, watch the Nth thump in the video and enter where the ball landed on the string bed, in cm from the
sweet-spot centre: "x y" (x to the right, y toward the racket tip, as seen from the video), or a single number
if you only know the distance. Enter = same as last, 's' = skip for now, 'd' = discard (double trigger, floor
bounce, frame/other noise), 'b' = back one, 'q' = save and quit. Progress is saved after every clip, so you can
stop and resume. Output: labels.csv (file,dist_cm) for ml/train.py plus positions.csv (file,x_cm,y_cm).
"""
import csv
import math
import os
import sys


def load(path, default):
    if not os.path.exists(path):
        return default
    return {r[0]: r[1:] for r in csv.reader(open(path)) if r and r[0] != "file"}


def write_all(folder, labels, pos):
    with open(os.path.join(folder, "labels.csv"), "w") as f:
        f.write("file,dist_cm\n")
        for k, v in labels.items():
            f.write(f"{k},{v[0]}\n")
    with open(os.path.join(folder, "positions.csv"), "w") as f:
        f.write("file,x_cm,y_cm\n")
        for k, v in pos.items():
            f.write(f"{k},{v[0]},{v[1]}\n")


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    folder = os.path.dirname(os.path.abspath(sys.argv[1]))
    clips = [r for r in csv.DictReader(open(sys.argv[1]))]
    labels = load(os.path.join(folder, "labels.csv"), {})
    pos = load(os.path.join(folder, "positions.csv"), {})
    discarded_path = os.path.join(folder, "discarded.txt")
    discarded = set(open(discarded_path).read().split()) if os.path.exists(discarded_path) else set()

    i, last = 0, "0 0"
    while i < len(clips):
        c = clips[i]
        f = c["file"]
        done = "labelled" if f in labels else "discarded" if f in discarded else ""
        if done and "--redo" not in sys.argv:
            i += 1
            continue
        ans = input(f"#{c['n']} t={c['t_s']}s {c['verdict']}\n  position cm [{last}]: ").strip().lower() or last
        if ans == "q":
            break
        if ans == "b":
            i = max(0, i - 1)
            labels.pop(clips[i]["file"], None); pos.pop(clips[i]["file"], None)
            continue
        if ans == "s":
            i += 1
            continue
        if ans == "d":
            discarded.add(f)
            open(discarded_path, "w").write("\n".join(sorted(discarded)))
            i += 1
            continue
        try:
            v = [float(t) for t in ans.replace(",", " ").split()]
            if len(v) == 1:
                dist, xy = abs(v[0]), (float("nan"), float("nan"))
            elif len(v) == 2:
                dist, xy = math.hypot(*v), (v[0], v[1])
            else:
                raise ValueError
        except ValueError:
            print("  enter 'x y', a distance, s, d, b or q")
            continue
        last = ans
        labels[f] = [f"{dist:.2f}"]
        pos[f] = [f"{xy[0]:.2f}", f"{xy[1]:.2f}"]
        write_all(folder, labels, pos)
        i += 1
    write_all(folder, labels, pos)
    print(f"{len(labels)} labelled clips in {folder}/labels.csv")


if __name__ == "__main__":
    main()

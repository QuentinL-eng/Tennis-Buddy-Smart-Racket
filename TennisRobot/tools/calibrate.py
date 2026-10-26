#!/usr/bin/env python3
"""Camera calibration for TennisRobot.

Intrinsics from chessboard images:

    python3 tools/calibrate.py intrinsics --images "calib/*.jpg" \\
        --cols 9 --rows 6 --square 0.025 --out calib/intrinsics.json

Camera pose from known world points (metres) and their pixels:

    python3 tools/calibrate.py pose --intrinsics calib/intrinsics.json \\
        --points calib/world_points.json

``world_points.json`` is::

    {"world": [[x, y, z], ...], "pixels": [[u, v], ...]}

Use at least six points that are not all on one plane.  The output pose is the
camera-to-world transform to paste into ``config/uno_q.toml``.
"""

from __future__ import annotations

import argparse
import glob
import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from tennisrobot.geometry import Transform  # noqa: E402


def _require_cv2():
    try:
        import cv2
    except ImportError as exc:
        raise SystemExit("OpenCV is required: pip install opencv-python") from exc
    return cv2


def _intrinsics(args: argparse.Namespace) -> int:
    cv2 = _require_cv2()
    paths = sorted(glob.glob(args.images))
    if not paths:
        raise SystemExit(f"no images matched {args.images!r}")
    pattern = (args.cols, args.rows)
    object_point = np.zeros((args.cols * args.rows, 3), np.float32)
    object_point[:, :2] = np.mgrid[0 : args.cols, 0 : args.rows].T.reshape(-1, 2) * args.square

    object_points = []
    image_points = []
    shape = None
    for path in paths:
        image = cv2.imread(path, cv2.IMREAD_GRAYSCALE)
        if image is None:
            print(f"skip (unreadable): {path}")
            continue
        shape = image.shape[::-1]
        found, corners = cv2.findChessboardCornersSB(
            image, pattern, flags=cv2.CALIB_CB_EXHAUSTIVE | cv2.CALIB_CB_ACCURACY
        )
        if not found:
            found, corners = cv2.findChessboardCorners(image, pattern, None)
            if found:
                corners = cv2.cornerSubPix(
                    image,
                    corners,
                    (5, 5),
                    (-1, -1),
                    (cv2.TERM_CRITERIA_EPS + cv2.TERM_CRITERIA_MAX_ITER, 30, 1e-3),
                )
        if not found:
            print(f"skip (no {args.cols}x{args.rows} board): {path}")
            continue
        object_points.append(object_point.copy())
        image_points.append(corners.reshape(-1, 1, 2))
        print(f"ok: {path}")

    if len(object_points) < 5:
        raise SystemExit(f"need at least 5 usable images, got {len(object_points)}")
    assert shape is not None
    rms, matrix, distortion, _rvecs, _tvecs = cv2.calibrateCamera(
        object_points, image_points, shape, None, None
    )
    flat = distortion.reshape(-1)
    k1, k2, p1, p2 = (float(value) for value in flat[:4])
    result = {
        "fx": float(matrix[0, 0]),
        "fy": float(matrix[1, 1]),
        "cx": float(matrix[0, 2]),
        "cy": float(matrix[1, 2]),
        "distortion": [k1, k2, p1, p2],
        "rms_px": float(rms),
    }
    print()
    print(f"reprojection RMS: {rms:.3f} px over {len(object_points)} images")
    print("Paste into [camera]:")
    print(f"  fx = {result['fx']:.3f}")
    print(f"  fy = {result['fy']:.3f}")
    print(f"  cx = {result['cx']:.3f}")
    print(f"  cy = {result['cy']:.3f}")
    print(f"  distortion = [{k1:.6f}, {k2:.6f}, {p1:.6f}, {p2:.6f}]")
    if args.out:
        Path(args.out).parent.mkdir(parents=True, exist_ok=True)
        Path(args.out).write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
        print(f"written {args.out}")
    return 0


def _pose(args: argparse.Namespace) -> int:
    cv2 = _require_cv2()
    intrinsics = json.loads(Path(args.intrinsics).read_text(encoding="utf-8"))
    points = json.loads(Path(args.points).read_text(encoding="utf-8"))
    world = np.asarray(points["world"], dtype=float).reshape(-1, 3)
    pixels = np.asarray(points["pixels"], dtype=float).reshape(-1, 2)
    if len(world) != len(pixels) or len(world) < 4:
        raise SystemExit("need at least four world/pixel pairs of equal length")
    matrix = np.array(
        [
            [intrinsics["fx"], 0.0, intrinsics["cx"]],
            [0.0, intrinsics["fy"], intrinsics["cy"]],
            [0.0, 0.0, 1.0],
        ]
    )
    distortion = np.asarray(intrinsics.get("distortion", [0, 0, 0, 0]), dtype=float)
    ok, rvec, tvec, inliers = cv2.solvePnPRansac(
        world, pixels, matrix, distortion, flags=cv2.SOLVEPNP_ITERATIVE
    )
    if not ok:
        raise SystemExit("solvePnP failed")
    rotation_world_from_camera, _ = cv2.Rodrigues(rvec)
    # solvePnP gives p_camera = R p_world + t; the config wants the camera pose
    # in world coordinates, so invert.
    camera_position = (-rotation_world_from_camera.T @ tvec).reshape(3)
    camera_rotation = rotation_world_from_camera.T
    pose = Transform(camera_rotation, camera_position).pose6()
    print(f"inliers: {len(inliers) if inliers is not None else len(world)}/{len(world)}")
    print("Paste into [camera] as:")
    print("  pose = [" + ", ".join(f"{value:.4f}" for value in pose) + "]")
    print("  # look_at must be removed when pose is set")
    if args.out:
        Path(args.out).parent.mkdir(parents=True, exist_ok=True)
        Path(args.out).write_text(
            json.dumps({"pose": list(pose), "inliers": len(inliers) if inliers is not None else len(world)}, indent=2)
            + "\n",
            encoding="utf-8",
        )
        print(f"written {args.out}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="mode", required=True)

    intrinsics = sub.add_parser("intrinsics", help="chessboard intrinsics")
    intrinsics.add_argument("--images", required=True, help="glob, e.g. 'calib/*.jpg'")
    intrinsics.add_argument("--cols", type=int, required=True, help="inner corners across")
    intrinsics.add_argument("--rows", type=int, required=True, help="inner corners down")
    intrinsics.add_argument("--square", type=float, required=True, help="square size in metres")
    intrinsics.add_argument("--out", help="write JSON summary here")
    intrinsics.set_defaults(func=_intrinsics)

    pose = sub.add_parser("pose", help="camera pose from known world points")
    pose.add_argument("--intrinsics", required=True)
    pose.add_argument("--points", required=True)
    pose.add_argument("--out", help="write JSON summary here")
    pose.set_defaults(func=_pose)

    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())

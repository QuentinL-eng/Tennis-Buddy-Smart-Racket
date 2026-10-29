"""Check an exported trajectory; does not establish that its source is actual data."""
import argparse
import csv
import math
import statistics
import sys

FIELDS = ['time_s', *[f'j{i}_rad' for i in range(1, 7)],
          'tcp_x_m', 'tcp_y_m', 'tcp_z_m', 'qw', 'qx', 'qy', 'qz']


def check(path):
    with open(path, newline='', encoding='utf-8-sig') as f:
        reader = csv.DictReader(f)
        if reader.fieldnames != FIELDS:
            raise ValueError('Expected columns: ' + ','.join(FIELDS))
        rows = []
        for line, row in enumerate(reader, 2):
            try:
                values = [float(row[k]) for k in FIELDS]
            except (TypeError, ValueError) as exc:
                raise ValueError(f'Invalid value on line {line}') from exc
            if not all(math.isfinite(v) for v in values):
                raise ValueError(f'Non-finite value on line {line}')
            if abs(sum(v*v for v in values[-4:]) - 1) > 0.002:
                raise ValueError(f'Quaternion not unit length on line {line}')
            rows.append(values)
    if len(rows) < 2:
        raise ValueError('At least two samples are required')
    intervals = [b[0] - a[0] for a, b in zip(rows, rows[1:])]
    if min(intervals) <= 0:
        raise ValueError('Timestamps must strictly increase')
    duration = rows[-1][0] - rows[0][0]
    print(f'{len(rows)} samples; {duration:.3f} s; mean {(len(rows)-1)/duration:.1f} Hz; '
          f'median interval {statistics.median(intervals)*1000:.2f} ms; '
          f'max gap {max(intervals)*1000:.2f} ms; gaps >10 ms: '
          f'{sum(dt > 0.0100001 for dt in intervals)}')
    tcp_speeds = []
    angular_speeds = []
    joint_speeds = [[] for _ in range(6)]
    for a, b, dt in zip(rows, rows[1:], intervals):
        tcp_speeds.append(math.sqrt(sum((b[i] - a[i])**2 for i in range(7, 10))) / dt)
        # q and -q encode the same orientation; normalize for numerical stability.
        qa, qb = a[10:14], b[10:14]
        na = math.sqrt(sum(v*v for v in qa))
        nb = math.sqrt(sum(v*v for v in qb))
        dot = min(1.0, abs(sum(x*y for x, y in zip(qa, qb)) / (na * nb)))
        angular_speeds.append(math.degrees(2 * math.acos(dot)) / dt)
        for i in range(6):
            joint_speeds[i].append(math.degrees(abs(b[i+1] - a[i+1])) / dt)
    print(f'Peak finite-difference TCP speed: {max(tcp_speeds):.3f} m/s; '
          f'orientation speed: {max(angular_speeds):.1f} deg/s')
    print('Peak joint speeds deg/s: ' + ', '.join(f'J{i+1} {max(s):.1f}'
                                                    for i, s in enumerate(joint_speeds)))
    print('Peaks are sample-dependent estimates; unwrap joint angles before analysis and inspect gaps and noise.')
    print('Verify source, frame, timestamps and event times separately; cadence alone does not prove actual motion.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('csv_file')
    args = parser.parse_args()
    try:
        check(args.csv_file)
    except (OSError, ValueError, csv.Error) as exc:
        print(f'FAILED: {exc}', file=sys.stderr)
        sys.exit(1)

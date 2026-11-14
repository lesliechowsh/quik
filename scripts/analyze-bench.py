#!/usr/bin/env python3
"""Compare experience latency and verdicts across the three bench segments."""
import re
import statistics
import sys

PATTERN = re.compile(r"level=(\d+) score=(\d+) busy=(\d+)% jank95=([\d.]+) baseline=([\d.]+)")


def load(path):
    rows = []
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            match = PATTERN.search(line)
            if match:
                rows.append({
                    "level": int(match.group(1)),
                    "score": int(match.group(2)),
                    "busy": int(match.group(3)),
                    "jank": float(match.group(4)),
                    "baseline": float(match.group(5)),
                })
    # Each segment file is a full copy of the log, so keep only the tail that
    # belongs to that segment.
    return rows[-10:]


def stats(rows, key):
    values = [row[key] for row in rows]
    if not values:
        return (0, 0, 0)
    ordered = sorted(values)
    p95 = ordered[max(0, int((len(ordered) - 1) * 0.95))]
    return (statistics.median(values), p95, max(values))


def main():
    if len(sys.argv) != 4:
        print("usage: analyze-bench.py baseline load recovery", file=sys.stderr)
        return 2
    names = ["baseline", "load", "recovery"]
    data = {name: load(path) for name, path in zip(names, sys.argv[1:])}

    print(f"{'segment':<10} {'n':>4} {'jank med':>9} {'jank p95':>9} {'jank max':>9} "
          f"{'score med':>10} {'busy med':>9} {'non-fluid':>10}")
    for name in names:
        rows = data[name]
        if not rows:
            print(f"{name:<10} no samples")
            continue
        jank_med, jank_p95, jank_max = stats(rows, "jank")
        score_med, _, _ = stats(rows, "score")
        busy_med, _, _ = stats(rows, "busy")
        non_fluid = sum(1 for row in rows if row["level"] > 0) / len(rows)
        print(f"{name:<10} {len(rows):>4} {jank_med:>9.1f} {jank_p95:>9.1f} {jank_max:>9.1f} "
              f"{score_med:>10.0f} {busy_med:>8.0f}% {non_fluid:>9.0%}")

    if not data["baseline"] or not data["load"]:
        print("FAIL: missing baseline or load samples")
        return 1

    base_jank = statistics.median(row["jank"] for row in data["baseline"])
    load_jank = statistics.median(row["jank"] for row in data["load"])
    obase = max(base_jank, 1.0)
    ratio = load_jank / obase
    base_busy = statistics.median(row["busy"] for row in data["baseline"])
    load_busy = statistics.median(row["busy"] for row in data["load"])
    load_score = statistics.median(row["score"] for row in data["load"])
    load_alert = sum(1 for row in data["load"] if row["level"] > 0) / len(data["load"])

    print()
    print(f"busy rise: {load_busy - base_busy:+.0f} points")
    print(f"load score median: {load_score:.0f}")
    print(f"load segment flagged non-fluid: {load_alert:.0%}")
    print(f"latency ratio load/baseline: {ratio:.2f}x (expected near 1, QoS protects interaction)")

    ok = load_busy - base_busy >= 30 and load_score >= 40 and load_alert >= 0.5
    if data["recovery"]:
        recover_jank = statistics.median(row["jank"] for row in data["recovery"])
        recovered = data["recovery"][-1]["level"] == 0
        print(f"recovery latency / baseline: {recover_jank / obase:.2f}x")
        print(f"recovery ended fluid: {'yes' if recovered else 'no'}")
        ok = ok and recovered

    print("RESULT:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())

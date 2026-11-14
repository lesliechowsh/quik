#!/usr/bin/env python3
"""Count display changes in a QUIK_DEBUG log."""
import re
import sys

path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/quik-debug.log"
rows = []
for line in open(path):
    m = re.search(r"level=(\d+) score=(\d+)", line)
    if not m:
        continue
    top = re.search(r"top=\[(.*?)\]", line)
    first = top.group(1).split(" | ")[0] if top and top.group(1) else ""
    pid = re.search(r"pid=(\d+)", first)
    cause = re.search(r"causes=\[([^:\]]+)", line)
    stable = re.search(r"stable=([a-z-]+)", line)
    rows.append((int(m.group(1)), int(m.group(2)), pid.group(1) if pid else "", cause.group(1) if cause else "", stable.group(1) if stable else ""))

level = [r[0] for r in rows]
score = [r[1] for r in rows]
top = [r[2] for r in rows]
cause = [r[3] for r in rows]
stable = [r[4] for r in rows]


def flips(values):
    return sum(1 for a, b in zip(values, values[1:]) if a != b)


def runs(values):
    return sum(1 for a, b in zip(values, values[1:]) if a != b) + (1 if values else 0)


print(f"samples={len(rows)}")
print(f"level_flips={flips(level)} level_runs={runs(level)} levels={sorted(set(level))}")
print(f"score_flips={flips(score)} distinct_scores={len(set(score))}")
print(f"top_culprit_flips={flips(top)} distinct_top={len(set(top))}")
print(f"top_cause_flips={flips(cause)} distinct_causes={len(set(cause))}")
print(f"stable_cause_flips={flips(stable)} distinct_stable={sorted(set(stable))}")
if rows:
    print(f"minutes={len(rows) / 60:.1f} flips_per_minute={(flips(level) + flips(score) + flips(top) + flips(stable)) / max(len(rows) / 60, 1 / 60):.1f}")

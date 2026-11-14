#!/usr/bin/env python3
"""Adds up scripted discussions over several runs.

    mac/scripts/tally.py runs/2026-11-12T18-*          the runs named
    mac/scripts/tally.py --last 6                      the six newest runs that hold a discussion

For each line of the script: in how many runs Stand spoke after it, and whether that is
what the script expects. One run says little: these behaviours vary from run to run.
"""
import glob
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def main():
    args = sys.argv[1:]
    if args[:1] == ["--last"]:
        found = sorted(glob.glob(os.path.join(ROOT, "runs", "*", "discussion.json")))
        files = found[-int(args[1]):]
    else:
        files = [os.path.join(a, "discussion.json") if os.path.isdir(a) else a for a in args]
    runs = [json.load(open(f)) for f in files if os.path.exists(f)]
    if not runs:
        sys.exit("no runs with a discussion.json")

    lines = max(len(r["lines"]) for r in runs)
    judged = right = 0
    print(f"{len(runs)} runs of {runs[0]['script']}")
    print(f"{'':3} {'should':7} {'spoke':>7}  {'after':>6}  line")
    for i in range(lines):
        rows = [r["lines"][i] for r in runs if i < len(r["lines"])]
        first = rows[0]
        spoke = sum(1 for row in rows if row["spoke"])
        ok = [row["ok"] for row in rows if "ok" in row]
        judged += len(ok)
        right += sum(ok)
        waits = [row["after"] for row in rows if row["spoke"] and "after" in row]
        after = f"{sum(waits) / len(waits):.1f} s" if waits else ""
        flag = "" if not ok or all(ok) else f"  <-- {len(ok) - sum(ok)} of {len(ok)} not as expected"
        print(f"{i + 1:2}. {first['expect']:7} {spoke:>3}/{len(rows):<3}  {after:>6}  {first['voice']}: {first['say'][:70]}{flag}")
    total = lambda key: sum(r.get(key, 0) for r in runs)
    print(f"\nas expected: {right} of {judged} judged lines ({100 * right / max(judged, 1):.0f}%)")
    print(f"chose to say nothing {total('keptQuiet')} times; stray words not played {total('swallowed')}; "
          f"cut off while speaking {total('interrupted')}; began while someone was talking {total('talkedOver')}")
    print(f"cost about ${sum(float(r.get('cost', 0)) for r in runs):.2f}")
    if "--said" in args:
        for i in range(lines):
            for n, r in enumerate(runs):
                if i < len(r["lines"]) and r["lines"][i]["said"]:
                    print(f"\n[{i + 1}] run {n + 1}: {r['lines'][i]['said']}")


if __name__ == "__main__":
    main()

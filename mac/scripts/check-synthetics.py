#!/usr/bin/env python3
"""Check Stand -> actual Floor -> fake headless model on temporary employee homes.

Usage: python3 mac/scripts/check-synthetics.py --synthetics-source /path/to/synthetics
Build first with `swift build --package-path mac`. No real model, audio hardware or live home.
"""
import argparse
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys
import tempfile
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--synthetics-source", type=Path, required=True)
    parser.add_argument("--binary", type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    source = args.synthetics_source.resolve()
    if not (source / "synthetics" / "floor.py").is_file():
        parser.error("--synthetics-source must hold the maintained Synthetics package")
    binary = (args.binary or root / "mac/.build/debug/Stand").resolve()
    env = {k: v for k, v in os.environ.items() if not k.startswith(("STAND_", "SYNTHETICS_"))}
    env.update(PYTHONPATH=str(source), STAND_PROJECT_ROOT=str(root))

    def run(command, **kwargs):
        result = subprocess.run([str(x) for x in command], env=env, cwd=str(root),
                                capture_output=True, text=True, timeout=30, **kwargs)
        if result.returncode:
            raise RuntimeError("Command failed: %s\n%s\n%s" % (command[0], result.stdout, result.stderr))
        return result

    refused = subprocess.run([str(binary), "--probe", "synthetics", "--expect-session-refusal"],
                             env=dict(env, SYNTHETICS_SESSION_RUN="fixture-running-session"), cwd=root,
                             capture_output=True, text=True, timeout=10)
    if refused.returncode:
        raise RuntimeError(refused.stdout + refused.stderr)
    print(refused.stdout, end="")

    with tempfile.TemporaryDirectory(prefix="stand-floor-acceptance-") as temp:
        folder = Path(temp)
        home = folder / "employee"
        key = folder / "stand.key"
        key.write_text(secrets.token_hex(32) + "\n")
        key.chmod(0o600)
        cli = [sys.executable, "-m", "synthetics", "--home", home]
        run(cli + ["init", "--name", "Aster", "--role", "engineer", "--human", "owner"])
        run(cli + ["channel", "register", "stand", "--source-prefix", "stand:", "--key-file", key])
        fake = folder / "fixture-claude"
        fake.write_text("#!" + sys.executable + "\n" + '''import json,sys,time
for raw in sys.stdin:
    item=json.loads(raw)
    text=item.get("message",{}).get("content","")
    if "slow fixture request" in str(text): time.sleep(0.5)
    print(json.dumps({"type":"result","result":"I am Aster, the engineer. This answer came from the fixture employee.","total_cost_usd":0}),flush=True)
''')
        fake.chmod(0o700)
        state = {"policy": {}, "effective": {"brain": "claude", "claude": str(fake), "model": "fixture", "budget": 100}}
        (home / "runtime.state.json").write_text(json.dumps(state))
        probe = [binary, "--probe", "synthetics", "--floor-python", sys.executable,
                 "--floor-home", home, "--floor-key", key, "--fixture-python", sys.executable]
        print(run(probe + ["--expect-refused"]).stdout, end="")
        (home / "floor.json").write_text('{"enabled": true}\n')
        print(run(probe).stdout, end="")
        # Wait for Floor's normal end, model stop, wrap feed and idle-hold release.
        inspect = '''import json,sys
from pathlib import Path
from synthetics.store import Store
from synthetics import floorjournal
with Store(Path(sys.argv[1])) as s:
    wraps=[e for e in s.event_search() if e.get("source")=="stand:meeting"]
    if len(wraps)!=1: raise SystemExit(3)
    body=json.loads(wraps[0]["body"])
    lines=floorjournal.lines(s.home,body["meeting"])
    assert floorjournal.verify(s.home,body["meeting"],body["head"])["chain"]=="chain_ok"
    assert s.meeting_pending() is None and s._hold_row() is None
    assert all(r["status"]!="running" for r in s.run_list())
    assert any(l["op"]=="heard" and l["speaker"]=="room-unidentified" for l in lines)
    assert any(l["op"]=="note" and l["speaker"]=="human-panel" for l in lines)
    assert any(l["op"]=="spoken" and l["speaker"]=="employee-played" for l in lines)
    assert any(l["op"]=="spoken" and l["speaker"]=="employee-generated-unplayed" for l in lines)
    assert any(l["op"]=="cancelled" for l in lines)
    assert lines[-1]["op"]=="end"
    print("PASS actual Floor: anchored journal, speaker classes, cancellation, wrap input, ended run and released idle hold")
'''
        for _ in range(100):
            result = subprocess.run([sys.executable, "-c", inspect, str(home)], env=env,
                                    capture_output=True, text=True, timeout=10)
            if result.returncode == 0:
                print(result.stdout, end="")
                break
            if result.returncode != 3:
                raise RuntimeError(result.stderr)
            time.sleep(0.05)
        else:
            raise RuntimeError("Floor did not finish its normal end/wrap in time")
    print("PASS scratch homes only; zero real model or audio calls")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Compare ordinary Stand instruction bytes against a Git baseline, with no model calls.

Builds two isolated control packages. XCTest is not needed (the macOS CLT lacks it).
Usage: python3 mac/scripts/check-synthetics-compat.py [--base origin/main]
"""
import argparse
import concurrent.futures
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile


CHECK = r'''
import Foundation
import CryptoKit
import StandCore
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
var values = [String: String]()
for mode in ["default", "auto", "api", "claudeCode"] {
    let config = root.appendingPathComponent("brain.json")
    if mode == "default" { try? FileManager.default.removeItem(at: config) }
    else { try JSONSerialization.data(withJSONObject: ["connectionMode": mode]).write(to: config) }
    for talk in ["", "talks/introducing-stand.md"] {
        for lookup in [false, true] { for human in [false, true] { for screen in [false, true] {
            for outline in [nil, "A fixture outline"] as [String?] {
                let text = try Project.instructions(root: root, talk: talk, brief: "Fixture meeting brief.",
                    canLookUp: lookup, notesOutline: outline, canAskHuman: human, screen: screen)
                let key = "\(mode)|\(talk)|\(lookup)|\(human)|\(screen)|\(outline ?? "none")"
                values[key] = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
            }
        } } }
    }
}
let data = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
print(String(decoding: data, as: UTF8.self))
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", default="origin/main")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    base = subprocess.check_output(["git", "rev-parse", args.base], cwd=root, text=True).strip()
    folder = Path(tempfile.mkdtemp(prefix="stand-instructions-compat-"))
    archive = folder / "base.tar"
    with archive.open("wb") as handle:
        subprocess.run(["git", "archive", base], cwd=root, stdout=handle, check=True)
    original = folder / "base"
    original.mkdir()
    # This is the local repository's own tracked archive, not a downloaded archive.
    with tarfile.open(archive) as tar:
        tar.extractall(original)
    current = folder / "current"
    current.mkdir()
    names = subprocess.check_output(["git", "ls-files", "--cached", "--others", "--exclude-standard"], cwd=root, text=True)
    for name in names.splitlines():
        if not (name.startswith(("mac/Sources/", "identity/", "prompts/", "talks/")) or name == "mac/Package.swift"):
            continue
        source = root / name
        if not source.is_file():
            continue
        target = current / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
    for tree in (original, current):
        package = tree / "mac/Package.swift"
        text = package.read_text()
        anchor = '.executableTarget(name: "Stand", dependencies: ["StandCore"], path: "Sources/Stand"),'
        if anchor not in text:
            raise RuntimeError("Package layout changed; update the compatibility driver")
        package.write_text(text.replace(anchor, anchor + '\n        .executableTarget(name: "InstructionsCheck", dependencies: ["StandCore"]),'))
        helper = tree / "mac/Sources/InstructionsCheck/main.swift"
        helper.parent.mkdir(parents=True)
        helper.write_text(CHECK)
    env = {k: v for k, v in os.environ.items() if not k.startswith(("STAND_", "SYNTHETICS_"))}

    def run(tree):
        result = subprocess.run(["swift", "run", "--package-path", str(tree / "mac"), "InstructionsCheck", str(tree)],
                                env=env, cwd=tree, capture_output=True, text=True, timeout=180)
        (folder / (tree.name + ".build.log")).write_text(result.stderr)
        if result.returncode:
            raise RuntimeError("Compatibility control failed; see " + str(folder))
        values = json.loads(result.stdout)
        (folder / (tree.name + ".json")).write_text(json.dumps(values, indent=2) + "\n")
        return values

    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        before, after = list(pool.map(run, (original, current)))
    different = sorted(key for key in set(before) | set(after) if before.get(key) != after.get(key))
    report = {"base": base, "variants": len(after), "different": different, "artifacts": str(folder)}
    (folder / "result.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    if different:
        raise SystemExit(1)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Fail closed on dependency advisories, license/source policy and unpinned actions."""
from pathlib import Path
import json
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
REPORTS = ROOT / "security-reports"


def run(arguments, name):
    result = subprocess.run(arguments, cwd=ROOT, text=True, encoding="utf-8", capture_output=True)
    (REPORTS / name).write_text(result.stdout if name.endswith(".json") else result.stdout + result.stderr, encoding="utf-8")
    if name.endswith(".json"):
        (REPORTS / (name + ".stderr.log")).write_text(result.stderr, encoding="utf-8")
    print(result.stdout, end="")
    print(result.stderr, end="", file=sys.stderr)
    if result.returncode:
        raise SystemExit(result.returncode)


def main():
    REPORTS.mkdir(exist_ok=True)
    for path in sorted((ROOT / ".github/workflows").glob("*.yml")):
        for action in re.findall(r"uses:\s*([^\s#]+)", path.read_text()):
            if action.startswith("./"):
                continue
            if not re.fullmatch(r"[^@]+@[0-9a-f]{40}", action):
                raise SystemExit(f"Unpinned third-party action in {path.name}: {action}")
    for label, manifest in [
        ("core", "core/Cargo.toml"),
        ("node", "bindings/node/native/Cargo.toml"),
        ("python", "bindings/python/Cargo.toml"),
    ]:
        lock = str(Path(manifest).with_name("Cargo.lock"))
        run(["cargo", "audit", "--file", lock, "--json"], f"cargo-audit-{label}.json")
        run(["cargo", "deny", "--manifest-path", manifest, "--config", str(ROOT / "deny.toml"),
             "--locked", "check", "advisories", "licenses", "bans", "sources", "--show-stats"],
            f"cargo-deny-{label}.log")
    run(["npm", "--prefix", "bindings/node", "ci", "--ignore-scripts"], "npm-install.log")
    run(["npm", "--prefix", "bindings/node", "audit", "--omit=dev", "--json"], "npm-audit.json")
    output = REPORTS / "pip-audit-export.json"
    run(["pip-audit", "--requirement", "model/export/requirements.txt", "--format", "json",
         "--progress-spinner", "off", "--output", str(output)], "pip-audit-export.log")
    report = json.loads(output.read_text())
    skipped = [d for d in report["dependencies"] if d.get("skip_reason") or d.get("skipped_reason")]
    if skipped:
        raise SystemExit("Export audit skipped a dependency; resolve it rather than waiving it")
    print("SUPPLY CHAIN PASS: all three Cargo locks, license/source policy, npm production, export Python graph, action pins")


if __name__ == "__main__":
    main()

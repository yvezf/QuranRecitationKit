#!/usr/bin/env python3
"""Compare deterministic acoustic-fixture receipts; this is not a classroom benchmark."""
import argparse
import json
from pathlib import Path


def read_receipts(path):
    cases = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        marker = "RECALL_CASE "
        if marker not in line:
            continue
        item, _ = json.JSONDecoder().raw_decode(line.split(marker, 1)[1])
        key = (item["case"], item["window_seconds"])
        if key in cases:
            raise ValueError(f"Duplicate fixture receipt: {key}")
        cases[key] = item
    if not cases:
        raise ValueError(f"No fixture receipts: {path}")
    return cases


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--before", type=Path, required=True)
    parser.add_argument("--after", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    before, after = read_receipts(args.before), read_receipts(args.after)
    if before.keys() != after.keys():
        raise ValueError("Before/after logs must contain the identical fixture conditions")
    rows = []
    for key in sorted(after):
        a, b = before[key], after[key]
        if a["expected"] != b["expected"]:
            raise ValueError("Fixture expectations changed")
        if b["matched"] != b["expected"] or b["matched"] < a["matched"] or b["false_positives"]:
            raise ValueError(f"Fixture gate failed: {key}")
        rows.append({"case": key[0], "window_seconds": key[1], "expected": b["expected"],
                     "before_matched": a["matched"], "after_matched": b["matched"],
                     "before_false_positives": a["false_positives"],
                     "after_false_positives": b["false_positives"],
                     "before_events": len(a["quotes"]), "after_events": len(b["quotes"])})
    report = {"method": "identical synthetic posteriors, runtime corpus/tokenizer, unchanged acceptance thresholds",
              "classroom_precision_recall": "unmeasured", "cases": rows}
    encoded = json.dumps(report, indent=2) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(encoded, encoding="utf-8")
    print(encoded, end="")


if __name__ == "__main__":
    main()

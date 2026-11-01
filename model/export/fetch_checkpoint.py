#!/usr/bin/env python3
"""Fetch the pinned NVIDIA checkpoint; never fetch reciter audio or another exporter."""
import argparse
import hashlib
import json
from pathlib import Path
import urllib.request


def source_descriptor():
    return json.loads(Path(__file__).with_name("source.json").read_text())


def verify_checkpoint(path, source):
    if path.stat().st_size != source["size"]:
        raise ValueError("NVIDIA checkpoint size mismatch")
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    if digest.hexdigest() != source["sha256"]:
        raise ValueError("NVIDIA checkpoint SHA-256 mismatch")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    source = source_descriptor()
    args.out.parent.mkdir(parents=True, exist_ok=True)
    temporary = args.out.with_suffix(args.out.suffix + ".partial")
    try:
        with urllib.request.urlopen(source["url"], timeout=180) as response:
            with temporary.open("wb") as stream:
                size = 0
                while chunk := response.read(1024 * 1024):
                    size += len(chunk)
                    if size > source["size"]:
                        raise ValueError("NVIDIA checkpoint exceeds pinned size")
                    stream.write(chunk)
        verify_checkpoint(temporary, source)
        temporary.replace(args.out)
    finally:
        temporary.unlink(missing_ok=True)
    print(json.dumps(source, indent=2))


if __name__ == "__main__":
    main()

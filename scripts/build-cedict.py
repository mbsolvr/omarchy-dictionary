#!/usr/bin/env python3
"""Build small lookup buckets from an official CC-CEDICT .txt.gz release."""

import argparse
import gzip
import json
import re
from collections import defaultdict
from pathlib import Path


ENTRY = re.compile(r"^(\S+) (\S+) \[([^]]+)\] /(.+)/$")
ROOT = Path(__file__).resolve().parent.parent


def bucket(word):
    return f"{ord(word[0]) & 255:02x}"


def build(source, output):
    buckets = defaultdict(lambda: defaultdict(list))
    with gzip.open(source, "rt", encoding="utf-8") as stream:
        for line in stream:
            if line.startswith("#"):
                continue
            match = ENTRY.match(line.strip())
            if not match:
                continue
            traditional, simplified, pinyin, glosses = match.groups()
            definitions = [part.strip() for part in glosses.split("/") if part.strip()]
            if not definitions:
                continue
            item = [pinyin, definitions]
            for word in {traditional, simplified}:
                buckets[bucket(word)][word].append(item)

    output.mkdir(parents=True, exist_ok=True)
    for name, words in sorted(buckets.items()):
        data = json.dumps(words, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
        with output.joinpath(name + ".json.gz").open("wb") as raw:
            with gzip.GzipFile(fileobj=raw, mode="wb", mtime=0, filename="") as stream:
                stream.write(data.encode("utf-8"))
    print(f"Wrote {len(buckets)} CC-CEDICT buckets to {output}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="Official CC-CEDICT .txt.gz release")
    parser.add_argument("--output", type=Path, default=ROOT / "data" / "cedict")
    args = parser.parse_args()
    build(args.source, args.output)

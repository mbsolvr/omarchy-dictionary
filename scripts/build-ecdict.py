#!/usr/bin/env python3
"""Build small English-to-Chinese lookup buckets from ECDICT's CSV."""

import argparse
import csv
import gzip
import json
import re
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
HAN = re.compile(r"[\u3400-\u9fff\uf900-\ufaff]")


def bucket(word):
    value = 0
    encoded = word.encode("utf-16-le")
    for index in range(0, len(encoded), 2):
        unit = encoded[index] + (encoded[index + 1] << 8)
        value = (value * 31 + unit) & 255
    return f"{value:02x}"


def build(source, output):
    output.mkdir(parents=True, exist_ok=True)
    count = 0
    with tempfile.TemporaryDirectory(prefix="omarchy-ecdict-") as temporary:
        temporary = Path(temporary)
        writers = {}
        try:
            with source.open("r", encoding="utf-8-sig", newline="") as stream:
                for row in csv.DictReader(stream):
                    word = " ".join(row["word"].lower().split())
                    translation = row["translation"].strip()
                    if not word or not HAN.search(translation):
                        continue
                    name = bucket(word)
                    if name not in writers:
                        writers[name] = (temporary / name).open("w", encoding="utf-8")
                    record = [word, row["phonetic"].strip(), translation,
                              row["definition"].strip()]
                    writers[name].write(json.dumps(record, ensure_ascii=False) + "\n")
                    count += 1
        finally:
            for writer in writers.values():
                writer.close()

        for name in sorted(writers):
            words = {}
            with (temporary / name).open("r", encoding="utf-8") as stream:
                for line in stream:
                    word, phonetic, translation, definition = json.loads(line)
                    words[word] = [phonetic, translation, definition]
            data = json.dumps(words, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
            with (output / (name + ".json.gz")).open("wb") as raw:
                with gzip.GzipFile(fileobj=raw, mode="wb", mtime=0, filename="") as zipped:
                    zipped.write(data.encode("utf-8"))
    print(f"Wrote {count} translated headwords in {len(writers)} ECDICT buckets")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="Official ECDICT ecdict.csv")
    parser.add_argument("--output", type=Path, default=ROOT / "data" / "ecdict")
    arguments = parser.parse_args()
    build(arguments.source, arguments.output)

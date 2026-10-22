#!/usr/bin/env python3
"""Download chosen scenes of the Raw Natural Image Noise Dataset (RawNIND).

RawNIND (Brummer & De Vleeschouwer, UCLouvain, doi:10.14428/DVN/DEQCIM) pairs
noisy raw captures with a low-ISO ground truth of the same static scene. The
dataset is CC BY-SA 4.0; files are downloaded into a local directory and never
committed.

    python3 HyperDR_Model/denoise/fetch_rawnind.py --out build/denoise/rawnind \
        --scene MuseeL-Bobo-A7C --scene TEST_TitusToys --iso 3200 --iso 12800

For each scene the ground truth (``GT``) is fetched with the noisy capture whose
ISO is nearest to each requested ``--iso``. ``--list`` prints the scenes.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import sys
import urllib.request

SERVER = "https://dataverse.uclouvain.be"
DOI = "doi:10.14428/DVN/DEQCIM"
NAME = re.compile(r"^(Bayer|X-Trans)_(.+?)_(GT_)?ISO(\d+)_sha1=([0-9a-f]{40})\.(\w+)$")


def catalogue(cache: Path) -> list[dict]:
    if not cache.exists():
        url = f"{SERVER}/api/datasets/:persistentId/?persistentId={DOI}"
        with urllib.request.urlopen(url) as response:
            cache.write_bytes(response.read())
    files = json.loads(cache.read_text())["data"]["latestVersion"]["files"]
    entries = []
    for item in files:
        match = NAME.match(item["label"])
        if not match:
            continue
        entries.append({
            "sensor": match.group(1), "scene": match.group(2),
            "gt": bool(match.group(3)), "iso": int(match.group(4)),
            "sha1": match.group(5), "ext": match.group(6).lower(),
            "label": item["label"], "id": item["dataFile"]["id"],
        })
    return entries


def fetch(entry: dict, directory: Path) -> Path:
    directory.mkdir(parents=True, exist_ok=True)
    target = directory / entry["label"]
    if target.exists() and hashlib.sha1(target.read_bytes()).hexdigest() == entry["sha1"]:
        return target
    partial = target.with_suffix(target.suffix + ".part")
    url = f"{SERVER}/api/access/datafile/{entry['id']}"
    with urllib.request.urlopen(url) as response, partial.open("wb") as sink:
        while block := response.read(1 << 20):
            sink.write(block)
    digest = hashlib.sha1(partial.read_bytes()).hexdigest()
    if digest != entry["sha1"]:
        partial.unlink()
        raise RuntimeError(f"{entry['label']}: sha1 {digest} does not match")
    partial.rename(target)
    return target


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--scene", action="append", default=[])
    parser.add_argument("--iso", type=int, action="append", default=[])
    parser.add_argument("--all-iso", action="store_true", help="every noisy capture of the scene")
    parser.add_argument("--list", action="store_true")
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    entries = catalogue(args.out / "catalogue.json")

    if args.list:
        scenes: dict[str, list[dict]] = {}
        for entry in entries:
            scenes.setdefault(entry["scene"], []).append(entry)
        for scene, items in sorted(scenes.items()):
            isos = sorted(e["iso"] for e in items if not e["gt"])
            print(f"{scene}\t{items[0]['ext']}\t{isos}")
        return 0

    for scene in args.scene:
        items = [e for e in entries if e["scene"] == scene and e["ext"] != "xmp"]
        if not items:
            print(f"unknown scene {scene}", file=sys.stderr)
            return 1
        chosen = [e for e in items if e["gt"]][:1]
        noisy = [e for e in items if not e["gt"]]
        if args.all_iso:
            chosen += noisy
        for iso in args.iso:
            nearest = min(noisy, key=lambda e: abs(e["iso"] - iso))
            if nearest not in chosen:
                chosen.append(nearest)
        for entry in chosen:
            path = fetch(entry, args.out / scene)
            print(f"{scene}\tISO{entry['iso']}{' GT' if entry['gt'] else ''}\t{path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

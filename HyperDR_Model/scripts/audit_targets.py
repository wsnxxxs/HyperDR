#!/usr/bin/env python3
"""Report target eligibility and fixed-scale clipping without training."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from hyperdr_ml.data import AppleGainMapDataset, target_statistics


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--dataset-root",
        type=Path,
        default=Path.home() / "datasets/hyperdr-apple",
    )
    parser.add_argument("--output", type=Path)
    parser.add_argument("--allow-legacy-label-schema", action="store_true")
    args = parser.parse_args()
    result = {
        subset: {
            mode: {
                split: target_statistics(
                    AppleGainMapDataset(
                        args.dataset_root,
                        split,
                        subset,
                        False,
                        mode,
                        allow_legacy_label_schema=args.allow_legacy_label_schema,
                    )
                )
                for split in ("train", "validation", "test")
            }
            for mode in ("fixed_3stops", "per_image")
        }
        for subset in ("all", "xmp")
    }
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()

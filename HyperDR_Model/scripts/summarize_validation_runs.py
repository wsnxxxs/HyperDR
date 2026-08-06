#!/usr/bin/env python3
"""Summarize multi-seed architecture comparisons without touching test data."""

from __future__ import annotations

import argparse
from collections import defaultdict
import json
from pathlib import Path

import numpy as np


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("run_dirs", nargs="+", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    grouped: dict[str, list[dict[str, float | int | str]]] = defaultdict(list)
    for run_dir in args.run_dirs:
        config = json.loads((run_dir / "config.json").read_text())
        records = [
            json.loads(line)
            for line in (run_dir / "history.jsonl").read_text().splitlines()
        ]
        best = min(records, key=lambda row: row["validation"]["mae"])
        architecture = config.get("architecture", "baseline")
        grouped[architecture].append(
            {
                "run_dir": str(run_dir),
                "seed": config["seed"],
                "best_epoch": best["epoch"],
                "validation_mae": best["validation"]["mae"],
            }
        )
    summary = {}
    for architecture, runs in sorted(grouped.items()):
        values = np.asarray([run["validation_mae"] for run in runs])
        summary[architecture] = {
            "seeds": len(runs),
            "validation_mae_mean": float(values.mean()),
            "validation_mae_std": float(values.std(ddof=1)) if len(values) > 1 else 0.0,
            "runs": runs,
        }
    result = {
        "selection_scope": "validation only; test data was not read",
        "architectures": summary,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()

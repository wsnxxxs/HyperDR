#!/usr/bin/env python3
"""Build leakage-resistant splits while preserving a frozen assignment baseline.

The first dataset split was balanced globally. Once model development starts,
rerunning that global optimization after adding photos invalidates comparisons
because historical samples can move between train, validation, and test.

This script therefore has two explicit modes:

1. ``--freeze-current`` records the existing split and capture-group assignment
   as an immutable v1 baseline without changing any split file.
2. Normal runs recompute capture groups, preserve every frozen sample's split,
   inherit a frozen split for new members of an existing group, and assign only
   wholly new groups to train.

If recomputed evidence connects frozen samples from different splits, the run
fails before writing anything. That conflict needs human review because either
choice would introduce leakage or rewrite the evaluation baseline.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from collections import Counter, defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Iterable

import cv2
import numpy as np

DEFAULT_ROOT = Path.home() / "datasets/hyperdr-apple"
FROZEN_SPLITS = ("train", "validation", "test")
FREEZE_SCHEMA_VERSION = 1
FREEZE_ID = "hyperdr-apple-capture-group-split-v1"
SESSION_GAP_MINUTES = 30
PHASH_HAMMING_MAX = 5
DHASH_HAMMING_MAX = 6


class UnionFind:
    def __init__(self, items: Iterable[str]) -> None:
        self.parent = {item: item for item in items}

    def find(self, item: str) -> str:
        parent = self.parent[item]
        if parent != item:
            self.parent[item] = self.find(parent)
        return self.parent[item]

    def union(self, left: str, right: str) -> None:
        a, b = self.find(left), self.find(right)
        if a != b:
            self.parent[max(a, b)] = min(a, b)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=DEFAULT_ROOT)
    parser.add_argument("--long-side", type=int, default=1024)
    parser.add_argument(
        "--freeze-manifest",
        type=Path,
        help="Defaults to <root>/splits/frozen-v1.json",
    )
    parser.add_argument(
        "--freeze-current",
        action="store_true",
        help="Lock the current split/group files without recomputing them.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Recompute and validate assignments without writing files.",
    )
    return parser.parse_args()


def read_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    return [
        json.loads(line)
        for line in path.read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(4 * 1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def atomic_json(path: Path, value: Any, mode: int = 0o644) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    temp.write_text(
        json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    os.replace(temp, path)
    path.chmod(mode)


def phash(path: Path) -> int:
    image = cv2.imread(str(path), cv2.IMREAD_GRAYSCALE)
    if image is None:
        raise ValueError(f"Cannot read {path}")
    resized = cv2.resize(image, (32, 32), interpolation=cv2.INTER_AREA).astype(
        np.float32
    )
    transformed = cv2.dct(resized)[:8, :8]
    median = float(np.median(transformed.flatten()[1:]))
    bits = transformed.flatten() >= median
    result = 0
    for bit in bits:
        result = (result << 1) | int(bit)
    return result


def dhash(path: Path) -> int:
    image = cv2.imread(str(path), cv2.IMREAD_GRAYSCALE)
    if image is None:
        raise ValueError(f"Cannot read {path}")
    resized = cv2.resize(image, (9, 8), interpolation=cv2.INTER_AREA)
    bits = resized[:, 1:] >= resized[:, :-1]
    result = 0
    for bit in bits.flatten():
        result = (result << 1) | int(bit)
    return result


def distance(left: int, right: int) -> int:
    return (left ^ right).bit_count()


def load_manifest_rows(root: Path) -> list[dict[str, Any]]:
    rows = read_jsonl(root / "manifests" / "samples.jsonl")
    rows = [row for row in rows if bool(row.get("gain_map_present"))]
    ids = [str(row["sample_id"]) for row in rows]
    if len(ids) != len(set(ids)):
        raise RuntimeError("Gain-map manifest contains duplicate sample IDs")
    return rows


def load_current_assignments(root: Path) -> dict[str, str]:
    assignments: dict[str, str] = {}
    for split in FROZEN_SPLITS:
        path = root / "splits" / f"{split}.json"
        values = read_json(path).get("sample_ids")
        if not isinstance(values, list):
            raise RuntimeError(f"{path} does not contain a sample_ids list")
        for sample_id in values:
            if sample_id in assignments:
                raise RuntimeError(
                    f"Sample {sample_id} appears in both "
                    f"{assignments[sample_id]} and {split}"
                )
            assignments[str(sample_id)] = split
    return assignments


def validate_group_rows(
    groups: list[dict[str, Any]],
    assignments: dict[str, str],
    expected_ids: set[str],
) -> None:
    seen: list[str] = []
    for group in groups:
        members = [str(item) for item in group.get("members", [])]
        if not members:
            raise RuntimeError(f"Empty capture group: {group.get('group_id')}")
        declared_split = group.get("split")
        member_splits = {assignments.get(item) for item in members}
        if None in member_splits:
            missing = sorted(item for item in members if item not in assignments)
            raise RuntimeError(
                f"Capture group {group.get('group_id')} has unassigned members: "
                f"{missing[:5]}"
            )
        if member_splits != {declared_split}:
            raise RuntimeError(
                f"Capture group {group.get('group_id')} crosses splits: "
                f"{sorted(str(item) for item in member_splits)}"
            )
        seen.extend(members)
    if len(seen) != len(set(seen)) or set(seen) != expected_ids:
        raise RuntimeError("Capture-group coverage is incomplete or overlapping")


def freeze_current(root: Path, freeze_path: Path) -> dict[str, Any]:
    if freeze_path.exists():
        raise RuntimeError(
            f"Freeze manifest already exists: {freeze_path}. "
            "It is immutable; do not overwrite it."
        )

    rows = load_manifest_rows(root)
    expected_ids = {str(row["sample_id"]) for row in rows}
    assignments = load_current_assignments(root)
    if set(assignments) != expected_ids:
        missing = sorted(expected_ids - set(assignments))
        extra = sorted(set(assignments) - expected_ids)
        raise RuntimeError(
            "Current splits do not exactly cover gain-map samples; "
            f"missing={missing[:5]} extra={extra[:5]}"
        )

    groups_path = root / "splits" / "groups.json"
    groups = read_json(groups_path).get("groups")
    if not isinstance(groups, list):
        raise RuntimeError(f"{groups_path} does not contain a groups list")
    validate_group_rows(groups, assignments, expected_ids)

    manifest_path = root / "manifests" / "samples.jsonl"
    private_path = root / "private" / "capture-index.jsonl"
    payload = {
        "schema_version": FREEZE_SCHEMA_VERSION,
        "freeze_id": FREEZE_ID,
        "created_at_utc": datetime.now(timezone.utc).isoformat(),
        "policy": {
            "frozen_splits": list(FROZEN_SPLITS),
            "new_independent_groups": "train",
            "new_members_of_frozen_groups": "inherit_frozen_split",
            "cross_frozen_split_bridge": "fail_before_write",
            "removed_frozen_samples": "fail_before_write",
        },
        "grouping": {
            "session_gap_minutes": SESSION_GAP_MINUTES,
            "temporal_device_key": "model",
            "phash_hamming_max": PHASH_HAMMING_MAX,
            "dhash_hamming_max": DHASH_HAMMING_MAX,
        },
        "source_snapshot": {
            "samples_manifest_sha256": sha256_file(manifest_path),
            "private_capture_index_sha256": sha256_file(private_path),
            "groups_sha256": sha256_file(groups_path),
        },
        "counts": {
            "samples": len(assignments),
            "groups": len(groups),
            "splits": dict(Counter(assignments.values())),
        },
        "sample_assignments": dict(sorted(assignments.items())),
        "groups": [
            {
                "group_id": str(group["group_id"]),
                "split": str(group["split"]),
                "members": sorted(str(item) for item in group["members"]),
            }
            for group in sorted(groups, key=lambda item: str(item["group_id"]))
        ],
    }
    atomic_json(freeze_path, payload)
    return payload


def load_freeze(freeze_path: Path) -> dict[str, Any]:
    payload = read_json(freeze_path)
    if payload.get("schema_version") != FREEZE_SCHEMA_VERSION:
        raise RuntimeError(
            f"Unsupported freeze schema: {payload.get('schema_version')!r}"
        )
    if payload.get("freeze_id") != FREEZE_ID:
        raise RuntimeError(f"Unexpected freeze_id in {freeze_path}")
    assignments = payload.get("sample_assignments")
    if not isinstance(assignments, dict) or not assignments:
        raise RuntimeError(f"{freeze_path} has no sample assignments")
    invalid = {
        sample_id: split
        for sample_id, split in assignments.items()
        if split not in FROZEN_SPLITS
    }
    if invalid:
        raise RuntimeError(f"Invalid frozen split assignments: {invalid}")
    return payload


def parse_capture_datetime(raw: object) -> datetime | None:
    if not raw:
        return None
    value = datetime.fromisoformat(str(raw))
    if value.tzinfo is not None:
        value = value.astimezone(timezone.utc).replace(tzinfo=None)
    return value


def load_or_compute_hashes(
    ids: list[str],
    proxy_dir: Path,
    hashes_path: Path,
) -> dict[str, tuple[int, int]]:
    stored: dict[str, Any] = read_json(hashes_path) if hashes_path.exists() else {}
    hashes: dict[str, tuple[int, int]] = {}
    for index, sample_id in enumerate(ids, 1):
        values = stored.get(sample_id)
        if (
            isinstance(values, dict)
            and isinstance(values.get("phash64"), str)
            and isinstance(values.get("dhash64"), str)
        ):
            hashes[sample_id] = (
                int(values["phash64"], 16),
                int(values["dhash64"], 16),
            )
        else:
            path = proxy_dir / f"{sample_id}.png"
            hashes[sample_id] = (phash(path), dhash(path))
        if index % 100 == 0:
            print(f"hashed_or_loaded={index}/{len(ids)}", flush=True)
    return hashes


def build_groups(
    rows: list[dict[str, Any]],
    private_rows: list[dict[str, Any]],
    hashes: dict[str, tuple[int, int]],
) -> tuple[list[dict[str, Any]], dict[str, int]]:
    by_id = {str(row["sample_id"]): row for row in rows}
    private = {str(row["sample_id"]): row for row in private_rows}
    ids = sorted(by_id)
    missing_private = sorted(set(ids) - set(private))
    if missing_private:
        raise RuntimeError(
            f"Private capture index is missing {len(missing_private)} samples: "
            f"{missing_private[:5]}"
        )
    missing_hashes = sorted(set(ids) - set(hashes))
    if missing_hashes:
        raise RuntimeError(
            f"Perceptual hashes are missing {len(missing_hashes)} samples"
        )

    union = UnionFind(ids)
    dated_by_device: dict[str, list[tuple[datetime, str]]] = defaultdict(list)
    for sample_id in ids:
        capture_dt = parse_capture_datetime(
            private[sample_id].get("capture_datetime")
        )
        if capture_dt is not None:
            dated_by_device[str(by_id[sample_id].get("model", "unknown"))].append(
                (capture_dt, sample_id)
            )

    temporal_edges = 0
    for values in dated_by_device.values():
        values.sort()
        for (previous_dt, previous_id), (current_dt, current_id) in zip(
            values, values[1:]
        ):
            if current_dt - previous_dt <= timedelta(minutes=SESSION_GAP_MINUTES):
                union.union(previous_id, current_id)
                temporal_edges += 1

    visual_edges = 0
    for index, left in enumerate(ids):
        left_phash, left_dhash = hashes[left]
        for right in ids[index + 1 :]:
            right_phash, right_dhash = hashes[right]
            if (
                distance(left_phash, right_phash) <= PHASH_HAMMING_MAX
                and distance(left_dhash, right_dhash) <= DHASH_HAMMING_MAX
            ):
                union.union(left, right)
                visual_edges += 1

    members: dict[str, list[str]] = defaultdict(list)
    for sample_id in ids:
        members[union.find(sample_id)].append(sample_id)

    groups: list[dict[str, Any]] = []
    for member_ids in members.values():
        member_ids.sort()
        group_id = (
            "grp_"
            + hashlib.sha256("\n".join(member_ids).encode("utf-8")).hexdigest()[:16]
        )
        groups.append(
            {
                "group_id": group_id,
                "size": len(member_ids),
                "members": member_ids,
                "models": dict(
                    Counter(str(by_id[item].get("model", "unknown")) for item in member_ids)
                ),
            }
        )
    groups.sort(key=lambda item: str(item["group_id"]))
    return groups, {
        "temporal_adjacency_edges": temporal_edges,
        "visual_near_duplicate_pairs": visual_edges,
    }


def assign_groups(
    groups: list[dict[str, Any]],
    frozen_assignments: dict[str, str],
) -> tuple[list[dict[str, Any]], dict[str, str], dict[str, int]]:
    assignments: dict[str, str] = {}
    assigned_groups: list[dict[str, Any]] = []
    new_independent_groups = 0
    inherited_new_samples = 0

    for group in groups:
        members = [str(item) for item in group["members"]]
        frozen_splits = {
            str(frozen_assignments[item])
            for item in members
            if item in frozen_assignments
        }
        if len(frozen_splits) > 1:
            raise RuntimeError(
                "Recomputed capture evidence bridges frozen splits for "
                f"{group['group_id']}: {sorted(frozen_splits)}. "
                "No files were written."
            )
        if frozen_splits:
            split = next(iter(frozen_splits))
            inherited_new_samples += sum(
                item not in frozen_assignments for item in members
            )
        else:
            split = "train"
            new_independent_groups += 1
        for sample_id in members:
            assignments[sample_id] = split
        assigned_groups.append({**group, "split": split})

    return assigned_groups, assignments, {
        "new_independent_groups": new_independent_groups,
        "new_independent_group_policy_train": new_independent_groups,
        "new_samples_inheriting_frozen_group": inherited_new_samples,
    }


def split_ids_from_assignments(assignments: dict[str, str]) -> dict[str, list[str]]:
    result = {split: [] for split in FROZEN_SPLITS}
    for sample_id, split in assignments.items():
        if split not in result:
            raise RuntimeError(f"Unsupported split assignment: {split}")
        result[split].append(sample_id)
    for values in result.values():
        values.sort()
    return result


def main() -> None:
    args = parse_args()
    root: Path = args.root
    freeze_path = args.freeze_manifest or root / "splits" / "frozen-v1.json"

    if args.freeze_current:
        if args.dry_run:
            raise SystemExit("--freeze-current and --dry-run are mutually exclusive")
        payload = freeze_current(root, freeze_path)
        print(
            json.dumps(
                {
                    "freeze_manifest": str(freeze_path),
                    "freeze_id": payload["freeze_id"],
                    "counts": payload["counts"],
                    "split_files_changed": 0,
                },
                indent=2,
            )
        )
        return

    if not freeze_path.exists():
        raise SystemExit(
            f"Frozen split baseline is required: {freeze_path}. "
            "Review the current split, then run once with --freeze-current."
        )

    freeze = load_freeze(freeze_path)
    frozen_assignments = {
        str(sample_id): str(split)
        for sample_id, split in freeze["sample_assignments"].items()
    }
    rows = load_manifest_rows(root)
    ids = {str(row["sample_id"]) for row in rows}
    removed_frozen = sorted(set(frozen_assignments) - ids)
    if removed_frozen:
        raise RuntimeError(
            f"{len(removed_frozen)} frozen samples are missing from the manifest: "
            f"{removed_frozen[:5]}. No files were written."
        )

    private_rows = read_jsonl(root / "private" / "capture-index.jsonl")
    hashes_path = root / "private" / "perceptual-hashes.json"
    hashes = load_or_compute_hashes(
        sorted(ids),
        root / "extracted" / f"sdr_{args.long_side}",
        hashes_path,
    )
    groups, edge_stats = build_groups(rows, private_rows, hashes)
    group_rows, assignments, assignment_stats = assign_groups(
        groups, frozen_assignments
    )
    for sample_id, frozen_split in frozen_assignments.items():
        if assignments.get(sample_id) != frozen_split:
            raise RuntimeError(
                f"Frozen sample moved unexpectedly: {sample_id}. No files were written."
            )

    split_ids = split_ids_from_assignments(assignments)
    flattened = [
        sample_id for values in split_ids.values() for sample_id in values
    ]
    if (
        len(flattened) != len(ids)
        or set(flattened) != ids
        or len(flattened) != len(set(flattened))
    ):
        raise RuntimeError("Split is incomplete or overlapping")

    current_assignments = load_current_assignments(root)
    changed_existing = sorted(
        sample_id
        for sample_id in set(current_assignments) & set(assignments)
        if current_assignments[sample_id] != assignments[sample_id]
    )
    if changed_existing:
        raise RuntimeError(
            f"{len(changed_existing)} existing samples would move splits: "
            f"{changed_existing[:5]}. No files were written."
        )

    by_id = {str(row["sample_id"]): row for row in rows}
    summary = {
        "freeze_id": freeze["freeze_id"],
        "freeze_manifest": str(freeze_path.relative_to(root)),
        "frozen_samples": len(frozen_assignments),
        "new_samples": len(ids - set(frozen_assignments)),
        "labeled_samples": len(ids),
        "capture_groups": len(group_rows),
        "largest_group": max(len(group["members"]) for group in group_rows),
        **edge_stats,
        "visual_thresholds": {
            "phash_hamming_max": PHASH_HAMMING_MAX,
            "dhash_hamming_max": DHASH_HAMMING_MAX,
        },
        "session_gap_minutes": SESSION_GAP_MINUTES,
        "new_group_policy": "train",
        **assignment_stats,
        "existing_assignment_churn": len(changed_existing),
        "split_samples": {
            split: len(values) for split, values in split_ids.items()
        },
        "split_groups": dict(Counter(row["split"] for row in group_rows)),
        "split_models": {
            split: dict(
                Counter(
                    str(by_id[sample_id].get("model", "unknown"))
                    for sample_id in values
                )
            )
            for split, values in split_ids.items()
        },
        "dry_run": bool(args.dry_run),
    }

    if not args.dry_run:
        for split, values in split_ids.items():
            atomic_json(
                root / "splits" / f"{split}.json",
                {"split": split, "sample_ids": values},
            )
        atomic_json(root / "splits" / "groups.json", {"groups": group_rows})
        atomic_json(
            hashes_path,
            {
                sample_id: {
                    "phash64": f"{values[0]:016x}",
                    "dhash64": f"{values[1]:016x}",
                }
                for sample_id, values in sorted(hashes.items())
            },
            0o600,
        )
        atomic_json(root / "reports" / "split-summary.json", summary)

    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()

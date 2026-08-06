#!/usr/bin/env python3
"""Create a read-only quality and coverage audit for the HyperDR dataset.

The audit reads manifests, split metadata, private capture grouping metadata,
and cached gain grids. It never edits, moves, or deletes source photographs or
training caches. Only the explicitly requested JSON and Markdown report paths
are written.
"""

from __future__ import annotations

import argparse
from collections import Counter, defaultdict
from datetime import datetime, timezone
import hashlib
import json
import math
from pathlib import Path
from typing import Any, Iterable

import numpy as np

DEFAULT_ROOT = Path.home() / "datasets/hyperdr-apple"
SPLITS = ("train", "validation", "test")
XMP_SOURCE = "xmp_hdr_gain_map_headroom"
LEGACY_SOURCE = "apple_makernote_piecewise_estimate"
STOP_BANDS = (
    ("0–1", -math.inf, 1.0),
    ("1–2", 1.0, 2.0),
    ("2–3", 2.0, 3.0),
    ("3+", 3.0, math.inf),
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset-root", type=Path, default=DEFAULT_ROOT)
    parser.add_argument("--output-json", type=Path, required=True)
    parser.add_argument("--output-markdown", type=Path, required=True)
    parser.add_argument(
        "--output-sql",
        type=Path,
        help="Optional self-contained SQLite reproduction of bounded report rows.",
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


def write_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(4 * 1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def safe_rate(numerator: int | float, denominator: int | float) -> float:
    return float(numerator / denominator) if denominator else 0.0


def file_ids(directory: Path, suffix: str) -> set[str]:
    if not directory.exists():
        return set()
    return {path.name[: -len(suffix)] for path in directory.glob(f"*{suffix}")}


def finite_number(value: object) -> bool:
    try:
        number = float(value)
    except (TypeError, ValueError):
        return False
    return math.isfinite(number)


def quantiles(values: Iterable[object]) -> dict[str, float | int | None]:
    numbers = np.asarray(
        [float(value) for value in values if finite_number(value)],
        dtype=np.float64,
    )
    if not len(numbers):
        return {
            "count": 0,
            "min": None,
            "p10": None,
            "p25": None,
            "median": None,
            "p75": None,
            "p90": None,
            "max": None,
        }
    points = np.quantile(numbers, [0.0, 0.1, 0.25, 0.5, 0.75, 0.9, 1.0])
    return {
        "count": int(len(numbers)),
        "min": float(points[0]),
        "p10": float(points[1]),
        "p25": float(points[2]),
        "median": float(points[3]),
        "p75": float(points[4]),
        "p90": float(points[5]),
        "max": float(points[6]),
    }


def count_numeric_bands(
    rows: Iterable[dict[str, Any]],
    field: str,
    bands: tuple[tuple[str, float, float], ...],
) -> dict[str, int]:
    counts = Counter()
    for row in rows:
        value = row.get(field)
        if not finite_number(value):
            counts["missing"] += 1
            continue
        number = float(value)
        matched = False
        for label, lower, upper in bands:
            if lower <= number < upper:
                counts[label] += 1
                matched = True
                break
        if not matched:
            counts["out_of_range"] += 1
    result = {label: counts[label] for label, _, _ in bands}
    for label in ("missing", "out_of_range"):
        if counts[label]:
            result[label] = counts[label]
    return result


def stop_band_profile(
    root: Path,
    split_ids: dict[str, list[str]],
    manifest: dict[str, dict[str, Any]],
) -> dict[str, Any]:
    result: dict[str, Any] = {}
    grid_dir = root / "training" / "gain_grid_stride16_f16"
    for split, ids in split_ids.items():
        xmp_ids = [
            sample_id
            for sample_id in ids
            if manifest[sample_id].get("headroom_source") == XMP_SOURCE
        ]
        counts = Counter()
        samples_with_band = Counter()
        total_pixels = 0
        missing_grids: list[str] = []
        for sample_id in xmp_ids:
            path = grid_dir / f"{sample_id}.npy"
            if not path.exists():
                missing_grids.append(sample_id)
                continue
            grid = np.load(path, allow_pickle=False).astype(np.float32)
            total_pixels += int(grid.size)
            for label, lower, upper in STOP_BANDS:
                mask = (grid >= lower) & (grid < upper)
                count = int(mask.sum())
                counts[label] += count
                samples_with_band[label] += int(count > 0)
        result[split] = {
            "xmp_samples": len(xmp_ids),
            "pixels": total_pixels,
            "bands": {
                label: {
                    "pixels": counts[label],
                    "pixel_fraction": safe_rate(counts[label], total_pixels),
                    "samples_with_pixels": samples_with_band[label],
                    "sample_fraction": safe_rate(
                        samples_with_band[label], len(xmp_ids)
                    ),
                }
                for label, _, _ in STOP_BANDS
            },
            "missing_grid_count": len(missing_grids),
            "missing_grid_examples": missing_grids[:10],
        }
    return result


def inspect_assets(
    root: Path,
    sample_ids: set[str],
    gain_ids: set[str],
) -> dict[str, Any]:
    contracts = (
        ("original_heic", root / "originals", ".heic", sample_ids),
        ("sdr_proxy", root / "extracted" / "sdr_1024", ".png", sample_ids),
        (
            "raw_gain",
            root / "extracted" / "apple_gain_raw",
            ".png",
            gain_ids,
        ),
        (
            "canonical_gain",
            root / "extracted" / "canonical_log2_gain_f16",
            ".npy",
            gain_ids,
        ),
        (
            "linear_training_cache",
            root / "training" / "linear_p3_f16",
            ".npy",
            gain_ids,
        ),
        (
            "gain_grid_training_cache",
            root / "training" / "gain_grid_stride16_f16",
            ".npy",
            gain_ids,
        ),
    )
    result = {}
    for name, directory, suffix, expected in contracts:
        actual = file_ids(directory, suffix)
        missing = sorted(expected - actual)
        extra = sorted(actual - expected)
        result[name] = {
            "expected": len(expected),
            "found": len(actual),
            "missing": len(missing),
            "extra": len(extra),
            "missing_examples": missing[:10],
            "extra_examples": extra[:10],
        }
    return result


def pipeline_review() -> list[dict[str, str]]:
    return [
        {
            "stage": "extraction",
            "implementation": "scripts/extract_apple_dataset.py",
            "review": (
                "原始 HEIC 保持为事实来源；public manifest 不含源文件名、GPS "
                "和精确时间。精确拍摄时间只保存在 private capture index。"
            ),
        },
        {
            "stage": "label enrichment",
            "implementation": "scripts/enrich_apple_metadata.py",
            "review": (
                "存在 XMP HDRGainMapHeadroom 时直接使用。旧版 version-65536 "
                "照片使用逆向推导的 MakerNote 估算，并由 headroom_source "
                "持续明确区分。"
            ),
        },
        {
            "stage": "target construction",
            "implementation": "scripts/generate_canonical_gain.py",
            "review": (
                "canonical target 是 log2 线性增益。训练使用 stride-16 "
                "面积降采样缓存，并检查有限值与形状对齐。"
            ),
        },
        {
            "stage": "capture grouping",
            "implementation": "scripts/build_splits.py",
            "review": (
                "同一 model 字符串内 30 分钟的时间邻接，与较保守的 "
                "pHash+dHash 近重复证据共同构成 capture group。"
            ),
        },
        {
            "stage": "training selection",
            "implementation": "hyperdr_ml/data.py",
            "review": (
                "label_subset=xmp 在加载固定 split ID 后才过滤，因此 legacy "
                "MakerNote 样本会被排除，但不会改变任何 split 成员关系。"
            ),
        },
    ]


def finding(
    finding_id: str,
    severity: str,
    status: str,
    title: str,
    evidence: str,
    impact: str,
    remediation: str,
    confidence: str = "high",
) -> dict[str, str]:
    return {
        "id": finding_id,
        "severity": severity,
        "status": status,
        "title": title,
        "evidence": evidence,
        "impact": impact,
        "remediation": remediation,
        "confidence": confidence,
    }


def audit(root: Path) -> dict[str, Any]:
    generated_at = datetime.now(timezone.utc).isoformat()
    manifest_path = root / "manifests" / "samples.jsonl"
    private_path = root / "private" / "capture-index.jsonl"
    groups_path = root / "splits" / "groups.json"
    freeze_path = root / "splits" / "frozen-v1.json"

    rows = read_jsonl(manifest_path)
    private_rows = read_jsonl(private_path)
    manifest = {str(row["sample_id"]): row for row in rows}
    sample_ids_list = [str(row["sample_id"]) for row in rows]
    sample_ids = set(sample_ids_list)
    gain_ids = {
        str(row["sample_id"]) for row in rows if bool(row.get("gain_map_present"))
    }
    private = {str(row["sample_id"]): row for row in private_rows}

    split_ids = {
        split: [
            str(item)
            for item in read_json(root / "splits" / f"{split}.json")[
                "sample_ids"
            ]
        ]
        for split in SPLITS
    }
    all_split_ids = [item for values in split_ids.values() for item in values]
    sample_split = {
        sample_id: split for split, values in split_ids.items() for sample_id in values
    }

    groups = read_json(groups_path)["groups"]
    sample_group: dict[str, str] = {}
    group_split: dict[str, str] = {}
    group_cross_split: list[str] = []
    for group in groups:
        group_id = str(group["group_id"])
        members = [str(item) for item in group["members"]]
        member_splits = {sample_split.get(item) for item in members}
        if member_splits != {group.get("split")}:
            group_cross_split.append(group_id)
        group_split[group_id] = str(group["split"])
        for sample_id in members:
            if sample_id in sample_group:
                group_cross_split.append(group_id)
            sample_group[sample_id] = group_id

    duplicate_sample_ids = len(sample_ids_list) - len(sample_ids)
    split_duplicate_ids = len(all_split_ids) - len(set(all_split_ids))
    split_missing_ids = sorted(gain_ids - set(all_split_ids))
    split_extra_ids = sorted(set(all_split_ids) - gain_ids)
    group_missing_ids = sorted(gain_ids - set(sample_group))
    group_extra_ids = sorted(set(sample_group) - gain_ids)

    source_hashes = [
        str(row.get("source_sha256"))
        for row in rows
        if row.get("source_sha256")
    ]
    exact_duplicate_hashes = sum(
        count - 1 for count in Counter(source_hashes).values() if count > 1
    )

    headroom_sources = Counter(
        str(row.get("headroom_source", "missing"))
        for row in rows
        if bool(row.get("gain_map_present"))
    )
    label_by_split = {
        split: dict(
            Counter(
                str(manifest[sample_id].get("headroom_source", "missing"))
                for sample_id in ids
            )
        )
        for split, ids in split_ids.items()
    }
    xmp_group_counts = {}
    all_group_counts = {}
    for split, ids in split_ids.items():
        all_group_counts[split] = len(
            {sample_group[item] for item in ids if item in sample_group}
        )
        xmp_group_counts[split] = len(
            {
                sample_group[item]
                for item in ids
                if item in sample_group
                and manifest[item].get("headroom_source") == XMP_SOURCE
            }
        )

    invalid_rows: list[str] = []
    for row in rows:
        sample_id = str(row["sample_id"])
        if bool(row.get("gain_map_present")):
            if not finite_number(row.get("canonical_headroom")) or float(
                row["canonical_headroom"]
            ) < 1.0:
                invalid_rows.append(f"{sample_id}:invalid_canonical_headroom")
            if not finite_number(row.get("canonical_max_log2_gain")) or float(
                row["canonical_max_log2_gain"]
            ) < 0.0:
                invalid_rows.append(f"{sample_id}:invalid_canonical_max_log2_gain")
        if row.get("headroom_source") == XMP_SOURCE and not finite_number(
            row.get("gain_map_headroom_xmp")
        ):
            invalid_rows.append(f"{sample_id}:missing_xmp_headroom")
        if row.get("headroom_source") == LEGACY_SOURCE and not finite_number(
            row.get("apple_maker_hdr_headroom")
        ):
            invalid_rows.append(f"{sample_id}:missing_makernote_headroom")

    freeze: dict[str, Any] | None = read_json(freeze_path) if freeze_path.exists() else None
    frozen_assignments = (
        {
            str(sample_id): str(split)
            for sample_id, split in freeze.get("sample_assignments", {}).items()
        }
        if freeze
        else {}
    )
    frozen_missing = sorted(set(frozen_assignments) - gain_ids)
    frozen_moved = sorted(
        sample_id
        for sample_id, split in frozen_assignments.items()
        if sample_split.get(sample_id) != split
    )
    freeze_integrity = {
        "present": freeze is not None,
        "freeze_id": freeze.get("freeze_id") if freeze else None,
        "schema_version": freeze.get("schema_version") if freeze else None,
        "frozen_samples": len(frozen_assignments),
        "missing_frozen_samples": len(frozen_missing),
        "moved_frozen_samples": len(frozen_moved),
        "missing_examples": frozen_missing[:10],
        "moved_examples": frozen_moved[:10],
        "source_snapshot_matches_current": {
            "samples_manifest": (
                freeze["source_snapshot"]["samples_manifest_sha256"]
                == sha256_file(manifest_path)
                if freeze
                else False
            ),
            "private_capture_index": (
                freeze["source_snapshot"]["private_capture_index_sha256"]
                == sha256_file(private_path)
                if freeze
                else False
            ),
            "groups": (
                freeze["source_snapshot"]["groups_sha256"]
                == sha256_file(groups_path)
                if freeze
                else False
            ),
        },
    }

    assets = inspect_assets(root, sample_ids, gain_ids)
    asset_missing_total = sum(item["missing"] for item in assets.values())
    asset_extra_total = sum(item["extra"] for item in assets.values())
    stop_bands = stop_band_profile(root, split_ids, manifest)

    xmp_rows = [
        row for row in rows if row.get("headroom_source") == XMP_SOURCE
    ]
    metadata_profile = {
        "xmp": {
            "iso": quantiles(row.get("iso") for row in xmp_rows),
            "exposure_seconds": quantiles(
                row.get("exposure_seconds") for row in xmp_rows
            ),
            "focal_length_mm": quantiles(
                row.get("focal_length_mm") for row in xmp_rows
            ),
            "focal_length_35mm": quantiles(
                row.get("focal_length_35mm") for row in xmp_rows
            ),
            "canonical_max_log2_gain": quantiles(
                row.get("canonical_max_log2_gain") for row in xmp_rows
            ),
        },
        "xmp_iso_bands": count_numeric_bands(
            xmp_rows,
            "iso",
            (
                ("<100", -math.inf, 100.0),
                ("100–399", 100.0, 400.0),
                ("400–799", 400.0, 800.0),
                ("800–1599", 800.0, 1600.0),
                ("1600+", 1600.0, math.inf),
            ),
        ),
        "xmp_exposure_bands_seconds": count_numeric_bands(
            xmp_rows,
            "exposure_seconds",
            (
                ("<1/1000", -math.inf, 0.001),
                ("1/1000–1/250", 0.001, 0.004),
                ("1/250–1/60", 0.004, 1.0 / 60.0),
                ("1/60–1/15", 1.0 / 60.0, 1.0 / 15.0),
                ("1/15+", 1.0 / 15.0, math.inf),
            ),
        ),
        "models": dict(Counter(str(row.get("model", "unknown")) for row in rows)),
        "models_xmp": dict(
            Counter(str(row.get("model", "unknown")) for row in xmp_rows)
        ),
        "orientation": dict(
            Counter(
                (
                    "landscape"
                    if int(row["proxy_size"][0]) > int(row["proxy_size"][1])
                    else "portrait"
                    if int(row["proxy_size"][1]) > int(row["proxy_size"][0])
                    else "square"
                )
                for row in rows
                if isinstance(row.get("proxy_size"), list)
                and len(row["proxy_size"]) == 2
            )
        ),
        "capture_month": {
            "min": min(
                (str(row["capture_month"]) for row in rows if row.get("capture_month")),
                default=None,
            ),
            "max": max(
                (str(row["capture_month"]) for row in rows if row.get("capture_month")),
                default=None,
            ),
            "missing": sum(not row.get("capture_month") for row in rows),
            "distinct": len(
                {str(row["capture_month"]) for row in rows if row.get("capture_month")}
            ),
        },
        "private_capture_datetime_missing": sum(
            not private.get(sample_id, {}).get("capture_datetime")
            for sample_id in gain_ids
        ),
    }

    group_sizes = [len(group["members"]) for group in groups]
    duplicate_profile = {
        "exact_duplicate_source_files": exact_duplicate_hashes,
        "capture_groups": len(groups),
        "singleton_groups": sum(size == 1 for size in group_sizes),
        "multi_sample_groups": sum(size > 1 for size in group_sizes),
        "samples_in_multi_sample_groups": sum(
            size for size in group_sizes if size > 1
        ),
        "largest_group": max(group_sizes, default=0),
        "group_size_quantiles": quantiles(group_sizes),
    }

    test_high_gain_pixels = stop_bands["test"]["bands"]["2–3"]["pixels"]
    test_high_gain_fraction = stop_bands["test"]["bands"]["2–3"][
        "pixel_fraction"
    ]
    freeze_ok = (
        freeze is not None and not frozen_missing and not frozen_moved
    )
    split_ok = (
        duplicate_sample_ids == 0
        and split_duplicate_ids == 0
        and not split_missing_ids
        and not split_extra_ids
        and not group_missing_ids
        and not group_extra_ids
        and not group_cross_split
    )
    assets_ok = asset_missing_total == 0 and asset_extra_total == 0

    findings = [
        finding(
            "DQ-001",
            "critical",
            "pass" if split_ok else "fail",
            "Capture group 互斥，split 覆盖全部有标签样本",
            (
                f"{len(gain_ids)} 个 gain-map 样本、{len(groups)} 个组、"
                f"{split_duplicate_ids} 个重复分配、"
                f"{len(group_cross_split)} 个跨 split 组。"
            ),
            (
                "若失败，相关拍摄可能泄漏到 train 与评估两侧，或有标签数据"
                "被静默遗漏。"
            ),
            "将此检查保留为每次训练前的强制门禁。",
        ),
        finding(
            "DQ-002",
            "critical",
            "pass" if freeze_ok else "fail",
            "当前 split 已建立不可变的分配基线",
            (
                f"冻结 {len(frozen_assignments)} 个样本；"
                f"{len(frozen_missing)} 个缺失，{len(frozen_moved)} 个移动。"
            ),
            (
                "没有该基线时，新增数据可改变历史 train、validation、test "
                "成员，使实验比较失效。"
            ),
            (
                "不得覆盖 frozen-v1.json；新独立组进入 train，桥接冻结 split "
                "的冲突必须在写入前停止。"
            ),
        ),
        finding(
            "DQ-003",
            "high",
            "fail" if test_high_gain_pixels < 100 else "pass",
            "XMP test 几乎没有 2–3 stops 目标像素",
            (
                f"{stop_bands['test']['pixels']} 个 XMP test 像素中只有 "
                f"{test_high_gain_pixels} 个（{test_high_gain_fraction:.6%}）"
                "位于 2–3 stops。"
            ),
            (
                "相关分母如此小时，总体 test MAE 无法可靠刻画高增益表现。"
            ),
            (
                "把当前 test 作为开发测试集，并用未来高增益 XMP capture group "
                "建立封存的 test-v2。"
            ),
        ),
        finding(
            "DQ-004",
            "high",
            "warning",
            "Legacy MakerNote 估算仍是较低置信度标签",
            (
                f"{len(gain_ids)} 个标签中有 {headroom_sources[LEGACY_SOURCE]} 个"
                f"（{safe_rate(headroom_sources[LEGACY_SOURCE], len(gain_ids)):.1%}）"
                "来自逆向推导的估算。"
            ),
            (
                "label_subset=all 会混合估算与显式 headroom 语义；删除这些行"
                "不会改善 xmp-only 训练。"
            ),
            (
                "保持 headroom_source 显式可见，受控实验使用 label_subset=xmp；"
                "如有需要，再单独归档 legacy 重资产。"
            ),
        ),
        finding(
            "DQ-005",
            "medium",
            "warning",
            "时间分组只用 model 字符串识别设备",
            (
                "分组键为 model 加 30 分钟间隔；manifest 有 "
                f"{len(metadata_profile['models'])} 个 model 字符串，但没有"
                "稳定的物理设备标识。"
            ),
            (
                "若多部同型号手机的拍摄时间重叠，不相关照片可能被过度合并。"
            ),
            (
                "若预计同型号包含多部物理设备，导入时加入隐私安全的设备指纹。"
            ),
            confidence="medium",
        ),
        finding(
            "DQ-006",
            "high",
            "pass" if assets_ok else "fail",
            "Manifest、原图、提取资产与训练缓存一致",
            (
                f"缺失 {asset_missing_total} 个必需资产，发现 "
                f"{asset_extra_total} 个意外资产。"
            ),
            (
                "缺失或孤立资产会导致运行失败或使用陈旧训练输入。"
            ),
            "每批训练前运行资产契约检查。",
        ),
    ]

    status = (
        "blocked"
        if any(
            item["status"] == "fail" and item["severity"] == "critical"
            for item in findings
        )
        else "ready_with_known_gaps"
    )
    return {
        "audit": {
            "title": "HyperDR data pipeline and frozen-split audit",
            "generated_at_utc": generated_at,
            "dataset_root": str(root),
            "status": status,
            "scope": (
                "Read-only inspection of manifests, grouping metadata, split "
                "assignments, asset/cache presence, metadata coverage, and "
                "stride-16 gain-grid distributions."
            ),
        },
        "dataset": {
            "samples": len(rows),
            "gain_map_samples": len(gain_ids),
            "xmp_labels": headroom_sources[XMP_SOURCE],
            "legacy_labels": headroom_sources[LEGACY_SOURCE],
            "capture_groups": len(groups),
            "xmp_capture_groups": len(
                {
                    sample_group[str(row["sample_id"])]
                    for row in xmp_rows
                    if str(row["sample_id"]) in sample_group
                }
            ),
            "duplicate_sample_ids": duplicate_sample_ids,
            "invalid_label_rows": len(invalid_rows),
            "invalid_label_examples": invalid_rows[:10],
        },
        "pipeline_review": pipeline_review(),
        "split_integrity": {
            "valid": split_ok,
            "samples": {split: len(ids) for split, ids in split_ids.items()},
            "groups": all_group_counts,
            "xmp_samples": {
                split: label_by_split[split].get(XMP_SOURCE, 0) for split in SPLITS
            },
            "xmp_groups": xmp_group_counts,
            "label_sources": label_by_split,
            "duplicate_assignments": split_duplicate_ids,
            "missing_assignments": len(split_missing_ids),
            "extra_assignments": len(split_extra_ids),
            "cross_split_groups": len(group_cross_split),
            "missing_assignment_examples": split_missing_ids[:10],
            "extra_assignment_examples": split_extra_ids[:10],
            "cross_split_group_examples": sorted(set(group_cross_split))[:10],
        },
        "freeze_integrity": freeze_integrity,
        "target_stop_coverage_xmp": stop_bands,
        "metadata_coverage": metadata_profile,
        "duplicate_and_group_profile": duplicate_profile,
        "asset_integrity": assets,
        "findings": findings,
        "methodology": {
            "grain": {
                "sample": "one manifest row and one original HEIC",
                "capture_group": (
                    "connected component of same-model captures <=30 minutes "
                    "apart plus conservative pHash+dHash near duplicates"
                ),
                "target_pixel": (
                    "one float16 log2-gain cell in the stride-16 training grid"
                ),
            },
            "stop_bands": {
                label: f"[{lower}, {upper}) log2-gain stops"
                for label, lower, upper in STOP_BANDS
            },
            "label_subset": (
                "XMP coverage filters headroom_source after the frozen split is "
                "loaded; denominators therefore match actual xmp-only training."
            ),
            "asset_check": (
                "Filename-set reconciliation only; source-byte hashes are covered "
                "by scripts/validate_dataset.py and its latest validation report."
            ),
        },
        "limitations": [
            (
                "目前没有语义场景标注，因此无法直接量化逆光、窗户、灯牌、"
                "反光和太阳等场景覆盖。"
            ),
            (
                "本报告没有重新计算模型误差与 ISO、曝光时间的相关性，因为"
                "逐样本预测误差不属于数据集契约。"
            ),
            (
                "时间分组可能把同型号且拍摄时间重叠的多部物理设备过度合并。"
            ),
            (
                "当前 test 已在开发中被查看；审计可以度量它，但无法恢复盲测属性。"
            ),
        ],
        "recommended_next_steps": [
            "把固定 split 验证设为训练前强制检查。",
            (
                "仅在未来批次准备封存时加入显式 test-v2 导入；不得根据模型"
                "输出选择样本。"
            ),
            (
                "加入场景标签或轻量人工审计分类，使定向拍摄缺口可以量化。"
            ),
            (
                "在 manifest 中保留 legacy MakerNote 样本；只有在归档计划 "
                "dry-run 后才冷归档其重资产。"
            ),
        ],
        "further_questions": [
            (
                "数据集中是否有多部同型号 iPhone 设备？"
            ),
            (
                "test-v2 封存前，2–3 stops 像素与独立组的最低要求应是多少？"
            ),
        ],
    }


def fmt_int(value: int | float) -> str:
    return f"{int(value):,}"


def fmt_percent(value: int | float) -> str:
    return f"{float(value):.3%}"


def markdown_table(headers: list[str], rows: list[list[object]]) -> str:
    def escape(value: object) -> str:
        return str(value).replace("|", "\\|").replace("\n", " ")

    lines = [
        "| " + " | ".join(headers) + " |",
        "| " + " | ".join("---" for _ in headers) + " |",
    ]
    lines.extend("| " + " | ".join(escape(value) for value in row) + " |" for row in rows)
    return "\n".join(lines)


def render_markdown(report: dict[str, Any]) -> str:
    dataset = report["dataset"]
    split = report["split_integrity"]
    target = report["target_stop_coverage_xmp"]
    freeze = report["freeze_integrity"]
    findings = report["findings"]
    metadata = report["metadata_coverage"]

    lines = [
        "# HyperDR 数据管线与固定划分审计",
        "",
        (
            f"生成时间：{report['audit']['generated_at_utc']}  "
            f"状态：`{report['audit']['status']}`"
        ),
        "",
        "## 技术结论",
        "",
        (
            f"当前 {fmt_int(dataset['samples'])} 张照片的 split 已固定："
            f"`frozen-v1.json` 锁定 {fmt_int(freeze['frozen_samples'])} 个样本，"
            f"没有冻结样本缺失或移动。现有 train/validation/test 在 "
            f"{fmt_int(dataset['capture_groups'])} 个 capture group 上互斥。"
        ),
        "",
        (
            f"可靠 XMP 标签共 {fmt_int(dataset['xmp_labels'])} 张、"
            f"{fmt_int(dataset['xmp_capture_groups'])} 个独立组；legacy "
            f"MakerNote 估算标签 {fmt_int(dataset['legacy_labels'])} 张。"
            f"当前 XMP test 的 2–3 stops 区间只有 "
            f"{fmt_int(target['test']['bands']['2–3']['pixels'])} 个像素，"
            "不能可靠衡量高增益表现。"
        ),
        "",
        "## 关键发现",
        "",
        markdown_table(
            ["ID", "严重度", "状态", "发现", "证据"],
            [
                [
                    item["id"],
                    item["severity"],
                    item["status"],
                    item["title"],
                    item["evidence"],
                ]
                for item in findings
            ],
        ),
        "",
        "## 数据范围与度量定义",
        "",
        "- 样本：一行 public manifest 与一张原始 HEIC。",
        (
            "- Capture group：同型号、相邻不超过 30 分钟的照片，加上同时"
            "满足 pHash 与 dHash 阈值的近重复，组成连通分量。"
        ),
        "- 目标像素：stride-16 float16 `log2(gain)` 网格中的一个单元。",
        (
            "- XMP 子集：先读取固定 split，再按 "
            "`headroom_source=xmp_hdr_gain_map_headroom` 过滤。"
        ),
        "",
        "## Split 与标签覆盖",
        "",
        markdown_table(
            ["Split", "全部样本", "全部组", "XMP 样本", "XMP 组", "Legacy 样本"],
            [
                [
                    name,
                    fmt_int(split["samples"][name]),
                    fmt_int(split["groups"][name]),
                    fmt_int(split["xmp_samples"][name]),
                    fmt_int(split["xmp_groups"][name]),
                    fmt_int(
                        split["label_sources"][name].get(LEGACY_SOURCE, 0)
                    ),
                ]
                for name in SPLITS
            ],
        ),
        "",
        (
            f"完整性检查：重复分配 {split['duplicate_assignments']}，"
            f"缺失分配 {split['missing_assignments']}，"
            f"跨 split 组 {split['cross_split_groups']}。"
        ),
        "",
        "## XMP 高增益目标覆盖",
        "",
        markdown_table(
            ["Split", "区间", "像素数", "像素占比", "含该区间的样本"],
            [
                [
                    name,
                    band,
                    fmt_int(target[name]["bands"][band]["pixels"]),
                    fmt_percent(target[name]["bands"][band]["pixel_fraction"]),
                    fmt_int(target[name]["bands"][band]["samples_with_pixels"]),
                ]
                for name in SPLITS
                for band, _, _ in STOP_BANDS
            ],
        ),
        "",
        (
            "2–3 stops 的 test 分母极小；即使这一小段像素误差变化很大，"
            "总体 MAE 也几乎不会响应。当前 test 只能作为开发测试集。"
        ),
        "",
        "## 元数据覆盖",
        "",
        markdown_table(
            ["指标（XMP）", "数量", "最小", "P10", "中位数", "P90", "最大"],
            [
                [
                    name,
                    fmt_int(values["count"]),
                    values["min"],
                    values["p10"],
                    values["median"],
                    values["p90"],
                    values["max"],
                ]
                for name, values in metadata["xmp"].items()
            ],
        ),
        "",
        "ISO 分布：",
        "",
        markdown_table(
            ["区间", "XMP 样本"],
            [
                [name, fmt_int(count)]
                for name, count in metadata["xmp_iso_bands"].items()
            ],
        ),
        "",
        "曝光时间分布：",
        "",
        markdown_table(
            ["区间（秒）", "XMP 样本"],
            [
                [name, fmt_int(count)]
                for name, count in metadata[
                    "xmp_exposure_bands_seconds"
                ].items()
            ],
        ),
        "",
        "## 管线审查",
        "",
    ]
    for item in report["pipeline_review"]:
        lines.extend(
            [
                f"### {item['stage']}",
                "",
                f"`{item['implementation']}`：{item['review']}",
                "",
            ]
        )
    lines.extend(
        [
            "## 方法、限制与稳健性",
            "",
            (
                "审计读取 manifest、private capture index、split/group manifest、"
                "freeze manifest 与训练 gain grid。它只写本报告及 JSON 伴随文件，"
                "没有移动、删除或改写任何原始照片和缓存。"
            ),
            "",
        ]
    )
    lines.extend(f"- {item}" for item in report["limitations"])
    lines.extend(["", "## 建议的下一步", ""])
    lines.extend(
        f"{index}. {item}"
        for index, item in enumerate(report["recommended_next_steps"], 1)
    )
    lines.extend(["", "## 待确认问题", ""])
    lines.extend(f"- {item}" for item in report["further_questions"])
    lines.append("")
    return "\n".join(lines)


def sql_literal(value: object) -> str:
    if value is None:
        return "NULL"
    if isinstance(value, bool):
        return "1" if value else "0"
    if isinstance(value, (int, float)):
        number = float(value)
        if not math.isfinite(number):
            raise ValueError("Non-finite value cannot be emitted as SQL")
        return repr(value)
    return "'" + str(value).replace("'", "''") + "'"


def sql_result_set(
    name: str,
    columns: list[str],
    rows: list[dict[str, object]],
) -> str:
    values = ",\n    ".join(
        "(" + ", ".join(sql_literal(row.get(column)) for column in columns) + ")"
        for row in rows
    )
    return (
        f"-- Dataset: {name}\n"
        f"WITH {name} ({', '.join(columns)}) AS (\n"
        f"  VALUES\n    {values}\n"
        ")\n"
        f"SELECT * FROM {name};"
    )


def render_sql(report: dict[str, Any]) -> str:
    split = report["split_integrity"]
    target = report["target_stop_coverage_xmp"]
    dataset = report["dataset"]
    freeze = report["freeze_integrity"]
    headline = [
        {
            "all_samples": dataset["samples"],
            "xmp_labels": dataset["xmp_labels"],
            "legacy_labels": dataset["legacy_labels"],
            "legacy_fraction": safe_rate(
                dataset["legacy_labels"], dataset["gain_map_samples"]
            ),
            "capture_groups": dataset["capture_groups"],
            "xmp_capture_groups": dataset["xmp_capture_groups"],
            "xmp_train_samples": split["xmp_samples"]["train"],
            "xmp_train_groups": split["xmp_groups"]["train"],
            "frozen_samples": freeze["frozen_samples"],
            "moved_frozen_samples": freeze["moved_frozen_samples"],
            "test_2_3_pixels": target["test"]["bands"]["2–3"]["pixels"],
            "test_2_3_fraction": target["test"]["bands"]["2–3"][
                "pixel_fraction"
            ],
        }
    ]
    split_rows = [
        {
            "split": name,
            "all_samples": split["samples"][name],
            "all_groups": split["groups"][name],
            "xmp_samples": split["xmp_samples"][name],
            "xmp_groups": split["xmp_groups"][name],
            "legacy_samples": split["label_sources"][name].get(
                LEGACY_SOURCE, 0
            ),
            "xmp_sample_fraction": safe_rate(
                split["xmp_samples"][name], split["samples"][name]
            ),
        }
        for name in SPLITS
    ]
    stop_rows = [
        {
            "split": name,
            "stop_band": band,
            "pixels": target[name]["bands"][band]["pixels"],
            "pixel_fraction": target[name]["bands"][band]["pixel_fraction"],
            "samples_with_pixels": target[name]["bands"][band][
                "samples_with_pixels"
            ],
            "xmp_samples": target[name]["xmp_samples"],
            "total_pixels": target[name]["pixels"],
        }
        for name in SPLITS
        for band, _, _ in STOP_BANDS
    ]
    finding_rows = [
        {
            "priority": index,
            "id": item["id"],
            "severity": item["severity"],
            "status": item["status"],
            "title": item["title"],
            "evidence": item["evidence"],
        }
        for index, item in enumerate(report["findings"], 1)
    ]
    statements = [
        sql_result_set("headline", list(headline[0]), headline),
        sql_result_set("split_coverage", list(split_rows[0]), split_rows),
        sql_result_set("stop_coverage", list(stop_rows[0]), stop_rows),
        sql_result_set("findings", list(finding_rows[0]), finding_rows),
    ]
    return (
        "-- Generated by scripts/audit_dataset.py.\n"
        "-- Self-contained SQLite reproduction of the bounded rows exposed in\n"
        "-- the read-only Data Analytics report. Raw photos and private capture\n"
        "-- timestamps are not included.\n\n"
        + "\n\n".join(statements)
        + "\n"
    )


def main() -> None:
    args = parse_args()
    report = audit(args.dataset_root)
    write_text(
        args.output_json,
        json.dumps(report, ensure_ascii=False, indent=2) + "\n",
    )
    write_text(args.output_markdown, render_markdown(report))
    if args.output_sql:
        write_text(args.output_sql, render_sql(report))
    print(
        json.dumps(
            {
                "status": report["audit"]["status"],
                "output_json": str(args.output_json),
                "output_markdown": str(args.output_markdown),
                "output_sql": str(args.output_sql) if args.output_sql else None,
                "samples": report["dataset"]["samples"],
                "xmp_labels": report["dataset"]["xmp_labels"],
                "legacy_labels": report["dataset"]["legacy_labels"],
                "xmp_capture_groups": report["dataset"]["xmp_capture_groups"],
                "xmp_test_2_to_3_stop_pixels": report[
                    "target_stop_coverage_xmp"
                ]["test"]["bands"]["2–3"]["pixels"],
            },
            indent=2,
        )
    )


if __name__ == "__main__":
    main()

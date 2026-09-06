#!/usr/bin/env python3
"""Build CHW linear-P3 tensors through HyperDR's deployed model-input path.

This cache is intentionally separate from ``training/linear_p3_f16``.  It is a
domain-shift probe (or an explicit production-v4 training input), not a rewrite
of the immutable production-v3 cache.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

import cv2
import numpy as np


def subprocess_path(path: Path, *, windows_executable: bool) -> str:
    """Translate WSL paths when invoking a Windows HyperDR executable."""
    if not windows_executable:
        return str(path)
    translated = subprocess.run(
        ["wslpath", "-w", str(path)], check=True, capture_output=True, text=True
    ).stdout.strip()
    if not translated:
        raise RuntimeError(f"could not translate WSL path for Windows: {path}")
    return translated


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def atomic_npy(path: Path, value: np.ndarray) -> None:
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    with temporary.open("wb") as target:
        np.save(target, value, allow_pickle=False)
    os.replace(temporary, path)


def sample_ids(root: Path, split: str, label_subset: str) -> list[str]:
    if split == "development":
        # The CV registry is the only development-membership authority.  Do
        # not open test.json here: its 41 ISO samples are deliberately absent
        # from sample_fold, leaving exactly the 418 development samples.
        folds = json.loads((root / "splits" / "cv-folds-v1.json").read_text())
        selected = sorted(str(value) for value in folds["sample_fold"])
    elif split == "all":
        selected = sorted(
            str(json.loads(line)["sample_id"])
            for line in (root / "manifests" / "samples.jsonl").read_text().splitlines()
            if line.strip()
        )
    else:
        record = json.loads((root / "splits" / f"{split}.json").read_text())
        selected = [str(value) for value in record["sample_ids"]]
    if label_subset == "all":
        return selected
    source_type = {
        "iso_native": "iso_21496_1_tmap",
        "legacy_apple": "legacy_apple",
    }[label_subset]
    eligible = {
        str(row["sample_id"])
        for row in (
            json.loads(line)
            for line in (root / "manifests" / "training-cache-v2.jsonl").read_text().splitlines()
            if line.strip()
        )
        if row.get("source_type") == source_type
    }
    return [sample_id for sample_id in selected if sample_id in eligible]


def find_source(directory: Path, sample_id: str) -> Path:
    matches = [path for path in directory.glob(f"{sample_id}.*") if path.is_file()]
    if len(matches) != 1:
        raise RuntimeError(
            f"{sample_id}: expected one source below {directory}, found {len(matches)}"
        )
    return matches[0]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset-root", type=Path, default=Path.home() / "datasets/hyperdr-apple")
    parser.add_argument("--hyperdr-exe", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--source-dir", type=Path)
    parser.add_argument(
        "--fallback-sdr-dir",
        type=Path,
        help=(
            "optional extracted SDR proxy directory used only when HyperDR cannot "
            "decode an original; every fallback and original error is recorded"
        ),
    )
    parser.add_argument(
        "--split",
        choices=("development", "train", "validation", "test", "all"),
        default="development",
        help="development reads only cv-folds sample_fold and never opens test.json",
    )
    parser.add_argument("--label-subset", choices=("iso_native", "legacy_apple", "all"), default="iso_native")
    parser.add_argument("--long-side", type=int, default=1024)
    parser.add_argument("--highlight-recovery", choices=("clip", "unclip", "blend", "reconstruct"), default="blend")
    parser.add_argument("--resume", action="store_true")
    parser.add_argument(
        "--target-output-dir",
        type=Path,
        help=(
            "write paired signed-stop targets rebased from the frozen HDR "
            "alternate onto each newly generated deployment SDR base"
        ),
    )
    parser.add_argument("--reference-input-dir", type=Path)
    parser.add_argument("--reference-target-dir", type=Path)
    parser.add_argument(
        "--reuse-input-dir",
        type=Path,
        help="copy already-validated deployment tensors into a fresh membership-scoped cache",
    )
    args = parser.parse_args()

    root = args.dataset_root.resolve()
    source_dir = (args.source_dir or root / "originals").resolve()
    output = args.output_dir.resolve()
    target_output = args.target_output_dir.resolve() if args.target_output_dir else None
    reference_input = (
        args.reference_input_dir.resolve()
        if args.reference_input_dir
        else root / "training" / "linear_p3_f16"
    )
    reference_target = (
        args.reference_target_dir.resolve()
        if args.reference_target_dir
        else root / "training" / "gain_grid_stride16_f32_v2"
    )
    reuse_input = args.reuse_input_dir.resolve() if args.reuse_input_dir else None
    if args.long_side < 16:
        parser.error("--long-side must be at least 16")
    if not args.hyperdr_exe.is_file():
        raise SystemExit(f"HyperDR executable does not exist: {args.hyperdr_exe}")
    output.mkdir(parents=True, exist_ok=True)
    if target_output is not None:
        target_output.mkdir(parents=True, exist_ok=True)
    manifest_path = output / "deployment-cache.jsonl"
    if manifest_path.exists() and not args.resume:
        raise SystemExit(f"{manifest_path} already exists; use a new directory or --resume")

    rows: list[dict[str, object]] = []
    windows_executable = os.name != "nt" and args.hyperdr_exe.suffix.lower() == ".exe"
    for index, sample_id in enumerate(sample_ids(root, args.split, args.label_subset), 1):
        destination = output / f"{sample_id}.npy"
        source = find_source(source_dir, sample_id)
        row: dict[str, object]
        if destination.is_file() and args.resume:
            tensor = np.load(destination, allow_pickle=False)
            row = {
                "sample_id": sample_id,
                "source": str(source),
                "source_sha256": sha256_file(source),
                "tensor_shape": list(tensor.shape),
                "tensor_sha256": sha256_file(destination),
                "reused": True,
            }
        elif reuse_input is not None and (reuse_input / f"{sample_id}.npy").is_file():
            reused_source = reuse_input / f"{sample_id}.npy"
            shutil.copyfile(reused_source, destination)
            tensor = np.load(destination, allow_pickle=False)
            if tensor.ndim != 3 or tensor.shape[0] != 3 or not np.isfinite(tensor).all():
                raise RuntimeError(f"{sample_id}: reused deployment tensor is incompatible")
            row = {
                "sample_id": sample_id,
                "source": str(source),
                "source_sha256": sha256_file(source),
                "tensor_shape": list(tensor.shape),
                "tensor_sha256": sha256_file(destination),
                "reused": True,
                "reused_input_from": str(reused_source),
            }
        else:
          with tempfile.TemporaryDirectory(prefix="hyperdr-deployment-cache-") as temporary:
            raw = Path(temporary) / "input.f32"
            report_path = Path(temporary) / "input.json"
            command = [
                str(args.hyperdr_exe), "model-input",
                subprocess_path(source, windows_executable=windows_executable),
                "--output", subprocess_path(raw, windows_executable=windows_executable),
                "--report", subprocess_path(report_path, windows_executable=windows_executable),
                "--long-side", str(args.long_side),
                "--highlight-recovery", args.highlight_recovery,
            ]
            completed = subprocess.run(command, check=False, capture_output=True, text=True)
            original_error = None
            if completed.returncode:
                original_error = (
                    f"HyperDR model-input failed ({completed.returncode}): "
                    f"{completed.stderr.strip() or completed.stdout.strip()}"
                )
                if args.fallback_sdr_dir is None:
                    raise RuntimeError(f"{sample_id}: {original_error}")
                fallback = find_source(args.fallback_sdr_dir.resolve(), sample_id)
                command[2] = subprocess_path(
                    fallback, windows_executable=windows_executable
                )
                completed = subprocess.run(
                    command, check=False, capture_output=True, text=True
                )
                if completed.returncode:
                    raise RuntimeError(
                        f"{sample_id}: {original_error}; fallback also failed: "
                        f"{completed.stderr.strip() or completed.stdout.strip()}"
                    )
                source = fallback
            report = json.loads(report_path.read_text())
            pixel = report["pixel_file"]
            width, height = int(pixel["width"]), int(pixel["height"])
            if pixel.get("layout") != "HWC" or pixel.get("color_space") != "linear Display P3":
                raise RuntimeError(f"{sample_id}: HyperDR returned an incompatible pixel contract")
            hwc = np.fromfile(raw, dtype="<f4")
            if hwc.size != width * height * 3:
                raise RuntimeError(f"{sample_id}: raw tensor length does not match its report")
            chw = hwc.reshape(height, width, 3).transpose(2, 0, 1).copy()
            if not np.isfinite(chw).all() or chw.min() < 0.0 or chw.max() > 1.0:
                raise RuntimeError(f"{sample_id}: deployment tensor is outside finite SDR [0,1]")
            atomic_npy(destination, chw)
            row = {
                "sample_id": sample_id,
                "source": str(source),
                "source_sha256": sha256_file(source),
                "tensor_shape": list(chw.shape),
                "tensor_sha256": sha256_file(destination),
                "model_input_report": report,
                "original_decode_error": original_error,
                "reused": False,
            }
        if target_output is not None:
            old_input = np.load(reference_input / f"{sample_id}.npy", allow_pickle=False).astype(np.float32)
            old_target = np.load(reference_target / f"{sample_id}.npy", allow_pickle=False).astype(np.float32)
            new_input = np.load(destination, allow_pickle=False).astype(np.float32)
            if old_input.shape != new_input.shape or old_input.ndim != 3 or old_input.shape[0] != 3:
                raise RuntimeError(
                    f"{sample_id}: reference/deployment input shape mismatch "
                    f"{old_input.shape} versus {new_input.shape}"
                )
            if old_target.ndim != 3 or old_target.shape[0] != 1:
                raise RuntimeError(f"{sample_id}: incompatible reference target {old_target.shape}")
            coefficients = np.asarray([0.22897456, 0.69173852, 0.07928691], dtype=np.float32)[:, None, None]
            old_log_luma = np.log2(np.maximum((old_input * coefficients).sum(axis=0), 1e-6))
            new_log_luma = np.log2(np.maximum((new_input * coefficients).sum(axis=0), 1e-6))
            grid_height, grid_width = old_target.shape[-2:]
            # Preserve the same low-frequency HDR alternate:
            # log2(HDR) = log2(SDR) + gain.  INTER_AREA matches the frozen
            # stride-16 target builder's spatial averaging convention.
            base_delta = cv2.resize(
                old_log_luma - new_log_luma,
                (grid_width, grid_height),
                interpolation=cv2.INTER_AREA,
            )
            paired_target = old_target + base_delta[None, ...]
            if not np.isfinite(paired_target).all():
                raise RuntimeError(f"{sample_id}: paired deployment target is non-finite")
            target_destination = target_output / f"{sample_id}.npy"
            atomic_npy(target_destination, paired_target.astype(np.float32))
            row["target"] = {
                "file": str(target_destination),
                "shape": list(paired_target.shape),
                "sha256": sha256_file(target_destination),
                "contract": "signed_log2_stops_rebased_to_deployment_sdr/v1",
                "formula": "old_gain + area_mean(log2(old_base_luma)-log2(deployment_base_luma))",
            }
        rows.append(row)
        if index % 25 == 0:
            print(f"processed={index}", flush=True)

    temporary_manifest = manifest_path.with_name(f".{manifest_path.name}.{os.getpid()}.tmp")
    temporary_manifest.write_text(
        "".join(json.dumps(row, separators=(",", ":")) + "\n" for row in rows),
        encoding="utf-8",
    )
    os.replace(temporary_manifest, manifest_path)
    print(json.dumps({"samples": len(rows), "output_dir": str(output)}, indent=2))


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Run the desktop Phase A acceptance gates against a corpus lock."""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
import subprocess
import tempfile

import numpy as np

from hyperdr_ml.phase_a_labels import LABEL_CONTRACT_ID, sha256_file


def _descriptor_rows(root: Path) -> list[dict[str, object]]:
    return json.loads((root / "manifests" / "phase_a_labels_v2.json").read_text(encoding="utf-8"))["rows"]


def _metadata_value(metadata: dict[str, object], key: str) -> float:
    value = metadata[key]
    return float(value["numerator"]) / float(value["denominator"])


def _roundtrip(root: Path, row: dict[str, object]) -> dict[str, float | bool]:
    descriptor_path = root / "manifests" / "phase_a_labels_v2" / f"{row['sample_id']}.json"
    descriptor = json.loads(descriptor_path.read_text(encoding="utf-8"))
    metadata = descriptor["gain_metadata"]
    values = np.fromfile(
        root / "extracted" / "canonical_log2_gain_f32_v2" / f"{row['sample_id']}.f32",
        dtype="<f4",
    )
    gain_min = _metadata_value(metadata, "gain_min")
    gain_max = _metadata_value(metadata, "gain_max")
    gamma = _metadata_value(metadata, "gamma")
    fraction = np.clip((values - gain_min) / (gain_max - gain_min), 0.0, 1.0)
    encoded = np.rint(np.power(fraction, gamma) * 255.0) / 255.0
    decoded = gain_min + (gain_max - gain_min) * np.power(encoded, 1.0 / gamma)
    error = float(np.max(np.abs(decoded - values)))
    threshold = (gain_max - gain_min) / (2.0 * 255.0) + 2.0e-5
    return {"max_stop_error": error, "threshold": threshold, "pass": error <= threshold + 1.0e-7}


def _select_golden(rows: list[dict[str, object]]) -> list[dict[str, object]]:
    native = [row for row in rows if row["source_type"] == "iso_21496_1_tmap"]
    legacy = [row for row in rows if row["source_type"] == "legacy_apple"]
    selected: list[dict[str, object]] = []

    def add(row: dict[str, object]) -> None:
        if row not in selected:
            selected.append(row)

    # Keep the known ICC-only and nclx-only Apple bases in every verdict when
    # the private corpus contains them, then fill the remaining native slots
    # from metadata extrema rather than from filename ordering.
    native_by_id = {str(row["sample_id"]): row for row in native}
    for sample_id in ("apl_00df38e01131375a5553", "apl_79e7b57705b44d784a17"):
        if sample_id in native_by_id:
            add(native_by_id[sample_id])

    def metadata_value(row: dict[str, object], field: str) -> float:
        value = row["gain_metadata"][field]
        return float(value["numerator"]) / float(value["denominator"])

    for field in ("alternate_headroom", "gamma", "gain_min"):
        for reverse in (False, True):
            candidates = sorted(
                native,
                key=lambda row: metadata_value(row, field),
                reverse=reverse,
            )
            if candidates:
                add(candidates[0])
    for row in sorted(native, key=lambda item: str(item["sample_id"])):
        if len([item for item in selected if item["source_type"] == "iso_21496_1_tmap"]) >= 8:
            break
        add(row)

    # Legacy samples have no ISO tmap fields; four headroom quartiles keep the
    # MakerNote piecewise segments represented without pretending they are ISO
    # native labels.
    legacy = sorted(legacy, key=lambda row: float(row["canonical_max_log2_gain"]))
    for index in np.linspace(0, len(legacy) - 1, min(4, len(legacy)), dtype=int):
        add(legacy[int(index)])
    return selected


def _desktop_checks(root: Path, rows: list[dict[str, object]], executable: Path | None) -> dict[str, object]:
    if executable is None:
        return {"enabled": False, "passed": False, "reason": "HyperDR executable was not supplied"}
    checks: list[dict[str, object]] = []
    for row in rows:
        source = root / "originals" / f"{row['sample_id']}.heic"
        completed = subprocess.run(
            [str(executable), "inspect", str(source), "--json"],
            capture_output=True,
            text=True,
            check=False,
        )
        try:
            parsed = json.loads(completed.stdout)
            expected_tmap = row["source_type"] == "iso_21496_1_tmap"
            passed = (
                completed.returncode == 0
                and parsed.get("structurally_valid")
                and bool(parsed.get("tmap_metadata_present")) == expected_tmap
            )
        except json.JSONDecodeError:
            parsed = {"stdout": completed.stdout[-1000:], "stderr": completed.stderr[-1000:]}
            passed = False
        checks.append({"sample_id": row["sample_id"], "passed": bool(passed), "inspection": parsed})
    reconstruct_ids = [
        "apl_00df38e01131375a5553",
        "apl_79e7b57705b44d784a17",
    ]
    reconstruct: list[dict[str, object]] = []
    with tempfile.TemporaryDirectory(prefix="hyperdr-phase-a-") as temporary:
        for sample_id in reconstruct_ids:
            source = root / "originals" / f"{sample_id}.heic"
            if not source.exists():
                continue
            output = Path(temporary) / f"{sample_id}.tiff"
            completed = subprocess.run(
                [str(executable), "verify", str(source), "--reconstruct", str(output)],
                capture_output=True,
                text=True,
                check=False,
            )
            reconstruct.append({
                "sample_id": sample_id,
                "passed": completed.returncode == 0 and output.exists(),
                "stderr": completed.stderr[-1000:],
            })
    external_roundtrip: list[dict[str, object]] = []
    native_rows = [row for row in rows if row["source_type"] == "iso_21496_1_tmap"]
    if native_rows:
        row = native_rows[0]
        sample_id = str(row["sample_id"])
        source = root / "originals" / f"{sample_id}.heic"
        gain = root / "extracted" / "canonical_log2_gain_f32_v2" / f"{sample_id}.f32"
        report = root / "manifests" / "phase_a_labels_v2" / f"{sample_id}.json"
        with tempfile.TemporaryDirectory(prefix="hyperdr-phase-a-external-") as temporary:
            output_dir = Path(temporary) / "encoded"
            output_dir.mkdir()
            completed = subprocess.run(
                [str(executable), "convert", str(source), "--output", str(output_dir),
                 "--overwrite", "--external-gain", str(gain),
                 "--external-gain-report", str(report), "--encoding", "adaptive",
                 "--quality", "100", "--depth", "8"],
                capture_output=True,
                text=True,
                check=False,
            )
            outputs = sorted(output_dir.glob("*.heic"))
            reconstructed = output_dir / "reconstruct.tiff"
            verify = subprocess.run(
                [str(executable), "verify", str(outputs[0]), "--reconstruct", str(reconstructed)],
                capture_output=True,
                text=True,
                check=False,
            ) if completed.returncode == 0 and outputs else None
            external_roundtrip.append({
                "sample_id": sample_id,
                "passed": bool(completed.returncode == 0 and outputs and verify is not None and
                                verify.returncode == 0 and reconstructed.exists()),
                "stderr": ((completed.stderr if completed.returncode != 0 else "") +
                           (verify.stderr if verify is not None and verify.returncode != 0 else ""))[-1000:],
            })
    return {
        "enabled": True,
        "passed": all(item["passed"] for item in checks)
        and all(item["passed"] for item in reconstruct)
        and all(item["passed"] for item in external_roundtrip),
        "inspect": checks,
        "reconstruct": reconstruct,
        "external_roundtrip": external_roundtrip,
    }


def build_report(root: Path, executable: Path | None, output_dir: Path | None = None) -> dict[str, object]:
    lock_path = root / "reports" / "phase-a-corpus-lock.json"
    lock = json.loads(lock_path.read_text(encoding="utf-8"))
    rows = _descriptor_rows(root)
    native = [row for row in rows if row["source_type"] == "iso_21496_1_tmap"]
    legacy = [row for row in rows if row["source_type"] == "legacy_apple"]
    golden = _select_golden(rows)
    roundtrips = [{"sample_id": row["sample_id"], **_roundtrip(root, row)} for row in golden if row["source_type"] == "iso_21496_1_tmap"]
    def metadata(row: dict[str, object]) -> dict[str, object]:
        return json.loads(
            (root / "manifests" / "phase_a_labels_v2" / f"{row['sample_id']}.json")
            .read_text(encoding="utf-8")
        )["gain_metadata"]

    native_metadata_ok = all(
        abs(_metadata_value(metadata(row), "gain_max") - _metadata_value(metadata(row), "alternate_headroom")) <= 1.0e-6
        for row in native
    )
    desktop = _desktop_checks(root, golden, executable)
    checks = {
        "corpus_counts": len(rows) == 811 and len(native) == 423 and len(legacy) == 388,
        "unresolved_zero": lock.get("unresolved") == 0,
        "native_metadata_consistent": native_metadata_ok,
        "negative_gain_min_preserved": sum(
            _metadata_value(metadata(row), "gain_min") < 0
            for row in native
        ) == 382,
        "golden_roundtrip": all(item["pass"] for item in roundtrips),
        "desktop_golden": desktop["passed"],
    }
    failures: list[dict[str, object]] = [
        {"stage": "canonical_iso_roundtrip", **item}
        for item in roundtrips
        if not item["pass"]
    ]
    for item in desktop.get("inspect", []):
        if not item.get("passed", False):
            failures.append({"stage": "desktop_inspect", **item})
    for item in desktop.get("reconstruct", []):
        if not item.get("passed", False):
            failures.append({"stage": "desktop_reconstruct", **item})
    for item in desktop.get("external_roundtrip", []):
        if not item.get("passed", False):
            failures.append({"stage": "desktop_external_roundtrip", **item})
    report = {
        "label_contract_id": LABEL_CONTRACT_ID,
        "formula_version": lock.get("formula_version"),
        "corpus_lock_sha256": sha256_file(lock_path),
        "counts": {"samples": len(rows), "iso_21496_1_tmap": len(native), "legacy_apple": len(legacy)},
        "golden_samples": [row["sample_id"] for row in golden],
        "roundtrip": roundtrips,
        "desktop": desktop,
        "checks": checks,
        "acceptance_thresholds": {
            "canonical_roundtrip_max_stop_error": "(Qmax-Qmin)/(2*255)+2e-5",
            "metadata_field_tolerance": 1.0e-6,
        },
        "failures": failures,
        "pass": all(checks.values()),
    }
    output_dir = output_dir or (root / "reports")
    output_dir.mkdir(parents=True, exist_ok=True)
    (output_dir / "phase-a-label-verdict.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    lines = [
        "# Phase A label verdict",
        "",
        f"- Contract: `{LABEL_CONTRACT_ID}`",
        f"- Corpus: {len(rows)} samples ({len(native)} native ISO, {len(legacy)} legacy)",
        f"- Result: **{'PASS' if report['pass'] else 'FAIL'}**",
        "",
        "| Gate | Result |",
        "| --- | --- |",
    ]
    for name, value in checks.items():
        lines.append(f"| {name} | {'PASS' if value else 'FAIL'} |")
    lines.extend(["", "Golden samples: " + ", ".join(str(row["sample_id"]) for row in golden)])
    lines.extend([
        "",
        f"External Apple → v2 sidecar → HyperDR HEIC → reconstruct: "
        f"{'PASS' if desktop.get('external_roundtrip', [{}])[0].get('passed', False) else 'FAIL'}",
        f"Failure samples recorded: {len(failures)}",
    ])
    (output_dir / "phase-a-label-verdict.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    return report


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path.home() / "datasets" / "hyperdr-apple")
    parser.add_argument("--hyperdr-exe", type=Path)
    parser.add_argument("--output-dir", type=Path)
    args = parser.parse_args()
    report = build_report(args.root, args.hyperdr_exe, args.output_dir)
    print(json.dumps({"pass": report["pass"], "checks": report["checks"]}, indent=2))
    raise SystemExit(0 if report["pass"] else 1)


if __name__ == "__main__":
    main()

from __future__ import annotations

from pathlib import Path
import hashlib
import json

import numpy as np

from hyperdr_ml.phase_a_labels import LABEL_CONTRACT_ID


def write_gain_f32(path: str | Path, gain: np.ndarray) -> dict[str, int | str]:
    """Write and verify the paired-sidecar raw gain-grid interchange format."""
    output = Path(path)
    if output.suffix.lower() != ".f32":
        raise ValueError("Raw gain-grid output must use the .f32 suffix")
    array = np.asarray(gain)
    if array.ndim != 2:
        raise ValueError(f"Gain grid must be HW, got shape {array.shape}")
    if not np.isfinite(array).all():
        raise ValueError("Gain grid contains non-finite values")
    little_endian = np.ascontiguousarray(array, dtype="<f4")
    output.parent.mkdir(parents=True, exist_ok=True)
    little_endian.tofile(output)
    expected_bytes = int(little_endian.size * little_endian.dtype.itemsize)
    actual_bytes = output.stat().st_size
    if actual_bytes != expected_bytes:
        raise IOError(
            f"Gain-grid byte length mismatch: expected {expected_bytes}, got {actual_bytes}"
        )
    return {
        "format": "raw_float32_with_required_json_sidecar",
        "endianness": "little",
        "scale": "normalized_log2_gain_0_to_1",
        "width": int(little_endian.shape[1]),
        "height": int(little_endian.shape[0]),
        "byte_length": actual_bytes,
        "sha256": sha256_file(output),
    }


def read_gain_f32(path: str | Path, *, width: int, height: int) -> np.ndarray:
    """Read raw gain only when the caller supplies and validates both dimensions."""
    if width <= 0 or height <= 0:
        raise ValueError(f"width and height must be positive, got {width}x{height}")
    source = Path(path)
    expected_bytes = width * height * np.dtype("<f4").itemsize
    actual_bytes = source.stat().st_size
    if actual_bytes != expected_bytes:
        raise ValueError(
            f"Gain-grid length is {actual_bytes} bytes; "
            f"{width}x{height} little-endian float32 requires {expected_bytes}"
        )
    return np.fromfile(source, dtype="<f4").reshape(height, width)


def sha256_file(path: str | Path) -> str:
    digest = hashlib.sha256()
    with Path(path).open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def write_gain_f32_v2(
    path: str | Path,
    gain: np.ndarray,
    *,
    metadata: dict[str, object],
    source_type: str,
    confidence: str,
    formula_version: str,
) -> dict[str, object]:
    """Write signed canonical log2 gain and its immutable v2 descriptor.

    The raw file remains a deliberately boring contiguous little-endian grid;
    all semantics are in the JSON object so a consumer cannot infer a range
    from the pixels alone.
    """
    output = Path(path)
    if output.suffix.lower() != ".f32":
        raise ValueError("Canonical gain output must use the .f32 suffix")
    array = np.asarray(gain, dtype=np.float32)
    if array.ndim != 2 or not np.isfinite(array).all():
        raise ValueError("Canonical gain must be finite HW float32")
    little_endian = np.ascontiguousarray(array, dtype="<f4")
    output.parent.mkdir(parents=True, exist_ok=True)
    little_endian.tofile(output)
    byte_length = int(little_endian.nbytes)
    if output.stat().st_size != byte_length:
        raise IOError("Canonical gain byte length changed while writing")
    return {
        "label_contract_id": LABEL_CONTRACT_ID,
        "label_contract_version": 2,
        "gain_grid_size": [int(array.shape[1]), int(array.shape[0])],
        "source_type": source_type,
        "confidence": confidence,
        "formula_version": formula_version,
        "gain_metadata": metadata,
        "gain_file": {
            "format": "raw_float32_with_required_json_sidecar",
            "endianness": "little",
            "scale": "signed_log2_gain",
            "width": int(array.shape[1]),
            "height": int(array.shape[0]),
            "byte_length": byte_length,
            "sha256": sha256_file(output),
        },
    }


def read_gain_f32_v2(path: str | Path, descriptor: dict[str, object]) -> np.ndarray:
    """Read a v2 signed canonical grid after validating its descriptor."""
    if descriptor.get("label_contract_id") != LABEL_CONTRACT_ID:
        raise ValueError("unsupported gain label contract")
    file_info = descriptor.get("gain_file")
    if not isinstance(file_info, dict) or file_info.get("scale") != "signed_log2_gain":
        raise ValueError("v2 sidecar must declare signed_log2_gain")
    try:
        width = int(file_info["width"])
        height = int(file_info["height"])
        byte_length = int(file_info["byte_length"])
    except (KeyError, TypeError, ValueError) as exc:
        raise ValueError("v2 sidecar has invalid dimensions") from exc
    values = read_gain_f32(path, width=width, height=height)
    if values.nbytes != byte_length or not np.isfinite(values).all():
        raise ValueError("v2 canonical gain bytes do not match its sidecar")
    expected_sha = file_info.get("sha256")
    if expected_sha and sha256_file(path) != expected_sha:
        raise ValueError("v2 canonical gain hash does not match its sidecar")
    return values


def write_descriptor(path: str | Path, descriptor: dict[str, object]) -> None:
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = target.with_name(f".{target.name}.tmp")
    temporary.write_text(json.dumps(descriptor, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    temporary.replace(target)

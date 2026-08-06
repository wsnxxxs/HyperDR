"""Optional HyperDR_Model orchestration for one panel conversion.

The model remains a separate Python project. This module only resolves its
runtime configuration and builds the subprocess commands that connect model
inference to HyperDR's external gain-grid input.
"""
from __future__ import annotations

from dataclasses import dataclass
import json
import os
from pathlib import Path
import subprocess
import sys

from .config import IS_WINDOWS, REPO_ROOT


RASTER_INPUT_EXTENSIONS = frozenset({".jpg", ".jpeg", ".png"})
MODEL_ROOT_DEFAULT = (REPO_ROOT / "HyperDR_Model").resolve()
INFERENCE_TIMEOUT_SECONDS = max(
    10, int(os.environ.get("HYPERDR_MODEL_TIMEOUT_SECONDS", "300"))
)


class ModelConfigurationError(ValueError):
    """The model was requested but its runtime is not usable."""


@dataclass(frozen=True)
class ModelConfig:
    root: Path
    python: str
    script: Path
    checkpoint: Path
    dataset_root: Path
    device: str
    long_side: int
    allow_legacy_label_schema: bool = False


def _enabled() -> bool:
    configured = os.environ.get("HYPERDR_MODEL_ENABLED")
    if configured is not None:
        return configured.strip().lower() in {"1", "true", "yes", "on"}
    if os.environ.get("HYPERDR_MODEL_CHECKPOINT", "").strip():
        return True
    # The packaged Windows workspace includes a checkpoint and runtime. Since
    # inference is now user-triggered, making the button available has no
    # startup or import cost; HYPERDR_MODEL_ENABLED=0 remains the explicit off.
    return bool(_find_checkpoint(MODEL_ROOT_DEFAULT))


def _find_checkpoint(root: Path) -> Path | None:
    for folder_name in ("runs", "checkpoints"):
        folder = root / folder_name
        if not folder.is_dir():
            continue
        candidates = sorted(folder.rglob("*.pt")) + sorted(folder.rglob("*.pth"))
        if candidates:
            return candidates[0].resolve()
    return None


def _python_runtime(root: Path) -> str:
    configured = os.environ.get("HYPERDR_MODEL_PYTHON", "").strip()
    if configured:
        return configured

    candidates = [
        root / ".venv" / "Scripts" / "python.exe",
        root / ".venv" / "bin" / "python",
    ]
    # A lean release intentionally omits PyTorch. When it is unpacked somewhere
    # below an existing HyperDR workspace (for example dist-latest-test/), find
    # that workspace's already configured CUDA venv automatically. This keeps
    # Start.bat double-clickable without hard-coding a user-specific path.
    if IS_WINDOWS:
        for ancestor in REPO_ROOT.parents:
            candidates.extend([
                ancestor / "HyperDR_Model" / ".venv" / "Scripts" / "python.exe",
                ancestor / "HyperDR" / "HyperDR_Model" / ".venv"
                / "Scripts" / "python.exe",
            ])
    for candidate in candidates:
        if candidate.is_file():
            return str(candidate)
    return sys.executable


def _long_side() -> int:
    raw = os.environ.get("HYPERDR_MODEL_LONG_SIDE", "1024")
    try:
        value = int(raw)
    except ValueError as exc:
        raise ModelConfigurationError("HYPERDR_MODEL_LONG_SIDE must be an integer") from exc
    if not 16 <= value <= 8192:
        raise ModelConfigurationError("HYPERDR_MODEL_LONG_SIDE must be in [16, 8192]")
    return value


def _paths() -> tuple[Path, Path, Path, Path]:
    root = Path(os.environ.get("HYPERDR_MODEL_ROOT", str(MODEL_ROOT_DEFAULT))).resolve()
    script = root / "infer_gain.py"
    configured_checkpoint = os.environ.get("HYPERDR_MODEL_CHECKPOINT", "").strip()
    checkpoint = (Path(configured_checkpoint).expanduser().resolve()
                  if configured_checkpoint else (_find_checkpoint(root) or Path()))
    dataset_default = root / "dataset"
    dataset = Path(os.environ.get("HYPERDR_MODEL_DATASET_ROOT", str(dataset_default)))
    return root, script, checkpoint, dataset.resolve()


def load_config() -> ModelConfig | None:
    """Return a validated config, or ``None`` when model mode is disabled."""
    if not _enabled():
        return None
    root, script, checkpoint, dataset_root = _paths()
    missing = []
    if not root.is_dir():
        missing.append(f"model root {root}")
    if not script.is_file():
        missing.append(f"inference script {script}")
    if not checkpoint.is_file():
        missing.append("HYPERDR_MODEL_CHECKPOINT")
    if not dataset_root.is_dir():
        missing.append(f"dataset root {dataset_root}")
    if not (dataset_root / "assets" / "display-p3.icc").is_file():
        missing.append(f"Display P3 profile {dataset_root / 'assets' / 'display-p3.icc'}")
    allow_legacy = os.environ.get("HYPERDR_MODEL_ALLOW_LEGACY_LABEL_SCHEMA", "").strip().lower() in {"1", "true", "yes", "on"}
    declared_contract = os.environ.get("HYPERDR_MODEL_LABEL_CONTRACT", "v1").strip().lower()
    if declared_contract != "v2" and not allow_legacy:
        missing.append("legacy checkpoint requires HYPERDR_MODEL_ALLOW_LEGACY_LABEL_SCHEMA=1")
    if missing:
        raise ModelConfigurationError(
            "HyperDR_Model is enabled but not ready: " + "; ".join(missing)
        )
    device = os.environ.get("HYPERDR_MODEL_DEVICE", "auto").strip().lower()
    if device not in {"auto", "cuda", "cpu"}:
        raise ModelConfigurationError("HYPERDR_MODEL_DEVICE must be auto, cuda, or cpu")
    return ModelConfig(
        root=root,
        python=_python_runtime(root),
        script=script,
        checkpoint=checkpoint,
        dataset_root=dataset_root,
        device=device,
        long_side=_long_side(),
        allow_legacy_label_schema=allow_legacy,
    )


def status() -> dict[str, object]:
    """Return non-throwing state suitable for ``/api/state``."""
    enabled = _enabled()
    if not enabled:
        return {"enabled": False, "ready": False,
                "reason": "set HYPERDR_MODEL_ENABLED=1 and configure a checkpoint"}
    try:
        config = load_config()
    except ModelConfigurationError:
        # Do not expose local filesystem paths through the browser API.
        return {"enabled": True, "ready": False,
                "reason": "HyperDR_Model is enabled but its runtime is not ready"}
    assert config is not None
    try:
        probe = subprocess.run(
            [
                config.python, "-c",
                "import numpy, torch; from PIL import Image, ImageCms",
            ],
            capture_output=True, timeout=20, check=False,
        )
    except (OSError, subprocess.SubprocessError):
        probe = None
    if probe is None or probe.returncode != 0:
        return {
            "enabled": True,
            "ready": False,
            "reason": "configured Python does not provide PyTorch, NumPy and Pillow",
        }
    return {"enabled": True, "ready": True, "device": config.device,
            "longSide": config.long_side}


def build_commands(config: ModelConfig, source: Path, model_dir: Path,
                   converter_exe: str, highlight_recovery: str = "blend") -> tuple[list[list[str]], Path, Path]:
    """Build optional thumbnail/model steps and return gain paths.

    Pillow inference accepts raster inputs directly. RAW/HEIC inputs first pass
    through HyperDR's own thumbnail decoder, so the model can still participate
    in the same panel flow without teaching the training project about camera
    codecs.
    """
    model_dir.mkdir(parents=True, exist_ok=True)
    gain_path = model_dir / "model-gain.f32"
    report_path = model_dir / "model-gain.json"
    commands: list[list[str]] = []
    model_input = source
    if source.suffix.lower() not in RASTER_INPUT_EXTENSIONS:
        model_input = model_dir / "model-input.jpg"
        commands.append([
            converter_exe, "thumbnail", str(source), "--output", str(model_input),
            "--max-edge", str(config.long_side), "--quality", "100",
            "--highlight-recovery", highlight_recovery,
            "--base-only",
        ])
    commands.append([
        config.python, str(config.script),
        "--input", str(model_input),
        "--checkpoint", str(config.checkpoint),
        "--gain-output", str(gain_path),
        "--report", str(report_path),
        "--dataset-root", str(config.dataset_root),
        "--long-side", str(config.long_side),
        "--device", config.device,
    ])
    if config.allow_legacy_label_schema:
        commands[-1].append("--allow-legacy-label-schema")
    return commands, gain_path, report_path


def infer_preview(config: ModelConfig, source: Path, model_dir: Path,
                  converter_exe: str,
                  highlight_recovery: str = "blend") -> tuple[bytes, dict]:
    """Run inference now and return the validated browser-preview gain grid."""
    commands, gain_path, report_path = build_commands(
        config, source, model_dir, converter_exe, highlight_recovery
    )
    for command in commands:
        try:
            completed = subprocess.run(
                command, cwd=str(config.root), capture_output=True,
                timeout=INFERENCE_TIMEOUT_SECONDS, check=False,
            )
        except (OSError, subprocess.SubprocessError) as exc:
            raise RuntimeError("unable to run model inference: %s" % exc) from exc
        if completed.returncode != 0:
            detail = completed.stderr.decode("utf-8", errors="replace").strip()
            raise RuntimeError(detail or "model inference failed")

    report = json.loads(report_path.read_text(encoding="utf-8"))
    grid = report.get("gain_grid_size")
    max_stops = report.get("metadata_gain_max_stops")
    if (not isinstance(grid, list) or len(grid) != 2
            or not all(isinstance(value, int) and value > 0 for value in grid)
            or not isinstance(max_stops, (int, float))
            or not 0 <= float(max_stops) <= 4):
        raise ValueError("model inference produced an invalid gain report")
    gain = gain_path.read_bytes()
    if len(gain) != grid[0] * grid[1] * 4:
        raise ValueError("model gain byte length does not match its report")
    return gain, report

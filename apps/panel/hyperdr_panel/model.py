"""Native AI model capability and preview orchestration.

The panel no longer owns a Python model environment or a gain-grid sidecar.
The converter receives the uploaded source and the embedded model marker, then
performs development, inference, filtering and post-adjustment in memory. This
module is deliberately small: it only gates the feature, runs the optional
button-time probe, and validates the packet returned on stdout.
"""
from __future__ import annotations

from contextlib import nullcontext
import json
import math
import os
from pathlib import Path
import subprocess

from .concurrency import RAW_DECODE_BUDGET, SingleFlight
from .config import REPO_ROOT
from .executable import detect_exe
from .formats import RAW_INPUT_EXTENSIONS


NATIVE_MODEL_ARTIFACT = "embedded"
NATIVE_MODEL_GAIN_MAGIC = b"HYPGAIN1\n"
INFERENCE_TIMEOUT_SECONDS = max(
    10, int(os.environ.get("HYPERDR_MODEL_TIMEOUT_SECONDS", "300"))
)
_INFERENCE_FLIGHT = SingleFlight()


def _enabled() -> bool:
    """Whether the native model feature is enabled by operator policy."""
    configured = os.environ.get("HYPERDR_MODEL_ENABLED")
    if configured is None:
        return True
    return configured.strip().lower() in {"1", "true", "yes", "on"}


def _native_executable() -> str:
    """Return the converter path when the native binary is available."""
    return detect_exe() or ""


def status() -> dict[str, object]:
    """Return a non-blocking native-model capability for ``/api/state``.

    A checkpoint, Python interpreter and import probe are intentionally absent:
    the model is owned by the native runtime. The executable locator is the
    capability boundary; an unavailable runtime reports its actionable error
    when the button starts a native request.
    """
    if not _enabled():
        return {
            "enabled": False,
            "ready": False,
            "reason": "AI 优化已由 HYPERDR_MODEL_ENABLED 关闭",
        }
    if not _native_executable():
        return {
            "enabled": True,
            "ready": False,
            "reason": "原生 HyperDR 可执行文件尚未就绪",
        }
    return {"enabled": True, "ready": True, "device": "native"}


def _packet_metadata(packet: bytes) -> tuple[int, int, dict]:
    """Validate the native model-gain packet header and return its geometry."""
    if not packet.startswith(NATIVE_MODEL_GAIN_MAGIC) or len(packet) < 13:
        raise ValueError("native model returned an invalid gain packet")
    json_size = int.from_bytes(packet[9:13], "little")
    if json_size <= 0 or 13 + json_size > len(packet):
        raise ValueError("native model gain metadata is truncated")
    try:
        metadata = json.loads(packet[13:13 + json_size].decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ValueError("native model gain metadata is invalid") from exc
    if (not isinstance(metadata, dict)
            or metadata.get("schema") != "hyperdr.native-model-gain/v1"):
        raise ValueError("native model gain schema is invalid")
    width = metadata.get("width")
    height = metadata.get("height")
    if (isinstance(width, bool) or not isinstance(width, int) or width <= 0
            or isinstance(height, bool) or not isinstance(height, int) or height <= 0
            or metadata.get("channels") != 1
            or metadata.get("layout") != "HW"
            or metadata.get("sampleType") != "float32-le"
            or metadata.get("scale") != "signed-log2-gain"):
        raise ValueError("native model gain geometry is invalid")
    max_stops = metadata.get("gainMaxStops")
    if (isinstance(max_stops, bool) or not isinstance(max_stops, (int, float))
            or not math.isfinite(max_stops)):
        raise ValueError("native model gain headroom is invalid")
    expected = 13 + json_size + width * height * 4
    if len(packet) != expected:
        raise ValueError("native model gain pixels are truncated")
    return width, height, metadata


def _run_native_gain(executable: str, source: Path,
                     highlight_recovery: str) -> tuple[bytes, dict]:
    argv = [
        executable, "model-gain", str(source),
        "--ai-model", NATIVE_MODEL_ARTIFACT,
        "--highlight-recovery", highlight_recovery,
    ]
    try:
        completed = subprocess.run(
            argv, cwd=str(REPO_ROOT), capture_output=True,
            timeout=INFERENCE_TIMEOUT_SECONDS, check=False,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        raise RuntimeError("unable to run native model inference: %s" % exc) from exc
    if completed.returncode != 0:
        detail = completed.stderr.decode("utf-8", errors="replace").strip()
        raise RuntimeError(detail or "native model inference failed")
    width, height, metadata = _packet_metadata(completed.stdout)
    payload_offset = 13 + int.from_bytes(completed.stdout[9:13], "little")
    return completed.stdout[payload_offset:], {
        "width": width,
        "height": height,
        "max_stops": metadata.get("gainMaxStops"),
        "headroom_stops": metadata.get("headroomStops"),
    }


def native_model_gain(source: Path, highlight_recovery: str = "blend") -> tuple[bytes, dict]:
    """Run native model-gain without creating any sidecar files."""
    if not _enabled():
        raise RuntimeError("AI 优化已关闭。")
    executable = _native_executable()
    if not executable:
        raise RuntimeError("原生 HyperDR 可执行文件尚未就绪。")
    source = Path(source)
    stat = source.stat()
    key = (str(source.resolve()), stat.st_mtime_ns, stat.st_size,
           highlight_recovery, executable)

    def produce():
        raw = source.suffix.lower() in RAW_INPUT_EXTENSIONS
        slot = RAW_DECODE_BUDGET.hold(timeout=3.0) if raw else nullcontext()
        with slot:
            return _run_native_gain(executable, source, highlight_recovery)

    return _INFERENCE_FLIGHT.run(
        key, produce, timeout=INFERENCE_TIMEOUT_SECONDS + 5.0)

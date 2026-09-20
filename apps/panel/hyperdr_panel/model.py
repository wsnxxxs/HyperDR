"""Native AI model capability and preview orchestration.

The panel no longer owns a Python model environment or a gain-grid sidecar.
The converter receives the uploaded source and the selected model id, then
performs development, inference, filtering and post-adjustment in memory. This
module gates the feature, asks the executable what it can run, and validates the
packet returned on stdout.
"""
from __future__ import annotations

from contextlib import nullcontext
import json
import math
import os
from pathlib import Path
import subprocess
import threading

from .concurrency import RAW_DECODE_BUDGET, SingleFlight
from .config import REPO_ROOT
from .executable import detect_exe
from .formats import RAW_INPUT_EXTENSIONS
from .schema import validate as validate_settings


NATIVE_MODEL_GAIN_MAGIC = b"HYPGAIN1\n"
INFERENCE_TIMEOUT_SECONDS = max(
    10, int(os.environ.get("HYPERDR_MODEL_TIMEOUT_SECONDS", "300"))
)
EXECUTABLE_PROBE_TIMEOUT_SECONDS = max(
    5, int(os.environ.get("HYPERDR_MODEL_PROBE_TIMEOUT_SECONDS", "30"))
)
_INFERENCE_FLIGHT = SingleFlight()

#: Capability is a property of one executable build, so it is probed once per
#: executable version rather than on every state request or every inference.
_MODEL_LIST_LOCK = threading.Lock()
_MODEL_LIST_CACHE: dict[tuple, dict] = {}


def _enabled() -> bool:
    """Whether the native model feature is enabled by operator policy."""
    configured = os.environ.get("HYPERDR_MODEL_ENABLED")
    if configured is None:
        return True
    return configured.strip().lower() in {"1", "true", "yes", "on"}


def require_enabled() -> None:
    if not _enabled():
        raise RuntimeError("AI 优化已由 HYPERDR_MODEL_ENABLED 关闭")


def _native_executable() -> str:
    """Return the converter path when the native binary is available."""
    return detect_exe() or ""


def _executable_key(executable: str) -> tuple:
    try:
        stat = Path(executable).stat()
        return (executable, stat.st_mtime_ns, stat.st_size)
    except OSError:
        return (executable,)


def model_list(executable: str | None = None) -> list[dict]:
    """Read the supported model table from the executable."""
    require_enabled()
    executable = executable or _native_executable()
    if not executable:
        return []
    key = _executable_key(executable)
    with _MODEL_LIST_LOCK:
        cached = _MODEL_LIST_CACHE.get(key)
    if cached is not None:
        return cached["models"]
    try:
        completed = subprocess.run(
            [executable, "model-list", "--json"], cwd=str(REPO_ROOT),
            capture_output=True, timeout=EXECUTABLE_PROBE_TIMEOUT_SECONDS,
            check=False,
        )
        detail = completed.stderr.decode("utf-8", errors="replace").strip()
        if completed.returncode != 0:
            raise RuntimeError(detail or "model-list failed")
        else:
            document = json.loads(completed.stdout.decode("utf-8"))
        if not isinstance(document, dict) or not isinstance(document.get("models"), list):
            raise ValueError("invalid model-list response")
        models = [
            entry for entry in document.get("models", [])
            if isinstance(entry, dict) and isinstance(entry.get("id"), str) and entry["id"]
        ]
        if not models:
            raise RuntimeError("the executable reported no models")
        result = {"models": models,
                  "default": document.get("defaultModelId") or models[0]["id"],
                  "runtimeAvailable": document.get("runtimeAvailable") is True,
                  "source": "executable"}
    except (OSError, subprocess.SubprocessError, ValueError, RuntimeError) as exc:
        # Failed probes are retryable; only a real capability table is cached.
        raise RuntimeError("无法读取原生模型能力：%s" % exc) from exc
    with _MODEL_LIST_LOCK:
        _MODEL_LIST_CACHE[key] = result
    return result["models"]


def _model_capability(executable: str) -> dict:
    """The list plus its default, for ``/api/state``."""
    key = _executable_key(executable)
    with _MODEL_LIST_LOCK:
        cached = _MODEL_LIST_CACHE.get(key)
    if cached is None:
        model_list(executable)
        with _MODEL_LIST_LOCK:
            cached = _MODEL_LIST_CACHE[key]
    return {k: v for k, v in cached.items() if k != "reason"}


def known_model_ids(executable: str | None = None) -> frozenset[str]:
    return frozenset(entry.get("id") for entry in model_list(executable))


def resolve_model_id(requested, executable: str | None = None) -> str:
    """Validate a requested id against what this build can actually run.

    An omitted or empty value means the build's default, which is what a restored
    settings file from before the selector contains. A value this build does not
    have is an error: substituting another model would render a photograph with
    an algorithm the user did not pick, and the run would look successful.
    """
    require_enabled()
    executable = executable or _native_executable()
    if not executable:
        raise RuntimeError("原生 HyperDR 可执行文件尚未就绪。")
    capability = _model_capability(executable)
    if not capability["runtimeAvailable"]:
        raise RuntimeError("原生 AI 模型运行时不可用。")
    if requested is None or requested == "":
        requested = capability["default"]
    if not isinstance(requested, str):
        raise ValueError("modelId must be a string")
    entry = next((entry for entry in capability["models"] if entry["id"] == requested), None)
    if entry is None:
        raise ValueError("未知的模型 ID：%s" % requested)
    if entry.get("available") is not True:
        raise RuntimeError("原生 AI 模型不可用：%s" % requested)
    return requested


def status() -> dict[str, object]:
    """Return the executable's cached capability, without probing when disabled."""
    if not _enabled():
        return {
            "enabled": False,
            "ready": False,
            "reason": "AI 优化已由 HYPERDR_MODEL_ENABLED 关闭",
        }
    executable = _native_executable()
    if not executable:
        return {
            "enabled": True,
            "ready": False,
            "reason": "原生 HyperDR 可执行文件尚未就绪",
        }
    try:
        capability = _model_capability(executable)
    except RuntimeError as exc:
        return {"enabled": True, "ready": False, "reason": str(exc),
                "models": [], "modelListSource": "probe-failed"}
    ready = capability["runtimeAvailable"] and any(
        entry.get("available") is True for entry in capability["models"])
    return {
        "enabled": True,
        "ready": ready,
        "runtimeAvailable": capability["runtimeAvailable"],
        **({} if ready else {"reason": "原生 AI 模型运行时或模型不可用。"}),
        "device": "native",
        "defaultModelId": capability["default"],
        "models": capability["models"],
        "modelListSource": capability.get("source", "executable"),
    }


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


def _run_native_gain(executable: str, source: Path, highlight_recovery: str,
                     model_id: str, *, color_gamut: str | None = None,
                     clamp_srgb: bool = False, raw_profile: str | None = None) -> tuple[bytes, dict]:
    argv = [
        executable, "model-gain", str(source),
        "--ai-model", model_id,
        "--highlight-recovery", highlight_recovery,
    ]
    if color_gamut is not None:
        argv.extend(["--color-gamut", color_gamut])
    if clamp_srgb:
        argv.append("--clamp-srgb")
    if raw_profile:
        argv.extend(["--raw-profile", raw_profile])
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
    # The identity comes back from the converter rather than being echoed from
    # the request: only the converter knows whether model 2 answered with model
    # 1's prediction, and reporting the request would call that a model-2 result.
    effective = metadata.get("effectiveModelId") or model_id
    requested = metadata.get("requestedModelId") or model_id
    return completed.stdout[payload_offset:], {
        "width": width,
        "height": height,
        "max_stops": metadata.get("gainMaxStops"),
        "headroom_stops": metadata.get("headroomStops"),
        "requested_model_id": requested,
        "effective_model_id": effective,
        "model_version": metadata.get("modelVersion") or "",
        "inference_mode": metadata.get("inferenceMode") or "",
        "fallback_reason": metadata.get("fallbackReason") or "",
        "base_offset": _offset_value(metadata, "baseOffset"),
        "alternate_offset": _offset_value(metadata, "alternateOffset"),
    }


def _offset_value(metadata: dict, prefix: str) -> float:
    numerator = metadata.get(prefix + "Numerator")
    denominator = metadata.get(prefix + "Denominator")
    if (isinstance(numerator, bool) or not isinstance(numerator, int)
            or isinstance(denominator, bool) or not isinstance(denominator, int)
            or denominator == 0):
        return 0.0
    return numerator / denominator


def native_model_gain(source: Path, highlight_recovery: str = "blend",
                      model_id: str | None = None, *, color_gamut: str | None = None,
                      clamp_srgb: bool = False, raw_profile: str | None = None) -> tuple[bytes, dict]:
    """Run native model-gain without creating any sidecar files."""
    require_enabled()
    input_options = {"clamp_srgb": clamp_srgb}
    if color_gamut is not None:
        input_options["color_gamut"] = color_gamut
    input_options = validate_settings(input_options)
    color_gamut = input_options.get("color_gamut")
    clamp_srgb = input_options["clamp_srgb"]
    executable = _native_executable()
    if not executable:
        raise RuntimeError("原生 HyperDR 可执行文件尚未就绪。")
    selected = resolve_model_id(model_id, executable)
    source = Path(source)
    stat = source.stat()
    # Model and input/base options distinguish predictions for the same source.
    key = (str(source.resolve()), stat.st_mtime_ns, stat.st_size,
           highlight_recovery, selected, color_gamut, clamp_srgb, raw_profile, executable)

    def produce():
        raw = source.suffix.lower() in RAW_INPUT_EXTENSIONS
        slot = RAW_DECODE_BUDGET.hold(timeout=3.0) if raw else nullcontext()
        with slot:
            return _run_native_gain(executable, source, highlight_recovery, selected,
                                    color_gamut=color_gamut, clamp_srgb=clamp_srgb,
                                    **({"raw_profile": raw_profile} if raw_profile else {}))

    return _INFERENCE_FLIGHT.run(
        key, produce, timeout=INFERENCE_TIMEOUT_SECONDS + 5.0)

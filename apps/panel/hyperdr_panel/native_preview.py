"""Native linear-P3 preview frames produced by the C++ render pipeline."""
from __future__ import annotations

import json
import os
import subprocess
import tempfile
import threading
from pathlib import Path

from .command import build_preview_frame_argv
from .concurrency import RAW_DECODE_BUDGET, SingleFlight
from .executable import detect_exe

MAX_EDGE = max(512, min(4096, int(os.environ.get("HYPERDR_PREVIEW_MAX_EDGE", "2048"))))
TIMEOUT_SECONDS = max(1, int(os.environ.get("HYPERDR_PREVIEW_TIMEOUT_SECONDS", "180")))
MAGIC = b"HYPREV1\n"
DEFAULT_HIGHLIGHT_RECOVERY = "blend"
_CACHE: dict[tuple, tuple[bytes, dict]] = {}
_CACHE_LOCK = threading.Lock()
_CACHE_LIMIT = 8
_INFLIGHT = SingleFlight()


def parse_packet(data: bytes) -> dict:
    """Validate a native-preview packet and return its JSON metadata."""
    if not data.startswith(MAGIC) or len(data) < 12:
        raise ValueError("converter returned an invalid native preview")
    json_size = int.from_bytes(data[8:12], "little")
    if json_size <= 0 or 12 + json_size > len(data):
        raise ValueError("native preview metadata is truncated")
    try:
        metadata = json.loads(data[12:12 + json_size].decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ValueError("native preview metadata is invalid") from exc
    width = metadata.get("width")
    height = metadata.get("height")
    if (metadata.get("schema") != "hyperdr.native-preview/v1"
            or not isinstance(width, int) or width <= 0
            or not isinstance(height, int) or height <= 0):
        raise ValueError("native preview contract is invalid")
    expected = 12 + json_size + width * height * 3 * 4 * 2
    if len(data) != expected:
        raise ValueError("native preview pixel planes are truncated")
    return metadata


def _build(source: Path, options: dict, max_edge: int) -> tuple[bytes, dict]:
    exe = detect_exe()
    if not exe:
        raise ValueError("HyperDR executable was not found")
    handle, name = tempfile.mkstemp(prefix="hyperdr-preview-", suffix=".hpf")
    os.close(handle)
    output = Path(name)
    output.unlink(missing_ok=True)
    try:
        argv = build_preview_frame_argv(exe, source, output, options, max_edge)
        try:
            completed = subprocess.run(argv, capture_output=True, timeout=TIMEOUT_SECONDS)
        except subprocess.TimeoutExpired as exc:
            raise ValueError("native preview timed out") from exc
        except subprocess.SubprocessError as exc:
            raise ValueError("native preview failed: %s" % exc) from exc
        if completed.returncode != 0:
            message = completed.stderr.decode("utf-8", errors="replace").strip()
            raise ValueError(message or "native preview failed")
        data = output.read_bytes()
        return data, parse_packet(data)
    finally:
        output.unlink(missing_ok=True)


def preview_for(source: Path, options: dict, max_edge: int = MAX_EDGE) -> tuple[bytes, dict]:
    """Return an exact native SDR-base/HDR float frame and its metadata."""
    edge = max(320, min(MAX_EDGE, int(max_edge)))
    stat = source.stat()
    stable_options = json.dumps(
        options, sort_keys=True, separators=(",", ":"), default=str)
    key = (str(source), stat.st_mtime_ns, stat.st_size, stable_options, edge)
    with _CACHE_LOCK:
        cached = _CACHE.get(key)
    if cached:
        return cached

    def produce():
        with RAW_DECODE_BUDGET.hold(timeout=1.0):
            result = _build(source, options, edge)
        with _CACHE_LOCK:
            if len(_CACHE) >= _CACHE_LIMIT:
                _CACHE.pop(next(iter(_CACHE)))
            _CACHE[key] = result
        return result

    return _INFLIGHT.run(key, produce, timeout=TIMEOUT_SECONDS + 5.0)

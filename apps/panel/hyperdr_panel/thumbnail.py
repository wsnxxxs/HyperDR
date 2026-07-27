"""The browser-side preview image.

The panel's live HDR preview is computed in the browser from a small JPEG. This
module produces that JPEG, for every format, through the native codec pipeline,
so what gets cached is a thumbnail rather than a potentially 256 MB original.

A RAW used to take a shortcut: the largest embedded JPEG was lifted out of the
container and resized. That avoided a second RAW decode, and it made the panel
lie twice. The embedded JPEG is the camera's own rendering, not HyperDR's, so
the preview never matched the export; and because it never went through LibRaw,
`--highlight-recovery` could not change it. Someone moving that control saw a
completely static picture and concluded the setting did nothing. RAW now
decodes for real, at half size -- the result is bounded by MAX_EDGE anyway, so
the only thing half-size demosaic costs is the decode time it saves.

Renamed from `preview.py`, which was confusing: `/api/run` also had a "preview"
mode -- a low-quality conversion run -- that the front-end never once invoked.
That mode is gone; this is the only preview left.

A cache bounds *finished* work and says nothing about work in flight, so N
concurrent misses on the same file were N whole-file reads, N temporary files
and N CLI runs with a three-minute timeout, all to produce one answer. Callers
asking for the same image share a single execution and the number of concurrent
executions is capped. The decode settings are part of the cache key, because
they are part of the answer.
"""
from __future__ import annotations

import os
import subprocess
import tempfile
import threading
from pathlib import Path

from .concurrency import Budget, SingleFlight
from .executable import detect_exe

SUPPORTED_EXTENSIONS = frozenset({".arw", ".dng", ".jpg", ".jpeg", ".png", ".heic", ".heif"})
RAW_EXTENSIONS = frozenset({".arw", ".dng"})

#: The RAW decode settings the preview honours, and the value used when the
#: browser omits one. Kept alongside the panel default rather than imported from
#: `command` so that a preview request can be validated on its own.
DEFAULT_HIGHLIGHT_RECOVERY = "blend"

_CACHE: dict[tuple[str, int, int, str, int], tuple[bytes, tuple[int, int], str]] = {}
_CACHE_LOCK = threading.Lock()
# One entry per decode setting per image, so flipping between two highlight
# modes to compare them does not re-decode on every flip.
_CACHE_LIMIT = 8

MAX_EDGE = max(512, min(4096, int(os.environ.get("HYPERDR_PREVIEW_MAX_EDGE", "2048"))))
TIMEOUT_SECONDS = max(1, int(os.environ.get("HYPERDR_PREVIEW_TIMEOUT_SECONDS", "180")))
MAX_PROCESSES = max(1, int(os.environ.get("HYPERDR_MAX_PREVIEW_PROCESSES", "2")))

_BUDGET = Budget(MAX_PROCESSES, "预览服务繁忙，请稍后再试。")
_INFLIGHT = SingleFlight()

# Start-of-frame markers that carry image dimensions.
_SOF_MARKERS = frozenset({
    0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7,
    0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF,
})


def jpeg_dimensions(data: bytes) -> tuple[int, int] | None:
    """Return (width, height) parsed from a JPEG's SOF marker, or None."""
    if not data.startswith(b"\xff\xd8"):
        return None
    pos = 2
    while pos + 3 < len(data):
        if data[pos] != 0xFF:
            pos += 1
            continue
        while pos < len(data) and data[pos] == 0xFF:
            pos += 1
        if pos >= len(data):
            break
        marker = data[pos]
        pos += 1
        if marker in {0x00, 0x01, 0xD8, 0xD9} or 0xD0 <= marker <= 0xD7:
            continue
        if pos + 2 > len(data):
            break
        segment_length = int.from_bytes(data[pos:pos + 2], "big")
        if segment_length < 2 or pos + segment_length > len(data):
            break
        if marker in _SOF_MARKERS and segment_length >= 7:
            height = int.from_bytes(data[pos + 3:pos + 5], "big")
            width = int.from_bytes(data[pos + 5:pos + 7], "big")
            return (width, height) if width and height else None
        pos += segment_length
    return None


def _converter_thumbnail(
    source: Path, highlight_recovery: str = DEFAULT_HIGHLIGHT_RECOVERY,
    max_edge: int = MAX_EDGE,
) -> tuple[bytes, tuple[int, int]]:
    """Decode and resize through the native codec pipeline."""
    exe = detect_exe()
    if not exe:
        raise ValueError("找不到 HyperDR，无法生成预览。")
    handle, name = tempfile.mkstemp(prefix="hyperdr-thumb-", suffix=".jpg")
    os.close(handle)
    output = Path(name)
    output.unlink(missing_ok=True)
    argv = [exe, "thumbnail", str(source), "--output", str(output),
            "--max-edge", str(max_edge), "--quality", "85",
            "--highlight-recovery", highlight_recovery]
    # Half-size demosaic is a RAW-only concept and the flag is harmless
    # elsewhere, but sending it only where it means something keeps the command
    # the panel displays honest.
    if source.suffix.lower() in RAW_EXTENSIONS:
        argv.append("--half-size")
    try:
        try:
            completed = subprocess.run(
                argv, capture_output=True, timeout=TIMEOUT_SECONDS,
            )
        except subprocess.TimeoutExpired as exc:
            # TimeoutExpired is a SubprocessError, which no endpoint catches: it
            # escaped the handler as a traceback and the browser saw the
            # connection drop rather than an error it could display.
            raise ValueError("生成预览超时。") from exc
        except subprocess.SubprocessError as exc:
            raise ValueError("生成预览失败：%s" % exc) from exc
        if completed.returncode != 0:
            message = completed.stderr.decode("utf-8", errors="replace").strip()
            raise ValueError(message or "生成预览失败。")
        data = output.read_bytes()
        dimensions = jpeg_dimensions(data)
        if not dimensions:
            raise ValueError("转换器生成了无效的 JPEG 预览。")
        return data, dimensions
    finally:
        output.unlink(missing_ok=True)


def _build(
    source: Path, key: tuple, highlight_recovery: str, max_edge: int,
) -> tuple[bytes, tuple[int, int], str]:
    """Produce one thumbnail while holding a slot in the process budget."""
    with _BUDGET.hold(timeout=1.0):
        with _CACHE_LOCK:
            cached = _CACHE.get(key)
        if cached:
            return cached
        data, dimensions = _converter_thumbnail(source, highlight_recovery, max_edge)

    entry = (data, dimensions, "image/jpeg")
    with _CACHE_LOCK:
        if len(_CACHE) >= _CACHE_LIMIT:
            _CACHE.pop(next(iter(_CACHE)))
        _CACHE[key] = entry
    return entry


def thumbnail_for(
    source: Path, highlight_recovery: str = DEFAULT_HIGHLIGHT_RECOVERY,
    max_edge: int = MAX_EDGE,
) -> tuple[bytes, tuple[int, int], str]:
    """Return (JPEG bytes, dimensions, MIME type) for one image file.

    Keyed on path plus mtime and size, so replacing the session's image with a
    different file of the same name cannot serve the previous thumbnail, and on
    the decode settings, because two highlight-recovery modes are two different
    images and serving one for the other is the bug this key exists to prevent.
    """
    stat = source.stat()
    edge = max(320, min(MAX_EDGE, int(max_edge)))
    key = (str(source), stat.st_mtime_ns, stat.st_size, highlight_recovery, edge)
    with _CACHE_LOCK:
        cached = _CACHE.get(key)
    if cached:
        return cached
    # Followers wait slightly longer than the work may take, so a genuinely slow
    # decode is shared rather than becoming a second process.
    return _INFLIGHT.run(
        key, lambda: _build(source, key, highlight_recovery, edge),
        timeout=TIMEOUT_SECONDS + 5.0)

"""Native linear-P3 preview frames produced by the C++ render pipeline."""
from __future__ import annotations

import contextlib
import json
import os
import subprocess
import tempfile
import threading
import time
from pathlib import Path

from .command import build_preview_frame_argv
from .concurrency import RAW_DECODE_BUDGET, SingleFlight
from .digest import sha256_file
from .executable import detect_exe
from .formats import RAW_INPUT_EXTENSIONS
from .preview_worker import WORKER

MAX_EDGE = max(512, min(4096, int(os.environ.get("HYPERDR_PREVIEW_MAX_EDGE", "2048"))))
TIMEOUT_SECONDS = max(1, int(os.environ.get("HYPERDR_PREVIEW_TIMEOUT_SECONDS", "180")))
MAGIC = b"HYPREV1\n"
DEFAULT_HIGHLIGHT_RECOVERY = "blend"
_CACHE: dict[tuple, tuple[bytes, dict]] = {}
_CACHE_LOCK = threading.Lock()
_CACHE_ENTRY_LIMIT = 2
_CACHE_MAX_BYTES = 256 * 1024 * 1024
_INFLIGHT = SingleFlight()
_ORPHAN_MAX_AGE_SECONDS = max(3600, TIMEOUT_SECONDS * 2)
_ACTIVE_LOCK = threading.Lock()
_ACTIVE: dict[str, "_PreviewCall"] = {}
_CURRENT_CALL = threading.local()


class PreviewCancelled(ValueError):
    """A superseded preview was stopped before it could publish a frame."""


class _PreviewCall:
    """Cancellation state shared by the request thread and its CLI process."""

    def __init__(self, source_key: str, key: tuple,
                 decode_cache: Path | None = None,
                 source_digest: str | None = None,
                 executable: str | None = None) -> None:
        self.source_key = source_key
        self.key = key
        self.decode_cache = decode_cache
        self.source_digest = source_digest
        self.executable = executable
        self.cancel = threading.Event()
        self.process: subprocess.Popen | None = None

    def stop(self) -> None:
        self.cancel.set()
        process = self.process
        if process is None or process.poll() is not None:
            return
        try:
            process.terminate()
        except OSError:
            pass


def _source_key(source: Path) -> str:
    # `resolve(strict=False)` also makes relative and absolute session paths
    # collapse to one cancellation domain without requiring the file to exist.
    try:
        return str(source.resolve(strict=False))
    except OSError:
        return str(source)


def _cancel_superseded(source_key: str, key: tuple) -> None:
    with _ACTIVE_LOCK:
        active = _ACTIVE.get(source_key)
        if active is not None and active.key != key:
            active.stop()


def _register_call(call: _PreviewCall) -> None:
    with _ACTIVE_LOCK:
        previous = _ACTIVE.get(call.source_key)
        if previous is not None and previous.key != call.key:
            previous.stop()
        _ACTIVE[call.source_key] = call


def _unregister_call(call: _PreviewCall) -> None:
    with _ACTIVE_LOCK:
        if _ACTIVE.get(call.source_key) is call:
            _ACTIVE.pop(call.source_key, None)


def _remove_output_artifacts(output: Path) -> None:
    """Remove the requested packet and atomic-write debris from an interrupted CLI."""
    output.unlink(missing_ok=True)
    # HyperDR's atomic writer appends `.tmp.<pid>.<sequence>`. The random
    # mkstemp basename belongs exclusively to this invocation, so no other
    # preview can own a matching sibling.
    for candidate in output.parent.glob(output.name + ".tmp.*"):
        try:
            if candidate.is_file() or candidate.is_symlink():
                candidate.unlink(missing_ok=True)
        except OSError:
            pass


def _cleanup_orphaned_previews(now: float | None = None) -> None:
    """Remove preview packets left by a process that could not run ``finally``."""
    cutoff = (time.time() if now is None else now) - _ORPHAN_MAX_AGE_SECONDS
    try:
        candidates = Path(tempfile.gettempdir()).glob("hyperdr-preview-*.hpf*")
        for candidate in candidates:
            try:
                # A live preview cannot legitimately exceed the CLI timeout by
                # this margin. Never touch directories or a recently active
                # file, so parallel panel processes remain independent.
                if ((candidate.is_file() or candidate.is_symlink())
                        and candidate.stat().st_mtime < cutoff):
                    candidate.unlink(missing_ok=True)
            except OSError:
                pass
    except OSError:
        pass


def parse_packet(data: bytes) -> dict:
    """Validate a native-preview packet and return its JSON metadata."""
    if not data.startswith((MAGIC, b"HYPREV2\n")) or len(data) < 12:
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
    if (metadata.get("schema") not in ("hyperdr.native-preview/v1", "hyperdr.native-preview/v2")
            or not isinstance(width, int) or width <= 0
            or not isinstance(height, int) or height <= 0):
        raise ValueError("native preview contract is invalid")
    expected = 12 + json_size + width * height * 3 * 4 * 2
    if metadata["schema"] == "hyperdr.native-preview/v2":
        gw, gh = metadata.get("gainWidth"), metadata.get("gainHeight")
        if not isinstance(gw, int) or gw <= 0 or not isinstance(gh, int) or gh <= 0:
            raise ValueError("native preview gain dimensions are invalid")
        expected = 12 + json_size + (width * height * 3 + gw * gh) * 4
    if len(data) != expected:
        raise ValueError("native preview pixel planes are truncated")
    return metadata


def omit_unchanged_base(data: bytes, metadata: dict, base_id: str) -> bytes:
    """The editor names the exact base it retains; phone broadcasts stay complete."""
    if (not base_id or metadata.get("schema") != "hyperdr.native-preview/v2"
            or metadata.get("baseId") != base_id):
        return data
    header_size = int.from_bytes(data[8:12], "little")
    gain_offset = 12 + header_size + metadata["width"] * metadata["height"] * 12
    header = json.dumps(dict(metadata, baseOmitted=True), separators=(",", ":")).encode("utf-8")
    header += b" " * (-len(header) % 4)
    return b"HYPREV2\n" + len(header).to_bytes(4, "little") + header + data[gain_offset:]


def _build(source: Path, options: dict, max_edge: int,
           call: _PreviewCall | None = None) -> tuple[bytes, dict]:
    if call is None:
        call = getattr(_CURRENT_CALL, "value", None)
    if call is not None and os.environ.get("HYPERDR_PREVIEW_WORKER", "1") != "0":
        argv = build_preview_frame_argv(call.executable or detect_exe(), source, "-", options,
            max_edge, decode_cache=call.decode_cache, source_digest=call.source_digest)
        try:
            data = WORKER.request(argv, call, TIMEOUT_SECONDS)
        except ValueError:
            if call.cancel.is_set():
                raise PreviewCancelled("preview superseded")
            raise
        return data, parse_packet(data)
    _cleanup_orphaned_previews()
    exe = call.executable if call is not None and call.executable else detect_exe()
    if not exe:
        raise ValueError("HyperDR executable was not found")
    handle, name = tempfile.mkstemp(prefix="hyperdr-preview-", suffix=".hpf")
    os.close(handle)
    output = Path(name)
    _remove_output_artifacts(output)
    try:
        argv = build_preview_frame_argv(
            exe, source, output, options, max_edge,
            decode_cache=call.decode_cache if call is not None else None,
            source_digest=call.source_digest if call is not None else None)
        # Keep the small internal helper usable by diagnostics/tests that call
        # it directly. Live requests always pass a call object and use the
        # cancellable Popen path below.
        if call is None:
            try:
                completed = subprocess.run(
                    argv, capture_output=True, timeout=TIMEOUT_SECONDS)
            except subprocess.TimeoutExpired as exc:
                raise ValueError("native preview timed out") from exc
            except (OSError, subprocess.SubprocessError) as exc:
                raise ValueError("native preview failed: %s" % exc) from exc
            if completed.returncode != 0:
                message = completed.stderr.decode("utf-8", errors="replace").strip()
                raise ValueError(message or "native preview failed")
            data = output.read_bytes()
            return data, parse_packet(data)
        if call.cancel.is_set():
            raise PreviewCancelled("preview superseded")
        try:
            process = subprocess.Popen(
                argv, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            call.process = process
            deadline = time.monotonic() + TIMEOUT_SECONDS
            while True:
                if call.cancel.is_set():
                    call.stop()
                    try:
                        process.communicate(timeout=2.0)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.communicate()
                    raise PreviewCancelled("preview superseded")
                if process.poll() is not None:
                    break
                if time.monotonic() >= deadline:
                    call.stop()
                    try:
                        process.communicate(timeout=2.0)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.communicate()
                    raise ValueError("native preview timed out")
                time.sleep(0.025)
            stdout, stderr = process.communicate()
        except subprocess.TimeoutExpired as exc:
            raise ValueError("native preview timed out") from exc
        except (OSError, subprocess.SubprocessError) as exc:
            raise ValueError("native preview failed: %s" % exc) from exc
        finally:
            call.process = None
        if process.returncode != 0:
            message = stderr.decode("utf-8", errors="replace").strip()
            raise ValueError(message or "native preview failed")
        data = output.read_bytes()
        return data, parse_packet(data)
    finally:
        _remove_output_artifacts(output)


def _cache_bytes() -> int:
    return sum(len(value[0]) for value in _CACHE.values())


def _cache_get(key: tuple):
    cached = _CACHE.get(key)
    if cached is not None:
        # Dicts preserve insertion order; moving a hit to the end keeps the
        # two most recently used states for the current image.
        _CACHE.pop(key)
        _CACHE[key] = cached
    return cached


def _cache_put(key: tuple, value: tuple[bytes, dict]) -> None:
    _CACHE.pop(key, None)
    _CACHE[key] = value
    while _CACHE and (len(_CACHE) > _CACHE_ENTRY_LIMIT
                      or _cache_bytes() > _CACHE_MAX_BYTES):
        _CACHE.pop(next(iter(_CACHE)))


def preview_for(source: Path, options: dict, max_edge: int = MAX_EDGE,
                source_digest: str | None = None,
                decode_cache: Path | None = None) -> tuple[bytes, dict]:
    """Return an exact native SDR-base/HDR float frame and its metadata."""
    edge = max(320, min(MAX_EDGE, int(max_edge)))
    stat = source.stat()
    source_digest = source_digest or sha256_file(source)
    stable_options = json.dumps(
        options, sort_keys=True, separators=(",", ":"), default=str)
    external_digests = tuple(
        (name, sha256_file(Path(options[name])))
        for name in ("external_gain", "external_gain_report")
        if options.get(name)
    )
    exe = detect_exe()
    try:
        exe_stat = Path(exe).stat() if exe else None
    except OSError:
        exe_stat = None
    executable_key = (exe, exe_stat.st_mtime_ns, exe_stat.st_size) if exe_stat else (exe,)
    source_key = _source_key(source)
    key = (source_key, stat.st_mtime_ns, stat.st_size, source_digest,
           stable_options, external_digests, edge, executable_key)
    # Returning to a cached slider value must also stop the superseded render.
    _cancel_superseded(source_key, key)
    with _CACHE_LOCK:
        cached = _cache_get(key)
    if cached:
        return cached

    def produce():
        call = _PreviewCall(source_key, key, decode_cache, source_digest, exe)
        _register_call(call)
        try:
            # Raster previews do not use LibRaw's large sensor-domain working
            # set. Keeping them out of the RAW budget prevents a normal JPG
            # slider move from producing a misleading "RAW memory occupied"
            # error while another request is decoding a camera file.
            is_raw = source.suffix.lower() in RAW_INPUT_EXTENSIONS
            # A superseded RAW process needs a moment to terminate and release
            # the one decode slot. Absorb that normal handoff instead of making
            # the newest slider value fail with a transient 503.
            slot = RAW_DECODE_BUDGET.hold(timeout=3.0) if is_raw else contextlib.nullcontext()
            with slot:
                if call.cancel.is_set():
                    raise PreviewCancelled("preview superseded")
                _CURRENT_CALL.value = call
                try:
                    # Keep the three-argument helper contract used by small
                    # diagnostics and tests; the thread-local carries live
                    # cancellation state into the native subprocess path.
                    result = _build(source, options, edge)
                finally:
                    del _CURRENT_CALL.value
            if call.cancel.is_set():
                raise PreviewCancelled("preview superseded")
            with _CACHE_LOCK:
                _cache_put(key, result)
            return result
        finally:
            _unregister_call(call)

    return _INFLIGHT.run(key, produce, timeout=TIMEOUT_SECONDS + 5.0)

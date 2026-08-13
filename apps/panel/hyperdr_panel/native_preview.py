"""Native linear-P3 preview frames produced by the C++ render pipeline."""
from __future__ import annotations

import contextlib
import hashlib
import json
import os
import subprocess
import tempfile
import threading
import time
from pathlib import Path

from .command import build_preview_frame_argv
from .concurrency import RAW_DECODE_BUDGET, SingleFlight
from .executable import detect_exe
from .formats import RAW_INPUT_EXTENSIONS

MAX_EDGE = max(512, min(4096, int(os.environ.get("HYPERDR_PREVIEW_MAX_EDGE", "2048"))))
TIMEOUT_SECONDS = max(1, int(os.environ.get("HYPERDR_PREVIEW_TIMEOUT_SECONDS", "180")))
MAGIC = b"HYPREV1\n"
DEFAULT_HIGHLIGHT_RECOVERY = "blend"
_CACHE: dict[tuple, tuple[bytes, dict]] = {}
_CACHE_LOCK = threading.Lock()
_CACHE_LIMIT = 8
_INFLIGHT = SingleFlight()
_ORPHAN_MAX_AGE_SECONDS = max(3600, TIMEOUT_SECONDS * 2)
_ACTIVE_LOCK = threading.Lock()
_ACTIVE: dict[str, "_PreviewCall"] = {}
_CURRENT_CALL = threading.local()


class PreviewCancelled(ValueError):
    """A superseded preview was stopped before it could publish a frame."""


class _PreviewCall:
    """Cancellation state shared by the request thread and its CLI process."""

    def __init__(self, source_key: str, key: tuple) -> None:
        self.source_key = source_key
        self.key = key
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


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


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


def _build(source: Path, options: dict, max_edge: int,
           call: _PreviewCall | None = None) -> tuple[bytes, dict]:
    if call is None:
        call = getattr(_CURRENT_CALL, "value", None)
    _cleanup_orphaned_previews()
    exe = detect_exe()
    if not exe:
        raise ValueError("HyperDR executable was not found")
    handle, name = tempfile.mkstemp(prefix="hyperdr-preview-", suffix=".hpf")
    os.close(handle)
    output = Path(name)
    _remove_output_artifacts(output)
    try:
        argv = build_preview_frame_argv(exe, source, output, options, max_edge)
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


def preview_for(source: Path, options: dict, max_edge: int = MAX_EDGE) -> tuple[bytes, dict]:
    """Return an exact native SDR-base/HDR float frame and its metadata."""
    edge = max(320, min(MAX_EDGE, int(max_edge)))
    stat = source.stat()
    source_digest = _sha256(source)
    stable_options = json.dumps(
        options, sort_keys=True, separators=(",", ":"), default=str)
    external_digests = tuple(
        (name, _sha256(Path(options[name])))
        for name in ("external_gain", "external_gain_report")
        if options.get(name)
    )
    key = (str(source), stat.st_mtime_ns, stat.st_size, source_digest,
           stable_options, external_digests, edge)
    with _CACHE_LOCK:
        cached = _CACHE.get(key)
    if cached:
        return cached

    source_key = _source_key(source)
    _cancel_superseded(source_key, key)

    def produce():
        call = _PreviewCall(source_key, key)
        _register_call(call)
        try:
            # Raster previews do not use LibRaw's large sensor-domain working
            # set. Keeping them out of the RAW budget prevents a normal JPG
            # slider move from producing a misleading "RAW memory occupied"
            # error while another request is decoding a camera file.
            is_raw = source.suffix.lower() in RAW_INPUT_EXTENSIONS
            slot = RAW_DECODE_BUDGET.hold(timeout=1.0) if is_raw else contextlib.nullcontext()
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
                if len(_CACHE) >= _CACHE_LIMIT:
                    _CACHE.pop(next(iter(_CACHE)))
                _CACHE[key] = result
            return result
        finally:
            _unregister_call(call)

    return _INFLIGHT.run(key, produce, timeout=TIMEOUT_SECONDS + 5.0)

"""One session, one image.

The panel converts a single photograph at a time, so a session holds exactly one
input and produces exactly one output. That is what lets this module be a
handful of path lookups: the previous multi-file version had to track the
running byte total of a directory that grew with every upload *and* with
whatever the converter wrote into a nested output tree, which took a usage
cache, a directory mtime stamp, a per-session lock and an explicit invalidation
hook that `jobs.py` had to remember to call.

Uploading replaces the current input rather than adding to it, matching the
interface, where tapping the preview swaps the photograph.

The browser never supplies a filesystem path. It receives an opaque session id
and every path in here is derived from it and re-checked against the workspace
root, so a crafted id cannot address anything outside.
"""
from __future__ import annotations

import hashlib
import os
import re
import shutil
import time
import uuid
from pathlib import Path

from .config import IS_FROZEN, REPO_ROOT
from .digest import sha256_file
from . import formats
from .formats import (CANONICAL_EXTENSIONS, PREFIX_BYTES, RAW_INPUT_EXTENSIONS,
                      SUPPORTED_EXTENSIONS)




def _default_work_root() -> Path:
    """Use a writable per-user directory for frozen desktop installations."""
    if IS_FROZEN:
        app_data = Path(os.environ.get("LOCALAPPDATA", Path.home()))
        return app_data / "HyperDR" / "hdr-workspace"
    return REPO_ROOT / "hdr-workspace"


WORK_ROOT = Path(os.environ.get("HYPERDR_WORK_ROOT", _default_work_root())).resolve()
MAX_UPLOAD_BYTES = int(os.environ.get("HYPERDR_MAX_UPLOAD_MB", "256")) * 1024 * 1024
SESSION_TTL_SECONDS = int(os.environ.get("HYPERDR_SESSION_HOURS", "24")) * 3600

RESULT_EXTENSIONS = frozenset({".avif", ".heic", ".jpg", ".jpeg"})

_SESSION_RE = re.compile(r"^[0-9a-f]{32}$")

# Desktop Tauri can hand us an absolute path instead of copying the image into
# the session. This is deliberately process-local: a browser never gets to
# persist or choose a path by session id, and a restart simply requires the
# desktop panel to submit the path again.
_EXTERNAL_INPUTS: dict[str, Path] = {}
_INPUT_DIGESTS: dict[str, tuple[Path, int, int, str]] = {}
# The resolved input per session, so the common case does not re-scan and
# re-sort the input directory on every preview, run and download.
_INPUT_PATHS: dict[str, Path] = {}


# --- paths ----------------------------------------------------------------- #

def create_session() -> str:
    WORK_ROOT.mkdir(parents=True, exist_ok=True)
    session_id = uuid.uuid4().hex
    for name in ("input", "output"):
        (WORK_ROOT / session_id / name).mkdir(parents=True, exist_ok=False)
    return session_id


def session_root(session_id: str) -> Path:
    if not _SESSION_RE.fullmatch(session_id or ""):
        raise ValueError("invalid session id")
    root = (WORK_ROOT / session_id).resolve()
    # Re-checked after resolution: a symlinked session directory must not be
    # able to address anything outside the workspace.
    root.relative_to(WORK_ROOT)
    if not root.is_dir():
        raise FileNotFoundError("任务不存在或已过期。")
    os.utime(root, None)  # Touched on use, so cleanup measures idle time.
    return root


def session_dir(session_id: str, kind: str) -> Path:
    if kind not in {"input", "output"}:
        raise ValueError("invalid session directory")
    return session_root(session_id) / kind


# --- upload ---------------------------------------------------------------- #

def _safe_filename(value: str) -> str:
    name = Path(value.replace("\\", "/")).name.strip().rstrip(". ")
    if not name or name in {".", ".."}:
        raise ValueError("文件名无效。")
    suffix = Path(name).suffix.lower()
    if suffix not in SUPPORTED_EXTENSIONS:
        raise ValueError("不支持此格式；请选择 LibRaw RAW、JPEG、PNG、HEIC、HEIF 或 AVIF。")
    stem = re.sub(r"[^\w\-. ()\u4e00-\u9fff]", "_", Path(name).stem, flags=re.UNICODE)
    stem = stem[:120].strip(". ") or "image"
    return stem + suffix


def _read_header(path: Path) -> bytes:
    """The leading bytes, and only those.

    This used to be ``path.read_bytes()[:32]``, which pulled the entire file
    into memory to look at 32 of it -- on every upload and every desktop drop,
    so a 300 MB RAW cost a 300 MB read and allocation to answer a question the
    first sixty-four bytes settle.
    """
    with path.open("rb") as handle:
        return handle.read(PREFIX_BYTES)


def _classify_input(path: Path, suffix: str) -> str:
    """Return the extension this file should be stored under, or raise.

    The old guard demanded that the header match the extension exactly and
    refused the file otherwise. That is the right instinct -- a renamed file
    must not be taken at its word -- but it drew the line in the wrong place: a
    phone gallery exports HEIC under a ``.jpg`` name routinely, and those were
    rejected as corrupt when nothing was wrong with them. The bytes now decide
    the format and the name is corrected to match, while a file whose contents
    are not a supported image at all is still refused, extension or no.

    RAW takes the opposite path. Most RAW containers are TIFF and CR3 shares
    ISO-BMFF with HEIC, so a prefix cannot validate the claim. The extension
    routes it to LibRaw and the decoder remains the authority on its contents.
    """
    if suffix in RAW_INPUT_EXTENSIONS:
        # RAW headers are not an identification scheme: most formats are TIFF,
        # while CR3 shares ISO-BMFF with HEIC/AVIF. The extension selects LibRaw
        # and LibRaw reports whether the camera file itself is valid.
        return suffix
    header = _read_header(path)
    detected = formats.detect_format(header)
    if detected is None:
        raise ValueError(
            "无法识别此文件的图像格式；请选择 LibRaw RAW、JPEG、PNG、HEIC、HEIF 或 AVIF。")
    if formats.extension_format(suffix) == detected:
        return suffix
    return CANONICAL_EXTENSIONS[detected]


def input_digest(session_id: str) -> str:
    """Return the current input digest, reusing it while its file is unchanged."""
    source = input_path(session_id)
    stat = source.stat()
    cached = _INPUT_DIGESTS.get(session_id)
    if (cached is not None and cached[0] == source
            and cached[1] == stat.st_mtime_ns and cached[2] == stat.st_size):
        return cached[3]
    digest = sha256_file(source)
    _INPUT_DIGESTS[session_id] = (source, stat.st_mtime_ns, stat.st_size, digest)
    return digest


def save_upload(session_id: str, filename: str, stream, length: int) -> tuple[Path, int]:
    """Stream one image in, replacing whatever the session held before.

    Written to a dotted temporary name and renamed into place, so a connection
    that drops halfway cannot leave a truncated file that the converter would
    then try to decode.
    """
    if length <= 0:
        raise ValueError("上传内容为空。")
    if length > MAX_UPLOAD_BYTES:
        raise ValueError("文件超过上传大小限制。")

    root = session_root(session_id)
    inputs = root / "input"
    safe_name = _safe_filename(filename)
    temporary = inputs / f".{uuid.uuid4().hex}{Path(safe_name).suffix}"
    digest = hashlib.sha256()
    try:
        remaining = length
        with temporary.open("xb") as output:
            while remaining:
                chunk = stream.read(min(1024 * 1024, remaining))
                if not chunk:
                    raise ValueError("上传在完成前中断。")
                output.write(chunk)
                digest.update(chunk)
                remaining -= len(chunk)
        stored_suffix = _classify_input(temporary, Path(safe_name).suffix.lower())
        # One image per session: the previous one goes only once the new one is
        # known to be complete and well-formed.
        for existing in inputs.iterdir():
            if existing.is_file() and existing != temporary:
                existing.unlink(missing_ok=True)
        # Stored under the extension its contents are, not the one it arrived
        # with. Everything downstream reads the format off the name -- the
        # converter's RAW/raster split, the model's --half-size decision, the
        # job's resource class -- so a .jpg holding HEIC has to stop being
        # called a .jpg here rather than fool each of them separately.
        target = inputs / (Path(safe_name).stem + stored_suffix)
        temporary.replace(target)
        _EXTERNAL_INPUTS.pop(session_id, None)
        _INPUT_PATHS[session_id] = target
        stat = target.stat()
        _INPUT_DIGESTS[session_id] = (
            target, stat.st_mtime_ns, stat.st_size, digest.hexdigest())
    except BaseException:
        temporary.unlink(missing_ok=True)
        raise

    os.utime(root, None)
    return target, length


def set_external_input(session_id: str, raw_path: str) -> tuple[Path, int]:
    """Register a validated local source without copying its bytes.

    Only the Tauri desktop bridge calls this endpoint. Validation happens before
    the session's current input is removed, so a failed drop leaves the visible
    photograph usable.
    """
    if not isinstance(raw_path, str) or not raw_path.strip():
        raise ValueError("源文件路径不能为空")
    candidate = Path(raw_path)
    if not candidate.is_absolute():
        raise ValueError("源文件路径必须是绝对路径")
    try:
        source = candidate.resolve(strict=True)
    except OSError as exc:
        raise ValueError("源文件不存在或无法访问") from exc
    if not source.is_file():
        raise ValueError("拖入的路径不是文件")
    if source.suffix.lower() not in SUPPORTED_EXTENSIONS:
        raise ValueError("不支持此图像格式")
    try:
        size = source.stat().st_size
        if size <= 0:
            raise ValueError("源文件为空")
        stored_suffix = _classify_input(source, source.suffix.lower())
    except OSError as exc:
        raise ValueError("源文件无法读取") from exc
    # The desktop bridge publishes a path instead of copying bytes, so there is
    # nothing here to rename. A file whose contents disagree with its name is
    # refused rather than passed to a converter that would route it by that
    # name; the message says which format it actually is so the fix is obvious.
    if stored_suffix != source.suffix.lower():
        raise ValueError(
            "此文件的内容其实是 %s 格式，请先将扩展名改为 %s 再拖入"
            % (stored_suffix.lstrip("."), stored_suffix))

    root = session_root(session_id)
    inputs = root / "input"
    for existing in inputs.iterdir():
        if existing.is_file() or existing.is_symlink():
            existing.unlink(missing_ok=True)
    _EXTERNAL_INPUTS[session_id] = source
    _INPUT_PATHS[session_id] = source
    _INPUT_DIGESTS.pop(session_id, None)
    os.utime(root, None)
    return source, size


def input_path(session_id: str) -> Path:
    """The session's image, or FileNotFoundError if nothing was uploaded."""
    inputs = session_dir(session_id, "input")
    external = _EXTERNAL_INPUTS.get(session_id)
    if external is not None:
        if external.is_file() and external.suffix.lower() in SUPPORTED_EXTENSIONS:
            return external
        raise FileNotFoundError("桌面端源文件已不存在")
    # Both ingest paths record what they stored, so the ordinary case -- every
    # preview, run and download of an image already in the session -- answers
    # from memory instead of listing and sorting the directory again. The scan
    # remains for a workspace this process did not populate: a resumed session
    # after a restart, or a file placed there by hand.
    remembered = _INPUT_PATHS.get(session_id)
    if remembered is not None and remembered.parent == inputs and remembered.is_file():
        return remembered
    for item in sorted(inputs.iterdir()):
        if item.is_file() and item.suffix.lower() in SUPPORTED_EXTENSIONS:
            _INPUT_PATHS[session_id] = item
            return item
    _INPUT_PATHS.pop(session_id, None)
    raise FileNotFoundError("尚未上传图片。")


# --- results --------------------------------------------------------------- #

def clear_output(session_id: str) -> int:
    """Empty the output directory before a run.

    Without this, changing the encoding from HEIC to AVIF left the previous
    run's file in place under its old extension and `result_path` could return
    the wrong one. Dotted entries are left alone: the converter keeps its own
    bookkeeping there and it is keyed on the input, not on the run.
    """
    folder = session_dir(session_id, "output")
    removed = 0
    # Deepest first, so a directory is only removed once it is empty.
    for item in sorted(folder.rglob("*"), key=lambda p: len(p.parts), reverse=True):
        if any(part.startswith(".") for part in item.relative_to(folder).parts):
            continue
        try:
            if item.is_file() or item.is_symlink():
                item.unlink()
                removed += 1
            elif item.is_dir():
                item.rmdir()
        except OSError:
            continue
    return removed


def result_path(session_id: str) -> Path:
    """The converted image, or FileNotFoundError if this run produced none.

    Model inference keeps its thumbnails and gain-grid files in dotted
    subdirectories of ``output``.  Those are intermediate artifacts, not
    downloadable results, so only a file directly under ``output`` can be the
    converted image.
    """
    folder = session_dir(session_id, "output")
    for item in sorted(folder.iterdir(), key=lambda p: str(p).lower()):
        if item.is_file() and item.suffix.lower() in RESULT_EXTENSIONS:
            target = item.resolve()
            target.relative_to(folder.resolve())
            return target
    raise FileNotFoundError("结果文件不存在。")


# --- cleanup --------------------------------------------------------------- #

def cleanup_expired_sessions(now: float | None = None,
                             protected_session_ids: set[str] | None = None) -> int:
    """Remove idle sessions, never one a conversion is still using."""
    if not WORK_ROOT.exists():
        return 0
    cutoff = (now if now is not None else time.time()) - SESSION_TTL_SECONDS
    protected = protected_session_ids or set()
    removed = 0
    for item in WORK_ROOT.iterdir():
        if (not item.is_dir() or not _SESSION_RE.fullmatch(item.name)
                or item.name in protected):
            continue
        try:
            if item.stat().st_mtime < cutoff:
                shutil.rmtree(item)
                _EXTERNAL_INPUTS.pop(item.name, None)
                _INPUT_DIGESTS.pop(item.name, None)
                _INPUT_PATHS.pop(item.name, None)
                removed += 1
        except OSError:
            continue
    return removed
